// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOrderEngine} from "./interfaces/IOrderEngine.sol";
import {IBookFeeVault} from "./interfaces/IBookFeeVault.sol";
import {ITruthMarket} from "./interfaces/ITruthMarket.sol";
import {TickBitmap} from "./libraries/TickBitmap.sol";
import {BookLeg} from "./libraries/BookLeg.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice One YES-price order book with backed, independently owned YES and NO.
/// @dev Reservations are subsets of ownership. BUY orders reserve cash, SELL
/// orders reserve inventory. There is no automatic netting or merging.
/// Matching first plans bounded fills, then collects exact aggregate taker cash
/// before applying fills and paying makers. Transfers do not release backing.
contract OrderEngine is IOrderEngine, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TickBitmap for TickBitmap.Bitmap;

    struct Inventory {
        uint256 yesOwned;
        uint256 noOwned;
        uint256 yesReserved;
        uint256 noReserved;
        uint256 cashReserved;
    }

    struct Order {
        uint64 id;
        address maker;
        uint128 amount;
        uint128 originalAmount;
        uint8 action;
        uint8 outcome;
        uint64 expiry;
        uint32 prev; // live-list neighbor, or NIL
        uint32 next;
        bool liveLink;
        uint256 cashReserved;
    }

    /// @dev Live orders at one tick, in price-time order. Cancel and full fill
    ///      unlink in O(1), so a spent slot cannot sit behind a live head.
    struct LiveList {
        uint32 head;
        uint32 tail;
        uint32 count;
    }

    struct OrderPointer {
        address market;
        uint8 side;
        uint16 tick;
        uint32 index;
        bool exists;
    }

    struct MatchStep {
        uint64 orderId;
        uint128 amount; // zero means an expired/self order must be cancelled
        uint256 makerCash;
    }

    struct ExecutionPlan {
        MatchStep[] steps;
        uint256 count;
        uint256 iterations;
        uint256 skipped;
        uint128 remaining;
        uint256 tokenIn;
        uint256 tokenOut;
        uint256 feeBasis;
    }

    uint16 private constant NUM_TICKS = 1000;
    uint16 private constant MAX_TICK = 999;
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_HEAD_ADVANCE = 32;
    uint256 private constant MAX_COMPACT_LENGTH = 32;
    uint256 private constant MAX_MAKER_CANCEL_SCAN = 32;
    /// @notice Previous per-order cap on spent-entry scans. Matching no longer walks
    ///         spent entries; cancel and full fill unlink them from the live list.
    uint256 public constant MAX_DEAD_SKIPS = 512;
    uint32 private constant NIL = type(uint32).max;

    IERC20 public immutable override baseToken;
    uint8 public immutable baseTokenDecimals;
    uint256 public immutable override shareUnit;
    address public immutable marketFactory;
    IBookFeeVault public immutable feeVault;

    mapping(address => bool) public registeredMarkets;
    uint256 public override fillCount;
    mapping(address => mapping(address => Inventory)) private _inventory;
    mapping(address => uint256) private _yesSupply;
    mapping(address => uint256) private _noSupply;
    mapping(address => mapping(address => uint8)) public override invalidRemainderOf;
    mapping(address => uint256) private _shareBacking;
    mapping(address => uint256) private _orderCash;

    mapping(address => mapping(uint8 => mapping(uint16 => Order[]))) internal _orders;
    mapping(address => mapping(uint8 => mapping(uint16 => uint256))) internal _orderHead;
    mapping(address => mapping(uint8 => mapping(uint16 => LiveList))) private _live;
    mapping(address => mapping(uint8 => TickBitmap.Bitmap)) internal _bitmaps;
    mapping(uint64 => OrderPointer) private _orderPointers;
    mapping(
        address => mapping(uint8 => mapping(uint16 => mapping(address => uint64[])))
    ) private _makerOrders;
    mapping(
        address => mapping(uint8 => mapping(uint16 => mapping(address => uint256)))
    ) private _makerCursor;
    uint64 private _nextOrderId;
    mapping(address => uint256) private _deferred;
    uint256 private _totalDeferred;

    error NotAuthorized();
    error ZeroAddress();
    error UnsupportedBaseTokenDecimals();
    error MarketNotSettled();
    error ZeroAmount();
    error NothingToRedeem();
    error MarketNotLive();
    error MarketNotActive();
    error MarketAlreadyRegistered();
    error TransferAmountMismatch();
    error InvalidTick();
    error InvalidSide();
    error InvalidOrderTerms();
    error InvalidShareAmount();
    error InvalidExpiry();
    error InsufficientInventory();
    error AmountTooLarge();
    error CashLimit();
    error PostOnlyWouldTrade();
    error NothingFilled();
    error OrderNotFound();
    error NothingToCancel();
    error NothingDeferred();
    error PayoutFailed();

    constructor(address token, address creator, address vault) {
        require(
            token != address(0) && creator != address(0) && vault != address(0),
            ZeroAddress()
        );
        uint8 decimals = IERC20Metadata(token).decimals();
        require(decimals <= 18, UnsupportedBaseTokenDecimals());
        baseToken = IERC20(token);
        baseTokenDecimals = decimals;
        shareUnit = 10 ** (18 - decimals);
        marketFactory = creator;
        feeVault = IBookFeeVault(vault);
    }

    function registerMarket(address market, address token, uint256 initialPrice)
        external
        override
    {
        require(
            msg.sender == marketFactory && token == address(baseToken), NotAuthorized()
        );
        require(ITruthMarket(market).marketFactory() == marketFactory, NotAuthorized());
        require(!registeredMarkets[market], MarketAlreadyRegistered());
        registeredMarkets[market] = true;
        emit MarketRegistered(market, token, initialPrice);
    }

    function split(address market, uint256 amount, uint256 maxTokenIn, uint64 validUntil)
        external
        override
        nonReentrant
        returns (uint256 collateral)
    {
        _requireTradingOpen(market);
        _checkAmount(amount);
        require(
            block.timestamp <= validUntil && maxTokenIn != type(uint256).max,
            InvalidOrderTerms()
        );
        collateral = amount / shareUnit;
        require(collateral <= maxTokenIn, CashLimit());
        _collectExact(msg.sender, collateral);
        _shareBacking[market] += collateral;
        _yesSupply[market] += amount;
        _noSupply[market] += amount;
        _credit(market, msg.sender, 1, amount);
        _credit(market, msg.sender, 0, amount);
        _emitInventory(market, msg.sender);
        emit Split(market, msg.sender, amount, collateral);
    }

    function merge(address market, uint256 amount, uint256 minTokenOut, uint64 validUntil)
        external
        override
        nonReentrant
        returns (uint256 collateral)
    {
        require(registeredMarkets[market], MarketNotActive());
        _checkAmount(amount);
        require(block.timestamp <= validUntil, InvalidOrderTerms());
        collateral = amount / shareUnit;
        require(collateral >= minTokenOut, CashLimit());
        _debitAvailable(market, msg.sender, 1, amount);
        _debitAvailable(market, msg.sender, 0, amount);
        _yesSupply[market] -= amount;
        _noSupply[market] -= amount;
        _shareBacking[market] -= collateral;
        _emitInventory(market, msg.sender);
        _pushExact(msg.sender, collateral);
        emit Merged(market, msg.sender, amount, collateral);
    }

    function placeOrder(address market, OrderParams calldata p)
        external
        override
        nonReentrant
        returns (OrderResult memory result)
    {
        uint64 expiry = _validateOrder(market, p);
        (uint8 side, uint16 tick) = BookLeg.normalize(p.action, p.outcome, p.priceTick);
        ExecutionPlan memory plan = _plan(market, p, side, tick);
        result.filled = p.amount - plan.remaining;
        require(
            !p.postOnly || (result.filled == 0 && plan.iterations < p.matchLimit),
            PostOnlyWouldTrade()
        );
        // An exhausted matching budget does not prove that the other side is
        // uncrossed. Discard the unfilled remainder instead of resting through it.
        uint128 resting = p.rest && plan.iterations < p.matchLimit
            && plan.remaining >= _minRestingOrder(p.priceTick)
            ? plan.remaining
            : 0;
        require(result.filled > 0 || resting > 0, NothingFilled());
        uint256 restingCash = p.action == BookLeg.BUY
            ? BookLeg.reserveCash(p.priceTick, resting, shareUnit)
            : 0;
        result.fee =
            BookLeg.feeNative(plan.feeBasis, feeVault.feeBpsOf(market), shareUnit);
        uint256 owed = plan.tokenIn + restingCash + result.fee;
        result.tokenIn = owed > plan.tokenOut ? owed - plan.tokenOut : 0;
        result.tokenOut = plan.tokenOut > owed ? plan.tokenOut - owed : 0;
        require(
            result.tokenIn <= p.maxTokenIn && result.tokenOut >= p.minTokenOut,
            CashLimit()
        );

        // Cancellations can return the caller's existing deposit. Those independent
        // refunds are outside this action's cash bounds and reported execution cash.
        for (uint256 i; i < plan.count; ++i) {
            if (plan.steps[i].amount == 0) _cancelPlanned(plan.steps[i].orderId);
        }
        if (result.tokenIn > 0) _collectExact(msg.sender, result.tokenIn);
        for (uint256 i; i < plan.count; ++i) {
            if (plan.steps[i].amount > 0) _applyFill(market, p, plan.steps[i]);
        }
        if (resting > 0) {
            result.orderId = _rest(market, p, side, tick, resting, expiry, restingCash);
        }
        _emitInventory(market, msg.sender);
        if (result.tokenOut > 0) _pushExact(msg.sender, result.tokenOut);
        if (result.fee > 0) {
            baseToken.forceApprove(address(feeVault), result.fee);
            require(
                feeVault.depositRevenue(market, result.fee, msg.sender) == result.fee,
                TransferAmountMismatch()
            );
        }
        _emitExecution(market, p, result);
    }

    function _emitExecution(
        address market,
        OrderParams calldata p,
        OrderResult memory result
    ) private {
        emit OrderExecuted(
            market,
            msg.sender,
            p.action,
            p.outcome,
            result.filled,
            result.orderId,
            result.tokenIn,
            result.tokenOut,
            result.fee
        );
    }

    function _validateOrder(address market, OrderParams calldata p)
        private
        view
        returns (uint64 expiry)
    {
        _requireTradingOpen(market);
        require(
            p.action <= 1 && p.outcome <= 1 && p.matchLimit > 0 && p.matchLimit <= 256
                && block.timestamp <= p.validUntil && p.maxTokenIn != type(uint256).max
                && (!p.postOnly || p.rest),
            InvalidOrderTerms()
        );
        _checkTick(p.priceTick);
        _checkAmount(p.amount);
        uint64 deadline = ITruthMarket(market).deadline();
        expiry = p.expiry == 0 ? deadline : p.expiry;
        require(expiry > block.timestamp && expiry <= deadline, InvalidExpiry());
        if (p.action == BookLeg.SELL) {
            require(
                _available(market, msg.sender, p.outcome) >= p.amount,
                InsufficientInventory()
            );
        }
    }

    function _plan(address market, OrderParams calldata p, uint8 side, uint16 limit)
        private
        view
        returns (ExecutionPlan memory plan)
    {
        plan.steps = new MatchStep[](p.matchLimit);
        plan.remaining = p.amount;
        uint8 makerSide = side == BookLeg.SIDE_BID ? BookLeg.SIDE_ASK : BookLeg.SIDE_BID;
        uint16 tick = makerSide == BookLeg.SIDE_ASK
            ? _bitmaps[market][makerSide].findNextUp(0)
            : _bitmaps[market][makerSide].findNextDown(NUM_TICKS);
        while (tick <= MAX_TICK && plan.remaining > 0 && plan.iterations < p.matchLimit) {
            if (side == BookLeg.SIDE_BID ? tick > limit : tick < limit) break;
            _planTick(market, p, makerSide, tick, plan);
            tick = makerSide == BookLeg.SIDE_ASK
                ? _bitmaps[market][makerSide].findNextUp(tick)
                : _bitmaps[market][makerSide].findNextDown(tick);
        }
    }

    function _planTick(
        address market,
        OrderParams calldata p,
        uint8 makerSide,
        uint16 tick,
        ExecutionPlan memory plan
    ) private view {
        LiveList storage list = _live[market][makerSide][tick];
        if (list.count == 0) return;
        uint32 cursor = list.head;
        while (plan.remaining > 0 && plan.iterations < p.matchLimit) {
            bool last = cursor == list.tail;
            _planEntry(market, p, makerSide, tick, cursor, plan);
            if (last) break;
            cursor = _orders[market][makerSide][tick][cursor].next;
        }
    }

    /// @dev Records one live entry. Spent orders are unlinked, so they are not visited.
    function _planEntry(
        address market,
        OrderParams calldata p,
        uint8 makerSide,
        uint16 tick,
        uint32 cursor,
        ExecutionPlan memory plan
    ) private view {
        Order storage maker = _orders[market][makerSide][tick][cursor];
        if (maker.amount == 0) return;
        ++plan.iterations;
        if (maker.expiry <= block.timestamp || maker.maker == msg.sender) {
            plan.steps[plan.count++] = MatchStep(maker.id, 0, 0);
            return;
        }
        uint128 fill = plan.remaining < maker.amount ? plan.remaining : maker.amount;
        uint256 cash = BookLeg.makerCash(
            maker.action,
            BookLeg.outcomeTick(maker.outcome, tick),
            maker.originalAmount,
            maker.amount,
            fill,
            maker.cashReserved,
            shareUnit
        );
        plan.steps[plan.count++] = MatchStep(maker.id, fill, cash);
        uint256 nativeShares = uint256(fill) / shareUnit;
        if (p.action == BookLeg.BUY) {
            plan.tokenIn += maker.action == BookLeg.BUY ? nativeShares - cash : cash;
        } else {
            plan.tokenOut += maker.action == BookLeg.SELL ? nativeShares - cash : cash;
        }
        plan.feeBasis += uint256(fill)
        * (tick < NUM_TICKS - tick ? tick : NUM_TICKS - tick);
        plan.remaining -= fill;
    }

    function _applyFill(address market, OrderParams calldata p, MatchStep memory step)
        private
    {
        OrderPointer memory pointer = _orderPointers[step.orderId];
        Order storage maker = _orders[market][pointer.side][pointer.tick][pointer.index];
        uint8 kind;
        if (maker.action == BookLeg.BUY) {
            maker.cashReserved -= step.makerCash;
            _orderCash[market] -= step.makerCash;
            _inventory[market][maker.maker].cashReserved -= step.makerCash;
            if (p.action == BookLeg.BUY) {
                kind = 2;
                _shareBacking[market] += uint256(step.amount) / shareUnit;
                _yesSupply[market] += step.amount;
                _noSupply[market] += step.amount;
                _credit(market, msg.sender, p.outcome, step.amount);
            } else {
                kind = p.outcome == 1 ? 0 : 1;
                _debitAvailable(market, msg.sender, p.outcome, step.amount);
            }
            _credit(market, maker.maker, maker.outcome, step.amount);
        } else {
            _unreserve(market, maker.maker, maker.outcome, step.amount);
            _debitAvailable(market, maker.maker, maker.outcome, step.amount);
            if (p.action == BookLeg.BUY) {
                kind = p.outcome == 1 ? 0 : 1;
                _credit(market, msg.sender, p.outcome, step.amount);
            } else {
                kind = 3;
                _debitAvailable(market, msg.sender, p.outcome, step.amount);
                _yesSupply[market] -= step.amount;
                _noSupply[market] -= step.amount;
                _shareBacking[market] -= uint256(step.amount) / shareUnit;
            }
        }
        maker.amount -= step.amount;
        if (maker.amount == 0) {
            _unlinkLive(market, pointer.side, pointer.tick, pointer.index);
        }
        ++fillCount;
        emit OrderFilled(
            market,
            maker.id,
            msg.sender,
            step.amount,
            pointer.tick,
            kind,
            maker.amount,
            maker.cashReserved
        );
        address makerAddress = maker.maker;
        bool paysMaker = maker.action == BookLeg.SELL;
        _emitInventory(market, makerAddress);
        if (maker.amount == 0) {
            delete _orderPointers[maker.id];
            _advanceHead(market, pointer.side, pointer.tick, MAX_HEAD_ADVANCE);
        }
        if (paysMaker && step.makerCash > 0) _pushOrDefer(makerAddress, step.makerCash);
    }

    function _rest(
        address market,
        OrderParams calldata p,
        uint8 side,
        uint16 tick,
        uint128 amount,
        uint64 expiry,
        uint256 cash
    ) private returns (uint64 id) {
        id = ++_nextOrderId;
        uint32 index = _appendLive(market, side, tick, id, p, amount, expiry, cash);
        _orderPointers[id] = OrderPointer(market, side, tick, index, true);
        _makerOrders[market][side][tick][msg.sender].push(id);
        _bitmaps[market][side].setBit(tick);
        Inventory storage inv = _inventory[market][msg.sender];
        if (p.action == BookLeg.BUY) {
            inv.cashReserved += cash;
            _orderCash[market] += cash;
        } else if (p.outcome == 1) {
            inv.yesReserved += amount;
        } else {
            inv.noReserved += amount;
        }
        emit OrderPlaced(
            market, msg.sender, id, p.action, p.outcome, tick, amount, expiry, cash
        );
    }

    function _appendLive(
        address market,
        uint8 side,
        uint16 tick,
        uint64 id,
        OrderParams calldata p,
        uint128 amount,
        uint64 expiry,
        uint256 cash
    ) private returns (uint32 index) {
        Order[] storage queue = _orders[market][side][tick];
        uint256 length = queue.length;
        require(length < uint256(NIL), AmountTooLarge());
        index = uint32(length);
        LiveList storage list = _live[market][side][tick];
        uint32 prev = list.count == 0 ? NIL : list.tail;
        queue.push(
            Order({
                id: id,
                maker: msg.sender,
                amount: amount,
                originalAmount: amount,
                action: p.action,
                outcome: p.outcome,
                expiry: expiry,
                prev: prev,
                next: NIL,
                liveLink: true,
                cashReserved: cash
            })
        );
        if (list.count == 0) list.head = index;
        else queue[prev].next = index;
        list.tail = index;
        list.count += 1;
    }

    function cancelById(uint64 id) external override nonReentrant {
        OrderPointer memory pointer = _orderPointers[id];
        require(pointer.exists, OrderNotFound());
        require(
            _orders[pointer.market][pointer.side][pointer.tick][pointer.index].maker
                == msg.sender,
            NotAuthorized()
        );
        _cancelAtIndex(pointer.market, pointer.side, pointer.tick, pointer.index);
        _advanceHead(pointer.market, pointer.side, pointer.tick, MAX_HEAD_ADVANCE);
    }

    function cancel(address market, uint8 side, uint16 tick)
        external
        override
        nonReentrant
        returns (uint64 cancelledOrderId)
    {
        _checkSideTick(side, tick);
        uint64[] storage ids = _makerOrders[market][side][tick][msg.sender];
        uint256 cursor = _makerCursor[market][side][tick][msg.sender];
        require(cursor < ids.length, NothingToCancel());
        uint256 scanned;
        while (cursor < ids.length && scanned < MAX_MAKER_CANCEL_SCAN) {
            uint64 id = ids[cursor];
            ++cursor;
            ++scanned;
            if (_orderPointers[id].exists) {
                cancelledOrderId = id;
                break;
            }
        }
        // A progress-only call must succeed so its bounded scan is not rolled back.
        _makerCursor[market][side][tick][msg.sender] = cursor;
        if (cancelledOrderId != 0) {
            OrderPointer memory pointer = _orderPointers[cancelledOrderId];
            _cancelAtIndex(market, side, tick, pointer.index);
            _advanceHead(market, side, tick, MAX_HEAD_ADVANCE);
        }
        emit MakerCancelProgress(market, msg.sender, side, tick, cursor, cancelledOrderId);
    }

    function _cancelPlanned(uint64 id) private {
        OrderPointer memory pointer = _orderPointers[id];
        _cancelAtIndex(pointer.market, pointer.side, pointer.tick, pointer.index);
        _advanceHead(pointer.market, pointer.side, pointer.tick, MAX_HEAD_ADVANCE);
    }

    /// @dev Drops a spent order from the match list without moving its neighbors.
    function _unlinkLive(address market, uint8 side, uint16 tick, uint32 index) private {
        Order[] storage queue = _orders[market][side][tick];
        Order storage order = queue[index];
        if (!order.liveLink) return;
        order.liveLink = false;
        LiveList storage list = _live[market][side][tick];
        uint32 prev = order.prev;
        uint32 next = order.next;
        if (index == list.head) list.head = next;
        else queue[prev].next = next;
        if (index == list.tail) list.tail = prev;
        else queue[next].prev = prev;
        order.prev = NIL;
        order.next = NIL;
        list.count -= 1;
    }

    function _cancelAtIndex(address market, uint8 side, uint16 tick, uint256 index)
        private
    {
        _unlinkLive(market, side, tick, uint32(index));
        Order storage order = _orders[market][side][tick][index];
        uint128 amount = order.amount;
        uint256 cash = order.cashReserved;
        address maker = order.maker;
        uint64 id = order.id;
        order.amount = 0;
        order.cashReserved = 0;
        delete _orderPointers[id];
        if (order.action == BookLeg.BUY) {
            _orderCash[market] -= cash;
            _inventory[market][maker].cashReserved -= cash;
        } else {
            _unreserve(market, maker, order.outcome, amount);
        }
        emit OrderCancelled(market, maker, id, amount, cash);
        _emitInventory(market, maker);
        if (cash > 0) _pushOrDefer(maker, cash);
    }

    function advanceHead(address market, uint8 side, uint16 tick, uint256 maxSteps)
        external
        override
        nonReentrant
        returns (uint256 head)
    {
        _checkSideTick(side, tick);
        require(maxSteps > 0 && maxSteps <= 1024, InvalidOrderTerms());
        Order[] storage queue = _orders[market][side][tick];
        head = _orderHead[market][side][tick];
        uint256 steps;
        while (head < queue.length && steps < maxSteps) {
            if (queue[head].amount > 0) {
                if (queue[head].expiry > block.timestamp) break;
                _cancelAtIndex(market, side, tick, head);
            }
            ++head;
            ++steps;
        }
        _orderHead[market][side][tick] = head;
        _compact(market, side, tick);
        head = _orderHead[market][side][tick];
        emit HeadAdvanced(market, side, tick, head);
    }

    function _advanceHead(address market, uint8 side, uint16 tick, uint256 maxSteps)
        private
    {
        Order[] storage queue = _orders[market][side][tick];
        uint256 head = _orderHead[market][side][tick];
        uint256 steps;
        while (head < queue.length && queue[head].amount == 0 && steps < maxSteps) {
            ++head;
            ++steps;
        }
        _orderHead[market][side][tick] = head;
        _compact(market, side, tick);
    }

    function _compact(address market, uint8 side, uint16 tick) private {
        Order[] storage queue = _orders[market][side][tick];
        if (queue.length > 0 && _orderHead[market][side][tick] == queue.length) {
            _bitmaps[market][side].clearBit(tick);
            if (queue.length <= MAX_COMPACT_LENGTH) {
                delete _orders[market][side][tick];
                _orderHead[market][side][tick] = 0;
            }
        }
    }

    function settlePosition(address market)
        external
        override
        nonReentrant
        returns (uint256 payout)
    {
        require(registeredMarkets[market], MarketNotActive());
        require(ITruthMarket(market).isSettled(), MarketNotSettled());
        Inventory storage inv = _inventory[market][msg.sender];
        uint256 yes = inv.yesOwned - inv.yesReserved;
        uint256 no = inv.noOwned - inv.noReserved;
        require(yes > 0 || no > 0, NothingToRedeem());
        uint8 outcome = ITruthMarket(market).winningOutcome();
        if (outcome == 2) {
            uint8 previous = invalidRemainderOf[market][msg.sender];
            uint256 halfUnits = (yes + no) / shareUnit + previous;
            payout = halfUnits / 2;
            uint8 remainder = uint8(halfUnits % 2);
            if (remainder != previous) {
                invalidRemainderOf[market][msg.sender] = remainder;
                emit InvalidRemainderChanged(market, msg.sender, remainder);
            }
        } else {
            payout = (outcome == 1 ? yes : no) / shareUnit;
        }
        inv.yesOwned -= yes;
        inv.noOwned -= no;
        _yesSupply[market] -= yes;
        _noSupply[market] -= no;
        _shareBacking[market] -= payout;
        _emitInventory(market, msg.sender);
        _pushExact(msg.sender, payout);
        emit PositionSettled(market, msg.sender, payout);
    }

    function claimDeferred() external override nonReentrant returns (uint256 amount) {
        amount = _deferred[msg.sender];
        require(amount > 0, NothingDeferred());
        delete _deferred[msg.sender];
        _totalDeferred -= amount;
        _pushExact(msg.sender, amount);
        emit DeferredClaimed(msg.sender, amount);
    }

    function getInventory(address market, address user)
        external
        view
        override
        returns (
            uint256 yesOwned,
            uint256 noOwned,
            uint256 yesReserved,
            uint256 noReserved,
            uint256 cashReserved
        )
    {
        Inventory storage inv = _inventory[market][user];
        return
            (inv.yesOwned, inv.noOwned, inv.yesReserved, inv.noReserved, inv.cashReserved);
    }

    function getPosition(address market, address user)
        public
        view
        override
        returns (uint256 yesShares, uint256 noShares)
    {
        Inventory storage inv = _inventory[market][user];
        return (inv.yesOwned, inv.noOwned);
    }

    function getBalance(address market, address user)
        external
        view
        returns (uint256 yes, uint256 no)
    {
        return getPosition(market, user);
    }

    function getNet(address market, address user)
        external
        view
        override
        returns (int256)
    {
        Inventory storage inv = _inventory[market][user];
        return int256(inv.yesOwned) - int256(inv.noOwned);
    }

    function getSupplies(address market)
        external
        view
        override
        returns (uint256 yesSupply, uint256 noSupply)
    {
        return (_yesSupply[market], _noSupply[market]);
    }

    function getOrder(uint64 id)
        external
        view
        override
        returns (OrderView memory result)
    {
        OrderPointer memory pointer = _orderPointers[id];
        if (!pointer.exists) return result;
        Order storage order =
            _orders[pointer.market][pointer.side][pointer.tick][pointer.index];
        return OrderView(
            pointer.market,
            order.maker,
            order.action,
            order.outcome,
            pointer.tick,
            order.amount,
            order.expiry,
            order.cashReserved
        );
    }

    function getCollateralBacking(address market) public view override returns (uint256) {
        return _shareBacking[market] + _orderCash[market];
    }

    function getShareBacking(address market) external view returns (uint256) {
        return _shareBacking[market];
    }

    function getOrderCash(address market) external view returns (uint256) {
        return _orderCash[market];
    }

    function deferredOf(address user) external view returns (uint256) {
        return _deferred[user];
    }

    function totalDeferred() external view returns (uint256) {
        return _totalDeferred;
    }

    function isMarketRegistered(address market) public view override returns (bool) {
        return registeredMarkets[market];
    }

    function requireBeforeDeadline(address market) external view override {
        _requireTradingOpen(market);
    }

    /// @notice BID=0 / ASK=1, both on the YES axis; 1000 means empty.
    function getBestTick(address market, uint8 side) external view returns (uint16) {
        require(side <= 1, InvalidSide());
        return _findBestActiveTick(market, side);
    }

    function getOrdersAtTick(address market, uint8 side, uint16 tick)
        external
        view
        returns (uint256 totalAmount, uint256 orderCount)
    {
        _checkSideTick(side, tick);
        Order[] storage queue = _orders[market][side][tick];
        for (uint256 i = _orderHead[market][side][tick]; i < queue.length; ++i) {
            if (queue[i].amount > 0 && queue[i].expiry > block.timestamp) {
                totalAmount += queue[i].amount;
                ++orderCount;
            }
        }
    }

    function getImpliedPrice(address market)
        external
        view
        returns (uint256 yesPrice, uint256 noPrice)
    {
        uint16 ask = _findBestActiveTick(market, BookLeg.SIDE_ASK);
        uint16 bid = _findBestActiveTick(market, BookLeg.SIDE_BID);
        if (ask <= MAX_TICK) yesPrice = uint256(ask) * WAD / NUM_TICKS;
        if (bid <= MAX_TICK) noPrice = (NUM_TICKS - uint256(bid)) * WAD / NUM_TICKS;
    }

    function getMinRestingOrder(uint16 priceTick) external view returns (uint128) {
        _checkTick(priceTick);
        return _minRestingOrder(priceTick);
    }

    function _minRestingOrder(uint16 priceTick) private view returns (uint128) {
        return uint128(((uint256(NUM_TICKS) + priceTick - 1) / priceTick) * shareUnit);
    }

    function _findBestActiveTick(address market, uint8 side)
        private
        view
        returns (uint16 tick)
    {
        tick = side == BookLeg.SIDE_ASK
            ? _bitmaps[market][side].findNextUp(0)
            : _bitmaps[market][side].findNextDown(NUM_TICKS);
        while (tick <= MAX_TICK) {
            Order[] storage queue = _orders[market][side][tick];
            for (uint256 i = _orderHead[market][side][tick]; i < queue.length; ++i) {
                if (queue[i].amount > 0 && queue[i].expiry > block.timestamp) {
                    return tick;
                }
            }
            tick = side == BookLeg.SIDE_ASK
                ? _bitmaps[market][side].findNextUp(tick)
                : _bitmaps[market][side].findNextDown(tick);
        }
    }

    function _available(address market, address user, uint8 outcome)
        private
        view
        returns (uint256)
    {
        Inventory storage inv = _inventory[market][user];
        return
            outcome == 1 ? inv.yesOwned - inv.yesReserved : inv.noOwned - inv.noReserved;
    }

    function _credit(address market, address user, uint8 outcome, uint256 amount)
        private
    {
        Inventory storage inv = _inventory[market][user];
        if (outcome == 1) {
            inv.yesOwned += amount;
            require(inv.yesOwned <= uint256(type(int256).max), AmountTooLarge());
        } else {
            inv.noOwned += amount;
            require(inv.noOwned <= uint256(type(int256).max), AmountTooLarge());
        }
    }

    function _debitAvailable(address market, address user, uint8 outcome, uint256 amount)
        private
    {
        require(_available(market, user, outcome) >= amount, InsufficientInventory());
        Inventory storage inv = _inventory[market][user];
        if (outcome == 1) inv.yesOwned -= amount;
        else inv.noOwned -= amount;
    }

    function _unreserve(address market, address user, uint8 outcome, uint256 amount)
        private
    {
        Inventory storage inv = _inventory[market][user];
        if (outcome == 1) inv.yesReserved -= amount;
        else inv.noReserved -= amount;
    }

    function _emitInventory(address market, address user) private {
        Inventory storage inv = _inventory[market][user];
        emit InventoryChanged(
            market,
            user,
            inv.yesOwned,
            inv.noOwned,
            inv.yesReserved,
            inv.noReserved,
            inv.cashReserved
        );
    }

    function _checkAmount(uint256 amount) private view {
        require(amount > 0, ZeroAmount());
        require(
            amount <= type(uint128).max && amount % shareUnit == 0, InvalidShareAmount()
        );
    }

    function _checkTick(uint16 tick) private pure {
        require(tick > 0 && tick < NUM_TICKS, InvalidTick());
    }

    function _checkSideTick(uint8 side, uint16 tick) private pure {
        require(side <= 1, InvalidSide());
        _checkTick(tick);
    }

    function _requireTradingOpen(address market) private view {
        require(registeredMarkets[market], MarketNotActive());
        require(ITruthMarket(market).isTradingOpen(), MarketNotLive());
    }

    function _pushOrDefer(address to, uint256 amount) private {
        uint256 sourceBefore = baseToken.balanceOf(address(this));
        uint256 recipientBefore = baseToken.balanceOf(to);
        bool success = baseToken.trySafeTransfer(to, amount);
        if (success) {
            _checkPayout(to, amount, sourceBefore, recipientBefore);
            return;
        }
        require(
            baseToken.balanceOf(address(this)) == sourceBefore
                && baseToken.balanceOf(to) == recipientBefore,
            TransferAmountMismatch()
        );
        require(
            baseToken.balanceOf(address(this)) >= _totalDeferred + amount, PayoutFailed()
        );
        _deferred[to] += amount;
        _totalDeferred += amount;
        emit PayoutDeferred(to, amount);
    }

    function _pushExact(address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 sourceBefore = baseToken.balanceOf(address(this));
        uint256 recipientBefore = baseToken.balanceOf(to);
        baseToken.safeTransfer(to, amount);
        _checkPayout(to, amount, sourceBefore, recipientBefore);
    }

    function _checkPayout(
        address to,
        uint256 amount,
        uint256 sourceBefore,
        uint256 recipientBefore
    ) private view {
        uint256 sourceAfter = baseToken.balanceOf(address(this));
        uint256 recipientAfter = baseToken.balanceOf(to);
        require(
            sourceBefore >= sourceAfter && sourceBefore - sourceAfter == amount
                && recipientAfter >= recipientBefore
                && recipientAfter - recipientBefore == amount,
            TransferAmountMismatch()
        );
    }

    function _collectExact(address from, uint256 amount) private {
        uint256 beforeBalance = baseToken.balanceOf(address(this));
        uint256 payerBefore = baseToken.balanceOf(from);
        baseToken.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = baseToken.balanceOf(address(this));
        uint256 payerAfter = baseToken.balanceOf(from);
        require(
            afterBalance >= beforeBalance && afterBalance - beforeBalance == amount
                && payerBefore >= payerAfter && payerBefore - payerAfter == amount,
            TransferAmountMismatch()
        );
    }
}

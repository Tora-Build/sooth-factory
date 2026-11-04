// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// FROZEN 0.4.0 REFERENCE — TEST ONLY. DO NOT EDIT, DO NOT IMPORT FROM `src/`.
///
/// The 0.4.0 `OrderEngine`: two ladders, an `escrow` flag, `mint`/`merge`.
///
/// Source: `src/OrderEngine.sol` at an earlier revision
///         (`ce65c68`, 2026-09-21: the last two-ladder, escrow-flagged book).
///
/// `ce65c68` postdates `9644c31` ("port ADR-0008 stages 1 and 2") by six days, and
/// this file still carries stage 2's shadow net ledger: `_net` at :141, `getNet` at
/// :434, `_applyNet` at :1009. What makes it an independent oracle is not that it
/// predates the ADR but that `getNet` is absent from `test/reference/IOrderEngineV040.sol`,
/// so no test can read it — `BookDifferential` compares the new engine's `getNet`
/// against the OLD two-sided `getPosition` pair, which is computed from the two
/// ladders and not from the shadow. The representation being compared is genuinely
/// the two-ladder one.
/// Vendored: 2026-10-07, for `test/integration/BookDifferential.t.sol`, which
/// replays one operation sequence against this engine and the single-axis one and
/// asserts they agree. ADR-0008 stage 4 calls this the confidence gate: stage 3's
/// tests had to change alongside its code, so a green suite there proves only that
/// the tests match the implementation. This file is the independent oracle.
///
/// Mechanical edits, and nothing else:
///   1. `contract OrderEngine` renamed to `OrderEngineV040` and its interface
///      to `IOrderEngineV040`, so it can be deployed beside the real engine.
///   2. `./interfaces/` and `./libraries/` import paths rewritten to `src/`.
///      `IFeeVault`, `ITruthMarket` and `TickBitmap` are unchanged between
///      that commit and this branch, so they are the live ones, not copies —
///      verified with `git diff origin/main develop -- src/interfaces src/libraries`,
///      whose only hit is `IOrderEngine.sol` itself.
///   3. `@inheritdoc IOrderEngine` tags retargeted to the renamed interface.
///   No logic, constant, rounding rule or storage layout is touched.

import {IOrderEngineV040} from "./IOrderEngineV040.sol";
import {IFeeVaultLegacy as IFeeVault} from "./IFeeVaultLegacy.sol";
import {TickBitmap} from "src/libraries/TickBitmap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";

/**
 * @title OrderEngine
 * @notice The on-chain order book together with custody and settlement for the
 *         trades it matches.
 * @dev Users approve OrderEngine directly — single transfer, no intermediary custody.
 *
 *      Trading is on-chain only. The book (formerly SoothBook) and this custody
 *      ledger were separate contracts so that an off-chain CLOB operator could drive
 *      custody over an EIP-712 signed-order surface. ADR-0007 removed that surface,
 *      which left the split buying nothing but a cross-contract authorization
 *      boundary, so the two contracts were merged. There is no operator, no
 *      signature verification, and no filler role.
 *
 *      That merge is why the custody functions below are `internal` rather than
 *      external. They used to be `external onlyFiller` — only the book could reach
 *      them. Dropping the modifier without also dropping `external` would have left
 *      `creditShares` ungated, letting anyone credit themselves outcome shares
 *      against no collateral, and no behavioural test would have failed. See
 *      `test/unit/MergedBookAuthorization.t.sol`, which asserts their absence from
 *      the external ABI by selector.
 *
 *      User-facing mint() / merge() / settlePosition() handle their own collateral
 *      transfers; the internal deposit() / withdraw() move base tokens for resting
 *      order collateral and cancel refunds.
 *
 *      This engine holds settlement backing ONLY. The taker fee (non-escrow fills)
 *      is deposited whole to the FeeVault in this engine's own token at collection
 *      — there is no fee custody and no claim surface here.
 *
 *      FEE POLICY, stated because it is a decision and not an oversight: the book
 *      fee is a BUY-SIDE fee. `_fill` charges the taker only when `!takerEscrow`,
 *      and taking with escrow is how a holder sells — they surrender the opposite
 *      outcome's shares and receive cash. So sellers pay nothing. `mint()` charges
 *      no book fee either, which means minting a complete set and then selling one
 *      leg with escrow reproduces a taxed taker buy without the tax, at the cost of
 *      an extra transaction and the collateral for a full set in between.
 *
 *      That route is accepted (issue #1, P-1). `test/integration/EscrowFeeExemption.t.sol`
 *      pins it at 6- and 18-decimal book tokens so the policy cannot drift by
 *      accident in either direction. Do not silently start charging escrow takers.
 */
contract OrderEngineV040 is IOrderEngineV040, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using TickBitmap for TickBitmap.Bitmap;

    // ============================================
    // Types
    // ============================================

    struct Position {
        uint256 yesShares;
        uint256 noShares;
    }

    struct Order {
        uint64 id;
        address maker;
        uint128 amount; // shares remaining (WAD)
        bool escrow; // true = escrowing opposite outcome for exit
    }

    struct OrderPointer {
        address market;
        uint8 side;
        uint16 tick;
        uint32 index;
        bool exists;
    }

    // ============================================
    // Constants
    // ============================================

    uint256 private constant WAD = 1e18;
    uint16 private constant MIN_TICK = 1;
    uint16 private constant MAX_TICK = 999;
    uint16 private constant NUM_TICKS = 1000;
    uint256 private constant MAX_HEAD_ADVANCE = 32;
    uint256 private constant MAX_COMPACT_LENGTH = 32;

    // ============================================
    // Immutables
    // ============================================

    IERC20 public immutable override baseToken;
    uint256 private immutable _baseTokenUnitWad;
    address public immutable marketFactory;
    IFeeVault public immutable feeVault;

    // ============================================
    // State — custody and positions
    // ============================================

    mapping(address => bool) public registeredMarkets;
    mapping(address => uint256) private _collateralBacking;
    uint256 public fillCount;
    /// @notice Unified positions: market => user => Position
    mapping(address => mapping(address => Position)) private _positions;
    /// @notice Signed net position, maintained ALONGSIDE the two-sided ledger while the
    ///         single-axis migration is in flight (ADR-0008 stage 2). `net` is
    ///         `yesShares - noShares` by construction; a complete set is net-zero.
    ///         Stage 3 makes it the only ledger and deletes the pair above.
    mapping(address => mapping(address => int256)) private _net;

    // ============================================
    // State — order book
    // ============================================

    /// @dev market => side (0=NO, 1=YES) => tick => FIFO queue of resting orders.
    mapping(address => mapping(uint8 => mapping(uint16 => Order[]))) internal _orders;
    /// @dev FIFO head pointer, so filling never shifts the queue array.
    mapping(address => mapping(uint8 => mapping(uint16 => uint256))) internal _orderHead;
    /// @dev market => side => occupied-tick bitmap.
    mapping(address => mapping(uint8 => TickBitmap.Bitmap)) internal _bitmaps;
    /// @dev Stable id => location, for id-based cancel and lookup.
    mapping(uint64 => OrderPointer) private _orderPointers;
    /// @dev Per-maker placement history and cursor, so cancel() resolves through the
    ///      caller's own orders instead of scanning the shared queue (audit R2).
    mapping(
        address => mapping(uint8 => mapping(uint16 => mapping(address => uint64[])))
    ) private _makerOrders;
    mapping(
        address => mapping(uint8 => mapping(uint16 => mapping(address => uint256)))
    ) private _makerCursor;
    uint64 private _nextOrderId;

    event OrderPlaced(
        address indexed market,
        uint8 side,
        uint16 tick,
        address indexed maker,
        uint128 amount,
        bool escrow,
        uint64 orderId
    );
    event OrderFilled(
        address indexed market,
        uint8 takerSide,
        uint16 yesTick,
        uint16 noTick,
        address indexed taker,
        address indexed maker,
        uint128 amount,
        uint256 surplus,
        uint64 makerOrderId
    );
    event OrderCancelled(
        address indexed market,
        uint8 side,
        uint16 tick,
        address indexed maker,
        uint128 amount,
        uint64 orderId
    );
    event DustOrderSkipped(
        address indexed market,
        uint8 side,
        uint16 tick,
        address indexed user,
        uint128 amount,
        bool escrow
    );
    event Minted(address indexed market, address indexed user, uint256 amount);
    event Merged(address indexed market, address indexed user, uint256 amount);
    event PositionSettled(address indexed market, address indexed user, uint256 payout);

    error MarketNotActive();
    error MarketAlreadyExists();
    error OrderNotActive();
    error NotAuthorized();
    error ZeroAddress();
    error UnsupportedBaseTokenDecimals();
    error TicksDontCross();
    error SideMismatch();
    error MarketMismatch();
    error MarketNotRegistered();
    error MarketNotSettled();
    error ZeroAmount();
    error InsufficientShares();
    error NothingToRedeem();
    error AmountTooSmallForBaseTokenDecimals();
    error MarketNotLive();
    error MarketAlreadyRegistered();
    error TransferAmountMismatch();
    error InvalidSide();
    error InvalidTick();
    error AmountTooLarge();

    constructor(
        address _baseToken,
        address _marketFactory,
        address _feeVault,
        address _owner
    ) Ownable(_owner) {
        require(_baseToken != address(0), ZeroAddress());
        require(_marketFactory != address(0), ZeroAddress());
        require(_feeVault != address(0), ZeroAddress());
        uint8 decimals = IERC20Metadata(_baseToken).decimals();
        require(decimals <= 18, UnsupportedBaseTokenDecimals());

        baseToken = IERC20(_baseToken);
        _baseTokenUnitWad = 10 ** (18 - decimals);
        marketFactory = _marketFactory;
        feeVault = IFeeVault(_feeVault);
    }

    // ============================================
    // Admin
    // ============================================

    // ============================================
    // Market Registration
    // ============================================

    /// @inheritdoc IOrderEngineV040
    function registerMarket(address market, address, uint256 initialPrice)
        external
        override
    {
        require(msg.sender == marketFactory, NotAuthorized());
        require(!registeredMarkets[market], MarketAlreadyRegistered());

        // One contract, one registration: the book's state lives here, so there is no
        // second registration to notify and no partially wired stack to guard against.
        // This engine's custody token is its own immutable, so the caller-supplied
        // token parameter is ignored and the event carries the actual book token.
        registeredMarkets[market] = true;

        emit MarketRegistered(market, address(baseToken), initialPrice);
    }

    function mint(address market, uint256 amount) external override nonReentrant {
        require(registeredMarkets[market], MarketNotRegistered());
        _mint(market, msg.sender, amount);
    }

    function merge(address market, uint256 amount) external override nonReentrant {
        _merge(market, msg.sender, amount);
    }

    function settlePosition(address market)
        external
        nonReentrant
        returns (uint256 payout)
    {
        require(ITruthMarket(market).isSettled(), MarketNotSettled());

        Position storage pos = _positions[market][msg.sender];
        uint256 yesBal = pos.yesShares;
        uint256 noBal = pos.noShares;
        if (yesBal == 0 && noBal == 0) revert NothingToRedeem();

        uint8 outcome = ITruthMarket(market).winningOutcome();
        uint256 payoutWad;
        if (outcome == 2) {
            payoutWad = (yesBal + noBal) / 2;
        } else if (outcome == 1) {
            payoutWad = yesBal;
        } else {
            payoutWad = noBal;
        }

        pos.yesShares = 0;
        pos.noShares = 0;
        _net[market][msg.sender] = 0;

        payout = _wadToBaseUnits(payoutWad);
        if (payout > 0) {
            _collateralBacking[market] -= payout;
            baseToken.safeTransfer(msg.sender, payout);
        }

        emit PositionSettled(market, msg.sender, payout);
    }

    function buyYes(
        address market,
        uint16 tick,
        uint128 amount,
        bool escrow,
        uint32 matchLimit
    ) external nonReentrant {
        _buy(market, 1, tick, amount, escrow, matchLimit);
    }

    function buyNo(
        address market,
        uint16 tick,
        uint128 amount,
        bool escrow,
        uint32 matchLimit
    ) external nonReentrant {
        _buy(market, 0, tick, amount, escrow, matchLimit);
    }

    /// @notice Cancel the caller's earliest live order at a tick.
    /// @dev Resolves through the caller's own placement history rather than the
    ///      shared queue, so third-party padding between the head and the
    ///      caller's order cannot inflate the cost (audit R2). Dead ids (filled or
    ///      already cancelled) are skipped once and the cursor is persisted.
    ///      Semantics match `cancelById` on the same order.
    function cancel(address market, uint8 side, uint16 tick) external nonReentrant {
        Order[] storage queue = _orders[market][side][tick];
        uint64[] storage ids = _makerOrders[market][side][tick][msg.sender];
        uint256 cursor = _makerCursor[market][side][tick][msg.sender];

        bool found;
        uint256 idx;
        while (cursor < ids.length) {
            OrderPointer storage pointer = _orderPointers[ids[cursor]];
            // The pointer is deleted on full fill and on cancel, so a live
            // pointer whose queue slot still carries this id is a live order.
            if (pointer.exists && pointer.index < queue.length) {
                Order storage order = queue[pointer.index];
                if (order.id == ids[cursor] && order.amount > 0) {
                    found = true;
                    idx = pointer.index;
                    break;
                }
            }
            unchecked {
                cursor++;
            }
        }
        _makerCursor[market][side][tick][msg.sender] = cursor;
        if (!found) revert OrderNotActive();

        _cancelAtIndex(market, side, tick, idx);
    }

    function cancelById(uint64 orderId) external nonReentrant {
        OrderPointer memory pointer = _orderPointers[orderId];
        if (!pointer.exists) revert OrderNotActive();

        Order[] storage queue = _orders[pointer.market][pointer.side][pointer.tick];
        uint256 idx = uint256(pointer.index);
        if (idx >= queue.length) revert OrderNotActive();

        Order storage order = queue[idx];
        if (order.id != orderId || order.maker != msg.sender || order.amount == 0) {
            revert OrderNotActive();
        }

        _cancelAtIndex(pointer.market, pointer.side, pointer.tick, idx);
    }

    /// @inheritdoc IOrderEngineV040
    function requireBeforeDeadline(address market) external view override {
        _requireTradingOpen(market);
    }

    function getBalance(address market, address user)
        external
        view
        returns (uint256 yes, uint256 no)
    {
        return getPosition(market, user);
    }

    function getImpliedPrice(address market)
        external
        view
        returns (uint256 yesPrice, uint256 noPrice)
    {
        return _impliedPrice(market);
    }

    function getBestTick(address market, uint8 side) external view returns (uint16) {
        return _findBestActiveTick(market, side);
    }

    function getOrdersAtTick(address market, uint8 side, uint16 tick)
        external
        view
        returns (uint256 totalAmount, uint256 orderCount)
    {
        Order[] storage queue = _orders[market][side][tick];
        uint256 head = _orderHead[market][side][tick];
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].amount > 0) {
                totalAmount += queue[i].amount;
                orderCount++;
            }
        }
    }

    function getMinRestingOrder(uint16 tick) external view returns (uint128) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
        return _minRestingOrderForTick(tick);
    }

    /// @notice Signed net position: positive is long YES, negative is long NO.
    /// @dev Maintained alongside the two-sided ledger during the single-axis migration
    ///      (ADR-0008). It becomes the only ledger at stage 3; `getPosition` stays as a
    ///      derived compat view, because client, indexer, web and arcade all read it.
    function getNet(address market, address user) external view returns (int256) {
        return _net[market][user];
    }

    /// @inheritdoc IOrderEngineV040
    function getCollateralBacking(address market) public view override returns (uint256) {
        return _collateralBacking[market];
    }

    /// @inheritdoc IOrderEngineV040
    function isMarketRegistered(address market) public view override returns (bool) {
        return registeredMarkets[market];
    }

    function getPosition(address market, address user)
        public
        view
        returns (uint256 yesShares, uint256 noShares)
    {
        Position storage pos = _positions[market][user];
        return (pos.yesShares, pos.noShares);
    }

    function _fill(
        address market,
        address taker,
        address maker,
        uint8 takerSide,
        uint128 shares,
        uint16 takerTick,
        uint16 makerTick,
        bool takerEscrow,
        bool makerEscrow
    ) internal returns (uint256 fillId) {
        _requireTradingOpen(market);

        if (!takerEscrow) {
            _collectTakerCostAndFee(market, taker, shares, takerTick, makerTick);
        }

        _settleEscrowAndSurplus(
            market, taker, maker, shares, takerTick, makerTick, takerEscrow, makerEscrow
        );

        fillId = ++fillCount;
        {
            uint16 yesTick = takerSide == 1 ? takerTick : makerTick;
            uint16 noTick = takerSide == 1 ? makerTick : takerTick;
            emit FillRecorded(
                market, taker, maker, takerSide, shares, yesTick, noTick, fillId
            );
        }
    }

    function _creditShares(address market, address to, uint8 outcome, uint256 amount)
        internal
    {
        _applyNet(market, to, outcome == 1, amount);
        if (outcome == 1) {
            _positions[market][to].yesShares += amount;
        } else {
            _positions[market][to].noShares += amount;
        }
    }

    function _debitShares(address market, address from, uint8 outcome, uint256 amount)
        internal
    {
        // A debited YES lowers the net; a debited NO raises it.
        _applyNet(market, from, outcome != 1, amount);
        Position storage pos = _positions[market][from];
        if (outcome == 1) {
            if (pos.yesShares < amount) revert InsufficientShares();
            pos.yesShares -= amount;
        } else {
            if (pos.noShares < amount) revert InsufficientShares();
            pos.noShares -= amount;
        }
    }

    function _creditMatchedShares(
        address market,
        address taker,
        address maker,
        uint8 takerSide,
        uint128 shares,
        bool takerEscrow,
        bool makerEscrow
    ) internal {
        if (!makerEscrow) {
            // `takerSide ^ 1` is bitwise XOR flipping 0↔1 to get the opposite
            // side — not exponentiation.
            // slither-disable-next-line incorrect-exp
            _creditShares(market, maker, takerSide ^ 1, shares);
        }
        if (!takerEscrow) {
            _creditShares(market, taker, takerSide, shares);
        }
    }

    function _mint(address market, address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _requireTradingOpen(market);

        uint256 collateralIn = _wadToBaseUnitsCeil(amount);
        if (collateralIn == 0) revert AmountTooSmallForBaseTokenDecimals();

        _collectExact(user, collateralIn);
        _collateralBacking[market] += collateralIn;

        // A complete set is net-zero: both sides move together, so `_net` is
        // unchanged here. That is precisely why the ledger swap and the mint/merge
        // deletion cannot be separated (ADR-0008 staging note 2).
        _positions[market][user].yesShares += amount;
        _positions[market][user].noShares += amount;

        emit Minted(market, user, amount);
    }

    function _merge(address market, address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        Position storage pos = _positions[market][user];
        if (pos.yesShares < amount || pos.noShares < amount) revert InsufficientShares();

        pos.yesShares -= amount;
        pos.noShares -= amount;

        uint256 collateralOut = _wadToBaseUnits(amount);
        if (collateralOut == 0) revert AmountTooSmallForBaseTokenDecimals();

        _collateralBacking[market] -= collateralOut;
        baseToken.safeTransfer(user, collateralOut);

        emit Merged(market, user, amount);
    }

    function _collectTakerCostAndFee(
        address market,
        address taker,
        uint128 shares,
        uint16 takerTick,
        uint16 makerTick
    ) internal {
        // Principal is collected at the taker's LIMIT, and the price-improvement
        // surplus is refunded in _settleEscrowAndSurplus. Ceil the WAD-domain tick
        // division (see maker-cost note): at 18 decimals the base-unit ceil is the
        // identity, so flooring here would under-back the set by 1 wei per fill.
        uint256 baseCostWad =
            (uint256(shares) * uint256(takerTick) + NUM_TICKS - 1) / NUM_TICKS;

        // The fee is charged on the price the fill EXECUTED at, never on the limit.
        // A taker's executed price is (NUM_TICKS - makerTick)/NUM_TICKS — exactly the
        // number _settleEscrowAndSurplus refunds the principal down to. Charging on
        // `takerTick` instead billed a taker for collateral they never spent, and
        // because the fee is pushed to the vault here, before that refund, nothing
        // downstream corrected it. A taker must widen their limit to reach more than
        // one price level, so the over-charge was systematic on every depth sweep,
        // not an exotic case: sweeping NO bids at 900/700/500 with buyYes(999) paid
        // 3.33x the correct fee, and a single maker at 999 taken at 999 paid ~10x the
        // executed notional. The crossing rule guarantees
        // takerTick + makerTick >= NUM_TICKS, so this basis is never larger than the
        // old one — the fee can only fall.
        uint256 executedCostWad =
            uint256(shares) * uint256(NUM_TICKS - makerTick) / NUM_TICKS;
        uint256 feeWad =
            (executedCostWad * uint256(feeVault.feeBpsOf(market, IFeeVault.Venue.BOOK)))
                / 10_000;

        // Backing collected rounds UP (never under-back the set); the fee to the
        // vault rounds DOWN (never over-charge the taker for revenue).
        uint256 takerBaseCost = _wadToBaseUnitsCeil(baseCostWad);
        uint256 feeBaseUnits = _wadToBaseUnits(feeWad);
        uint256 takerCostPlusFee = takerBaseCost + feeBaseUnits;
        require(takerCostPlusFee > 0, AmountTooSmallForBaseTokenDecimals());

        // `taker` reaches here only from this contract's own matching loop, so it
        // is a caller that placed or crossed an order — not an arbitrary address.
        _collectExact(taker, takerCostPlusFee);
        _collateralBacking[market] += takerBaseCost;

        if (feeBaseUnits == 0) return;

        // Dual-token: the whole book fee goes to the vault in the book's own
        // token (push-then-notify, pre-transfer snapshot) — never to the AMM.
        uint256 preBalance = baseToken.balanceOf(address(feeVault));
        baseToken.safeTransfer(address(feeVault), feeBaseUnits);
        feeVault.notifyDeposit(
            market, IFeeVault.Venue.BOOK, address(baseToken), feeBaseUnits, preBalance
        );
    }

    function fillOrder(
        address market,
        address taker,
        address maker,
        uint8 takerSide,
        uint128 shares,
        uint16 takerTick,
        uint16 makerTick,
        bool takerEscrow,
        bool makerEscrow
    ) internal returns (uint256 fillId) {
        require(registeredMarkets[market], MarketNotRegistered());
        // _creditMatchedShares collapses any side other than 1 into NO on both
        // legs. Every current caller passes a 0/1 literal; keep the invariant
        // independent of the caller rather than relying on that.
        if (takerSide > 1) revert InvalidSide();
        if (
            takerTick == 0 || takerTick >= NUM_TICKS || makerTick == 0
                || makerTick >= NUM_TICKS
        ) revert InvalidTick();
        fillId = _fill(
            market,
            taker,
            maker,
            takerSide,
            shares,
            takerTick,
            makerTick,
            takerEscrow,
            makerEscrow
        );

        _creditMatchedShares(
            market, taker, maker, takerSide, shares, takerEscrow, makerEscrow
        );
    }

    function creditShares(address market, address user, uint8 outcome, uint256 amount)
        internal
    {
        _creditShares(market, user, outcome, amount);
    }

    function debitSharesBeforeDeadline(
        address market,
        address user,
        uint8 outcome,
        uint256 amount
    ) internal {
        _requireTradingOpen(market);
        _debitShares(market, user, outcome, amount);
    }

    function deposit(address market, address from, uint256 baseUnits) internal {
        _requireTradingOpen(market);
        // `from` is forwarded by this contract's own book logic on behalf of a
        // user who has already approved this contract. This function is internal
        // (see the contract NatSpec), so `from` is never attacker-chosen.
        _collectExact(from, baseUnits);
        _collateralBacking[market] += baseUnits;
    }

    function withdraw(address market, address to, uint256 baseUnits) internal {
        if (baseUnits == 0) return;
        _collateralBacking[market] -= baseUnits;
        baseToken.safeTransfer(to, baseUnits);
    }

    function _cancelAtIndex(address market, uint8 side, uint16 tick, uint256 idx)
        internal
    {
        Order[] storage queue = _orders[market][side][tick];

        Order storage order = queue[idx];
        uint128 refundAmount = order.amount;
        bool wasEscrow = order.escrow;
        uint64 orderId = order.id;
        order.amount = 0;
        delete _orderPointers[orderId];

        _advanceHead(market, side, tick);

        if (_orderHead[market][side][tick] == queue.length) {
            _bitmaps[market][side].clearBit(tick);
            _compactTickIfExhausted(market, side, tick);
        }

        if (wasEscrow) {
            uint8 opposite = side == 1 ? 0 : 1;
            creditShares(market, msg.sender, opposite, refundAmount);
        } else {
            uint256 refundWad = (uint256(refundAmount) * uint256(tick)) / NUM_TICKS;
            uint256 refund = _wadToBaseUnits(refundWad);
            withdraw(market, msg.sender, refund);
        }

        emit OrderCancelled(market, side, tick, msg.sender, refundAmount, orderId);
    }

    function _buy(
        address market,
        uint8 side,
        uint16 tick,
        uint128 amount,
        bool escrow,
        uint32 matchLimit
    ) internal {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
        if (amount == 0) revert ZeroAmount();
        if (!registeredMarkets[market]) revert MarketNotActive();

        if (escrow) {
            uint8 opposite = side == 1 ? 0 : 1;
            debitSharesBeforeDeadline(market, msg.sender, opposite, amount);
        }

        uint128 remaining = _match(market, side, tick, amount, escrow, matchLimit);

        if (remaining == 0) return;

        // Skip dust remainder
        uint16 valueTick = escrow ? (NUM_TICKS - tick) : tick;
        if (remaining < _minRestingOrderForTick(valueTick)) {
            if (escrow) {
                uint8 opposite = side == 1 ? 0 : 1;
                creditShares(market, msg.sender, opposite, remaining);
            }
            emit DustOrderSkipped(market, side, tick, msg.sender, remaining, escrow);
            return;
        }

        // Deposit resting remainder cost into OrderEngine (pulled directly from user)
        if (!escrow) {
            uint256 restingCostWad = (uint256(remaining) * uint256(tick)) / NUM_TICKS;
            uint256 restingCost = _wadToBaseUnitsCeil(restingCostWad);
            if (restingCost > 0) {
                deposit(market, msg.sender, restingCost);
            }
        }

        // Rest goes on the book
        uint64 orderId = ++_nextOrderId;
        uint32 orderIndex = uint32(_orders[market][side][tick].length);
        _orders[market][side][tick].push(
            Order({id: orderId, maker: msg.sender, amount: remaining, escrow: escrow})
        );
        _orderPointers[orderId] = OrderPointer({
            market: market, side: side, tick: tick, index: orderIndex, exists: true
        });
        _makerOrders[market][side][tick][msg.sender].push(orderId);
        if (!_bitmaps[market][side].isSet(tick)) {
            _bitmaps[market][side].setBit(tick);
        }
        emit OrderPlaced(market, side, tick, msg.sender, remaining, escrow, orderId);
    }

    function _match(
        address market,
        uint8 takerSide,
        uint16 takerTick,
        uint128 amount,
        bool takerEscrow,
        uint32 matchLimit
    ) internal returns (uint128 remaining) {
        remaining = amount;
        if (matchLimit == 0) matchLimit = type(uint32).max;

        // takerTick is validated in [MIN_TICK, MAX_TICK] by the caller, so
        // minOppTick = NUM_TICKS - takerTick is always in [1, MAX_TICK].
        uint16 minOppTick = NUM_TICKS - takerTick;

        // `takerSide ^ 1` is bitwise XOR flipping 0↔1 for the opposite side.
        // slither-disable-next-line incorrect-exp
        uint16 oppTick = _bitmaps[market][takerSide ^ 1].findNextDown(NUM_TICKS);
        if (oppTick > MAX_TICK) return remaining;

        while (remaining > 0 && oppTick >= minOppTick && oppTick <= MAX_TICK) {
            (remaining, matchLimit) = _matchTick(
                market, takerSide, takerTick, oppTick, remaining, takerEscrow, matchLimit
            );

            if (matchLimit == 0) break;
            if (oppTick == 0) break;
            // slither-disable-next-line incorrect-exp
            oppTick = _bitmaps[market][takerSide ^ 1].findNextDown(oppTick);
            if (oppTick > MAX_TICK) break;
        }
    }

    function _matchTick(
        address market,
        uint8 takerSide,
        uint16 takerTick,
        uint16 oppTick,
        uint128 remaining,
        bool takerEscrow,
        uint32 matchLimit
    ) internal returns (uint128, uint32) {
        // slither-disable-next-line incorrect-exp
        uint8 ms = takerSide ^ 1;
        Order[] storage queue = _orders[market][ms][oppTick];
        uint256 head = _orderHead[market][ms][oppTick];

        while (remaining > 0 && head < queue.length && matchLimit > 0) {
            // Every iteration counts against matchLimit, including skips over
            // zeroed (cancelled) interior entries. Otherwise a griefer can pad a
            // tick with cancelled orders behind a live blocker and force every
            // crossing taker to walk them for free — an unbounded-gas DoS of the
            // tick. Bounding here makes the walk resumable across calls via the
            // persisted head pointer instead.
            unchecked {
                matchLimit--;
            }

            Order storage maker = queue[head];
            if (maker.amount == 0) {
                head++;
                continue;
            }

            uint128 fill = remaining < maker.amount ? remaining : maker.amount;
            _settleFill(market, takerSide, takerTick, oppTick, fill, takerEscrow, maker);

            maker.amount -= fill;
            remaining -= fill;

            if (maker.amount == 0) {
                delete _orderPointers[maker.id];
                head++;
            }
        }

        _orderHead[market][ms][oppTick] = head;

        if (head == queue.length) {
            _bitmaps[market][ms].clearBit(oppTick);
            _compactTickIfExhausted(market, ms, oppTick);
        }

        return (remaining, matchLimit);
    }

    function _settleFill(
        address market,
        uint8 takerSide,
        uint16 takerTick,
        uint16 oppTick,
        uint128 fill,
        bool takerEscrow,
        Order storage maker
    ) internal {
        // Atomic fill — OrderEngine handles token movement + fee routing
        fillOrder(
            market,
            msg.sender,
            maker.maker,
            takerSide,
            fill,
            takerTick,
            oppTick,
            takerEscrow,
            maker.escrow
        );

        uint16 yesTick = takerSide == 1 ? takerTick : oppTick;
        uint16 noTick = takerSide == 1 ? oppTick : takerTick;
        uint256 surplusTicks = uint256(yesTick) + uint256(noTick);
        uint256 surplus;
        if (surplusTicks > NUM_TICKS) {
            surplus =
                _wadToBaseUnits((surplusTicks - NUM_TICKS) * uint256(fill) / NUM_TICKS);
        }

        emit OrderFilled(
            market,
            takerSide,
            yesTick,
            noTick,
            msg.sender,
            maker.maker,
            fill,
            surplus,
            maker.id
        );
    }

    /// @dev Bounded walk. An attacker can pad a tick with cancelled entries behind
    ///      a victim's live head order; the victim's later cancel would otherwise
    ///      walk every one of them. Leaving the head on a zeroed entry is safe:
    ///      `_matchTick` skips zeroed entries (each counted against matchLimit) and
    ///      the next cancel or fill resumes from the persisted head.
    function _advanceHead(address market, uint8 side, uint16 tick) internal {
        Order[] storage queue = _orders[market][side][tick];
        uint256 head = _orderHead[market][side][tick];
        uint256 steps;
        while (
            head < queue.length && queue[head].amount == 0 && steps < MAX_HEAD_ADVANCE
        ) {
            unchecked {
                head++;
                steps++;
            }
        }
        _orderHead[market][side][tick] = head;
    }

    /// @dev Reclaim storage only for short queues. Deleting a long exhausted
    ///      array costs gas linear in its length and is the second half of the
    ///      cancel-gas grief; a long exhausted queue keeps `head == length`, which
    ///      every reader already treats as empty, and new orders append after it.
    function _compactTickIfExhausted(address market, uint8 side, uint16 tick) internal {
        Order[] storage queue = _orders[market][side][tick];
        uint256 head = _orderHead[market][side][tick];
        if (
            queue.length > 0 && head == queue.length && queue.length <= MAX_COMPACT_LENGTH
        ) {
            delete _orders[market][side][tick];
            _orderHead[market][side][tick] = 0;
        }
    }

    function _wadToBaseUnits(uint256 wadAmount) internal view returns (uint256) {
        return wadAmount / _baseTokenUnitWad;
    }

    /// @dev Inbound conversion: round UP so collateral collected always covers
    ///      the WAD obligation (a set is never under-backed by sub-unit dust).
    function _wadToBaseUnitsCeil(uint256 wadAmount) internal view returns (uint256) {
        return (wadAmount + _baseTokenUnitWad - 1) / _baseTokenUnitWad;
    }

    function _requireTradingOpen(address market) internal view {
        require(ITruthMarket(market).isTradingOpen(), MarketNotLive());
    }

    function _tickEmpty(address market, uint8 side, uint16 tick)
        internal
        view
        returns (bool)
    {
        Order[] storage queue = _orders[market][side][tick];
        uint256 head = _orderHead[market][side][tick];
        for (uint256 i = head; i < queue.length; i++) {
            if (queue[i].amount > 0) return false;
        }
        return true;
    }

    function _minRestingOrderForTick(uint16 tick) internal view returns (uint128) {
        uint256 minShares = (_baseTokenUnitWad * NUM_TICKS + tick - 1) / tick;
        return uint128(minShares);
    }

    function _findBestActiveTick(address market, uint8 side)
        internal
        view
        returns (uint16)
    {
        uint16 tick = _bitmaps[market][side].findNextDown(NUM_TICKS);
        while (tick <= MAX_TICK && _tickEmpty(market, side, tick)) {
            if (tick == 0) return NUM_TICKS;
            tick = _bitmaps[market][side].findNextDown(tick);
        }
        return tick;
    }

    function _impliedPrice(address market)
        internal
        view
        returns (uint256 yesPrice, uint256 noPrice)
    {
        uint16 bestYes = _findBestActiveTick(market, 1);
        uint16 bestNo = _findBestActiveTick(market, 0);

        if (bestYes <= MAX_TICK) {
            yesPrice = (uint256(bestYes) * WAD) / NUM_TICKS;
        }
        if (bestNo <= MAX_TICK) {
            noPrice = (uint256(bestNo) * WAD) / NUM_TICKS;
        }
    }

    /// @dev `long` credits the YES side, so it raises the net; otherwise it lowers it.
    function _applyNet(address market, address user, bool long, uint256 amount) private {
        require(amount <= uint256(type(int256).max), AmountTooLarge());
        _net[market][user] += long ? int256(amount) : -int256(amount);
    }

    /// @dev Fixed shares and signed amounts require exact native-unit receipts,
    ///      not partial credit. Existing donations or other markets' backing
    ///      cannot mask a short transfer. Token admission remains a separate gate.
    function _collectExact(address from, uint256 expectedNative) private {
        uint256 beforeBalance = baseToken.balanceOf(address(this));
        // `from` is either msg.sender or an address forwarded by this contract's
        // own book logic, which only ever forwards an order's own owner.
        // slither-disable-next-line arbitrary-send-erc20
        baseToken.safeTransferFrom(from, address(this), expectedNative);
        uint256 afterBalance = baseToken.balanceOf(address(this));
        require(afterBalance >= beforeBalance, TransferAmountMismatch());
        require(afterBalance - beforeBalance == expectedNative, TransferAmountMismatch());
    }

    function _settleEscrowAndSurplus(
        address market,
        address taker,
        address maker,
        uint128 shares,
        uint16 takerTick,
        uint16 makerTick,
        bool takerEscrow,
        bool makerEscrow
    ) private {
        uint256 totalDeduct;
        uint256 takerPayoutTotal;

        if (makerEscrow) {
            uint256 makerPayout = _wadToBaseUnits(
                uint256(NUM_TICKS - makerTick) * uint256(shares) / NUM_TICKS
            );
            if (makerPayout > 0) {
                totalDeduct += makerPayout;
                baseToken.safeTransfer(maker, makerPayout);
            }
        }

        if (takerEscrow) {
            uint256 takerPayout = _wadToBaseUnits(
                uint256(NUM_TICKS - takerTick) * uint256(shares) / NUM_TICKS
            );
            if (takerPayout > 0) {
                takerPayoutTotal += takerPayout;
            }
        }

        uint256 surplusTicks = uint256(takerTick) + uint256(makerTick);
        if (surplusTicks > NUM_TICKS) {
            uint256 surplus =
                _wadToBaseUnits((surplusTicks - NUM_TICKS) * uint256(shares) / NUM_TICKS);
            if (surplus > 0) {
                takerPayoutTotal += surplus;
            }
        }

        if (takerPayoutTotal > 0) {
            totalDeduct += takerPayoutTotal;
            baseToken.safeTransfer(taker, takerPayoutTotal);
        }

        if (totalDeduct > 0) {
            _collateralBacking[market] -= totalDeduct;
        }
    }
}

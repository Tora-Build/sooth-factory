// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {BookLeg} from "src/libraries/BookLeg.sol";

contract ListCash is ERC20 {
    constructor() ERC20("List cash", "LIST") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ListMarket {
    address public immutable marketFactory;
    uint64 public immutable deadline;

    constructor(address factory, uint64 deadline_) {
        marketFactory = factory;
        deadline = deadline_;
    }

    function isTradingOpen() external view returns (bool) {
        return block.timestamp < deadline;
    }
}

contract ListVault {
    ERC20 internal immutable token;

    constructor(ERC20 token_) {
        token = token_;
    }

    function feeBpsOf(address) external pure returns (uint16) {
        return 100;
    }

    function depositRevenue(address, uint256 amount, address) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), amount);
        return amount;
    }
}

/// @notice Handler over the real OrderEngine with stub market and fee vault.
/// @dev The per-tick live list is private. The handler reads the queue, the head
///      and the list from storage, and `checkLayout` proves those reads against
///      `getOrder`. Every placed order is first matched by a reference model that
///      reads only `amount`, `maker` and `expiry` in queue order. It does not read
///      the list links, so a broken link shows as a different fill.
contract LiveListHandler is Test {
    uint256 internal constant UNIT = 1e12;
    uint256 internal constant ORDERS_SLOT = 8;
    uint256 internal constant HEAD_SLOT = 9;
    uint256 internal constant LIVE_SLOT = 10;
    uint32 internal constant NIL = type(uint32).max;
    uint256 internal constant TICKS = 7;

    struct Entry {
        uint64 id;
        address maker;
        uint128 amount;
        uint64 expiry;
        uint32 prev;
        uint32 next;
        bool liveLink;
    }

    struct Model {
        uint128 remaining;
        uint256 iterations;
        uint256 cancels;
    }

    ListCash public cash;
    ListVault public vault;
    ListMarket public market;
    OrderEngine public book;
    address[4] public actors;
    uint64 public maxId;

    uint256 public placed;
    uint256 public filledOrders;
    uint256 public restedOrders;
    uint256 public cancelled;
    uint256 public spentRuns;
    uint256 public longestSpentRun;

    constructor() {
        cash = new ListCash();
        vault = new ListVault(cash);
        book = new OrderEngine(address(cash), address(this), address(vault));
        market = new ListMarket(address(this), uint64(block.timestamp + 60 days));
        book.registerMarket(address(market), address(cash), 0);
        for (uint256 i; i < 4; ++i) {
            actors[i] = address(uint160(0x11570 + i));
            cash.mint(actors[i], 1_000_000_000e6);
            vm.startPrank(actors[i]);
            cash.approve(address(book), type(uint256).max);
            book.split(address(market), 100_000 * UNIT, 100_000, uint64(block.timestamp));
            vm.stopPrank();
        }
    }

    // ── Storage reads ──

    function tickAt(uint256 i) public pure returns (uint16) {
        return [uint16(300), 400, 450, 500, 550, 600, 700][i % TICKS];
    }

    function _slot(uint256 root, uint8 side, uint16 tick)
        internal
        view
        returns (bytes32)
    {
        bytes32 a = keccak256(abi.encode(address(market), root));
        bytes32 b = keccak256(abi.encode(uint256(side), a));
        return keccak256(abi.encode(uint256(tick), b));
    }

    function queueLength(uint8 side, uint16 tick) public view returns (uint256) {
        return uint256(vm.load(address(book), _slot(ORDERS_SLOT, side, tick)));
    }

    function queueHead(uint8 side, uint16 tick) public view returns (uint256) {
        return uint256(vm.load(address(book), _slot(HEAD_SLOT, side, tick)));
    }

    function liveList(uint8 side, uint16 tick)
        public
        view
        returns (uint32 head, uint32 tail, uint32 count)
    {
        uint256 word = uint256(vm.load(address(book), _slot(LIVE_SLOT, side, tick)));
        head = uint32(word);
        tail = uint32(word >> 32);
        count = uint32(word >> 64);
    }

    function entry(uint8 side, uint16 tick, uint256 index)
        public
        view
        returns (Entry memory e)
    {
        uint256 base = uint256(keccak256(abi.encode(_slot(ORDERS_SLOT, side, tick))))
            + index * 4;
        uint256 w0 = uint256(vm.load(address(book), bytes32(base)));
        uint256 w1 = uint256(vm.load(address(book), bytes32(base + 1)));
        uint256 w2 = uint256(vm.load(address(book), bytes32(base + 2)));
        e.id = uint64(w0);
        e.maker = address(uint160(w0 >> 64));
        e.amount = uint128(w1);
        e.expiry = uint64(w2 >> 16);
        e.prev = uint32(w2 >> 80);
        e.next = uint32(w2 >> 112);
        e.liveLink = uint8(w2 >> 144) != 0;
    }

    // ── Actions ──

    function _actor(uint8 who) internal view returns (address) {
        return actors[who % 4];
    }

    function _bubblePanic(bytes memory data) internal pure {
        // A custom error is a refused order. A panic is a broken queue or list.
        if (data.length >= 4 && bytes4(data) == 0x4e487b71) {
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    function place(
        uint8 who,
        bool sell,
        bool yes,
        uint8 tickSeed,
        uint16 size,
        uint8 limitSeed,
        uint8 flags,
        uint32 life
    ) external {
        if (block.timestamp >= market.deadline()) return;
        address taker = _actor(who);
        IOrderEngine.OrderParams memory p;
        p.outcome = yes ? 1 : 0;
        p.action = sell ? 1 : 0;
        p.amount = uint128(bound(size, 1, 400) * UNIT);
        (uint8 side, uint16 yesTick) = (0, tickAt(tickSeed));
        // Choose the price on the YES axis so that orders land on the tick set.
        p.priceTick = yes ? yesTick : 1000 - yesTick;
        (side, yesTick) = BookLeg.normalize(p.action, p.outcome, p.priceTick);
        if (sell) {
            (uint256 yo, uint256 no, uint256 yr, uint256 nr,) =
                book.getInventory(address(market), taker);
            uint256 free = yes ? yo - yr : no - nr;
            if (free < p.amount) return;
        }
        p.matchLimit = limitSeed % 4 == 0 ? 256 : uint32(1 + limitSeed % 9);
        p.validUntil = uint64(block.timestamp);
        p.expiry =
            flags & 1 == 0 ? 0 : uint64(block.timestamp + 1 + bound(life, 0, 6 hours));
        if (p.expiry > market.deadline()) p.expiry = 0;
        p.rest = flags & 6 != 0;
        p.postOnly = p.rest && flags & 24 == 0;
        p.maxTokenIn = 1e15;

        Model memory m = _model(taker, side, yesTick, p.amount, p.matchLimit);
        uint128 expectedFill = p.amount - m.remaining;
        bool expectRest = p.rest && m.iterations < p.matchLimit
            && m.remaining >= book.getMinRestingOrder(p.priceTick);

        vm.prank(taker);
        try book.placeOrder(address(market), p) returns (
            IOrderEngine.OrderResult memory r
        ) {
            ++placed;
            assertEq(r.filled, expectedFill, "fill differs from price-time model");
            assertEq(r.orderId != 0, expectRest, "rest differs from model");
            assertFalse(
                p.postOnly && (expectedFill > 0 || m.iterations >= p.matchLimit),
                "post-only order traded"
            );
            if (r.filled > 0) ++filledOrders;
            if (r.orderId != 0) {
                ++restedOrders;
                maxId = r.orderId;
                IOrderEngine.OrderView memory o = book.getOrder(r.orderId);
                assertEq(o.amount, m.remaining, "rested amount");
            }
        } catch (bytes memory data) {
            _bubblePanic(data);
            // The model says something happens: the only refusals left are the
            // post-only rule and "nothing filled, nothing rested".
            if (expectedFill > 0 && !p.postOnly) {
                revert("a fillable order was refused");
            }
        }
    }

    /// @dev Reference matching: best price first, queue order inside a tick,
    ///      spent entries cost nothing, own and expired orders are cancelled.
    function _model(address taker, uint8 side, uint16 limit, uint128 amount, uint32 cap)
        internal
        view
        returns (Model memory m)
    {
        m.remaining = amount;
        uint8 makerSide = side == BookLeg.SIDE_BID ? BookLeg.SIDE_ASK : BookLeg.SIDE_BID;
        for (uint256 k; k < TICKS; ++k) {
            uint16 tick =
                makerSide == BookLeg.SIDE_ASK ? tickAt(k) : tickAt(TICKS - 1 - k);
            if (side == BookLeg.SIDE_BID ? tick > limit : tick < limit) break;
            uint256 length = queueLength(makerSide, tick);
            for (uint256 i; i < length; ++i) {
                if (m.remaining == 0 || m.iterations >= cap) return m;
                Entry memory e = entry(makerSide, tick, i);
                if (e.amount == 0) continue;
                ++m.iterations;
                if (e.expiry <= block.timestamp || e.maker == taker) {
                    ++m.cancels;
                    continue;
                }
                m.remaining -= m.remaining < e.amount ? m.remaining : e.amount;
            }
        }
    }

    function cancelById(uint64 seed) external {
        if (maxId == 0) return;
        uint64 id = uint64(bound(seed, 1, maxId));
        IOrderEngine.OrderView memory o = book.getOrder(id);
        if (o.maker == address(0)) return;
        vm.prank(o.maker);
        book.cancelById(id);
        ++cancelled;
    }

    function cancelAtTick(uint8 who, bool ask, uint8 tickSeed) external {
        vm.prank(_actor(who));
        try book.cancel(address(market), ask ? 1 : 0, tickAt(tickSeed)) returns (
            uint64 id
        ) {
            if (id != 0) ++cancelled;
        } catch (bytes memory data) {
            _bubblePanic(data);
        }
    }

    function advance(bool ask, uint8 tickSeed, uint16 steps) external {
        book.advanceHead(
            address(market), ask ? 1 : 0, tickAt(tickSeed), bound(steps, 1, 1024)
        );
    }

    /// @dev The L-1 shape: one live head, then a run of cancelled orders behind
    ///      it that the bounded head advance cannot remove, then a live tail.
    function spentRun(uint8 who, bool ask, uint8 tickSeed, uint8 length) external {
        if (block.timestamp >= market.deadline()) return;
        address maker = _actor(who);
        uint16 tick = tickAt(tickSeed);
        uint256 run = bound(length, 2, 70);
        IOrderEngine.OrderParams memory p;
        p.outcome = 1;
        p.action = ask ? 1 : 0;
        p.priceTick = tick;
        p.amount = uint128(4 * UNIT);
        p.matchLimit = 1;
        p.validUntil = uint64(block.timestamp);
        p.rest = true;
        p.postOnly = true;
        p.maxTokenIn = 1e15;
        uint64 first;
        uint64 last;
        vm.startPrank(maker);
        for (uint256 i; i < run + 2; ++i) {
            try book.placeOrder(address(market), p) returns (
                IOrderEngine.OrderResult memory r
            ) {
                if (first == 0) first = r.orderId;
                last = r.orderId;
            } catch (bytes memory data) {
                _bubblePanic(data);
                break; // the tick crosses the other side, or inventory ran out
            }
        }
        if (last > first + 1) {
            for (uint64 id = first + 1; id < last; ++id) {
                book.cancelById(id);
            }
            maxId = last;
            ++spentRuns;
            if (last - first - 1 > longestSpentRun) longestSpentRun = last - first - 1;
        } else if (last != 0) {
            maxId = last;
        }
        vm.stopPrank();
    }

    function warp(uint16 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 hours));
    }

    // ── Checks ──

    /// @dev The storage reads agree with the engine's own order view.
    function checkLayout() external view {
        uint256 liveSeen;
        for (uint8 side; side < 2; ++side) {
            for (uint256 k; k < TICKS; ++k) {
                uint256 length = queueLength(side, tickAt(k));
                for (uint256 i; i < length; ++i) {
                    Entry memory e = entry(side, tickAt(k), i);
                    IOrderEngine.OrderView memory o = book.getOrder(e.id);
                    if (e.amount == 0) {
                        assertEq(o.maker, address(0), "spent order still has a pointer");
                        continue;
                    }
                    ++liveSeen;
                    assertEq(o.maker, e.maker, "maker read");
                    assertEq(o.amount, e.amount, "amount read");
                    assertEq(o.expiry, e.expiry, "expiry read");
                    assertEq(o.yesTick, tickAt(k), "tick read");
                }
            }
        }
        uint256 liveIds;
        for (uint64 id = 1; id <= maxId; ++id) {
            if (book.getOrder(id).maker != address(0)) ++liveIds;
        }
        assertEq(liveSeen, liveIds, "live orders outside the scanned queues");
    }

    /// @dev The list holds exactly the unspent orders, in queue order.
    function checkLists() external view {
        for (uint8 side; side < 2; ++side) {
            for (uint256 k; k < TICKS; ++k) {
                _checkList(side, tickAt(k));
            }
        }
    }

    function _checkList(uint8 side, uint16 tick) internal view {
        uint256 length = queueLength(side, tick);
        uint256 qHead = queueHead(side, tick);
        (uint32 head, uint32 tail, uint32 count) = liveList(side, tick);
        assertLe(qHead, length, "head past the queue");
        uint256 live;
        uint32 previous = NIL;
        for (uint256 i; i < length; ++i) {
            Entry memory e = entry(side, tick, i);
            assertEq(e.liveLink, e.amount > 0, "linked flag differs from unspent");
            if (e.amount == 0) {
                assertEq(e.prev, NIL, "spent order keeps a prev link");
                assertEq(e.next, NIL, "spent order keeps a next link");
                continue;
            }
            assertGe(i, qHead, "unspent order below the head");
            if (live == 0) {
                assertEq(head, i, "list head is not the first unspent order");
            } else {
                assertEq(
                    entry(side, tick, previous).next, i, "next link skips or reorders"
                );
            }
            assertEq(e.prev, previous, "prev link");
            previous = uint32(i);
            ++live;
        }
        assertEq(count, live, "list count");
        if (live > 0) {
            assertEq(tail, previous, "list tail is not the last unspent order");
            assertEq(entry(side, tick, previous).next, NIL, "tail has a next link");
        }
    }

    /// @dev A resting order never crosses a live order on the other side, and
    ///      the bitmap finds every tick that holds an unexpired order.
    function checkBookShape() external view {
        uint16 bestBid;
        uint16 bestAsk = 1000;
        uint16 bestOpenBid = 1000;
        uint16 bestOpenAsk = 1000;
        for (uint256 k; k < TICKS; ++k) {
            uint16 tick = tickAt(k);
            (bool anyBid, bool openBid) = _has(0, tick);
            (bool anyAsk, bool openAsk) = _has(1, tick);
            if (anyBid) bestBid = tick;
            if (anyAsk && tick < bestAsk) bestAsk = tick;
            if (openBid) bestOpenBid = tick;
            if (openAsk && bestOpenAsk == 1000) bestOpenAsk = tick;
        }
        assertLt(bestBid, bestAsk, "book is crossed");
        assertEq(book.getBestTick(address(market), 0), bestOpenBid, "best bid tick");
        assertEq(book.getBestTick(address(market), 1), bestOpenAsk, "best ask tick");
    }

    function _has(uint8 side, uint16 tick) internal view returns (bool any, bool open) {
        uint256 length = queueLength(side, tick);
        for (uint256 i; i < length; ++i) {
            Entry memory e = entry(side, tick, i);
            if (e.amount == 0) continue;
            any = true;
            if (e.expiry > block.timestamp) return (true, true);
        }
    }

    function checkCustody() external view {
        assertEq(
            cash.balanceOf(address(book)),
            book.getShareBacking(address(market)) + book.getOrderCash(address(market))
                + book.totalDeferred(),
            "custody differs from liabilities"
        );
    }
}

contract BookLiveListInvariantTest is Test {
    LiveListHandler internal h;

    function setUp() public {
        h = new LiveListHandler();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = h.place.selector;
        selectors[1] = h.place.selector;
        selectors[2] = h.place.selector;
        selectors[3] = h.cancelById.selector;
        selectors[4] = h.cancelAtTick.selector;
        selectors[5] = h.advance.selector;
        selectors[6] = h.spentRun.selector;
        selectors[7] = h.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_liveListIsTheUnspentQueueAndTheBookIsUncrossed() public view {
        h.checkLayout();
        h.checkLists();
        h.checkBookShape();
        h.checkCustody();
    }

    function afterInvariant() public {
        emit log_named_uint("placed", h.placed());
        emit log_named_uint("filled", h.filledOrders());
        emit log_named_uint("rested", h.restedOrders());
        emit log_named_uint("cancelled", h.cancelled());
        emit log_named_uint("spent runs", h.spentRuns());
        emit log_named_uint("longest spent run", h.longestSpentRun());
    }

    /// The storage reads used by the invariants: one resting order sets the
    /// list to (head 0, tail 0, count 1) and its links to NIL.
    function test_layoutCanary() public {
        h.spentRun(0, false, 0, 2);
        uint16 tick = h.tickAt(0);
        assertEq(h.queueLength(0, tick), 4);
        (uint32 head, uint32 tail, uint32 count) = h.liveList(0, tick);
        assertEq(head, 0);
        assertEq(tail, 3);
        assertEq(count, 2);
        LiveListHandler.Entry memory first = h.entry(0, tick, 0);
        assertEq(first.next, 3, "the live head links past the spent run");
        assertEq(first.prev, type(uint32).max);
        assertTrue(first.liveLink);
        assertEq(h.entry(0, tick, 3).prev, 0);
        assertFalse(h.entry(0, tick, 1).liveLink);
        h.checkLayout();
        h.checkLists();
        h.checkBookShape();
    }

    /// A spent run longer than the old 512 skip cap sits behind a live head.
    /// A taker with a small match budget still reaches the order after it.
    function test_spentRunOfAnyLengthCostsTheTakerNothing() public {
        for (uint256 i; i < 9; ++i) {
            h.spentRun(0, true, 3, 70);
        }
        uint16 tick = h.tickAt(3);
        (,, uint32 count) = h.liveList(1, tick);
        assertEq(count, 18, "two live orders per run");
        assertGt(h.queueLength(1, tick), 512 + 18);
        // Actor 1 buys with a budget of 9 live orders, twice. Each call must
        // reach 9 orders of 4 shares: the spent runs between them cost nothing.
        h.place(1, false, true, 3, 36, 8, 0, 0);
        (,, count) = h.liveList(1, tick);
        assertEq(count, 9, "the first budget of 9 reached 9 live orders");
        h.place(1, false, true, 3, 36, 8, 0, 0);
        assertEq(h.filledOrders(), 2);
        (,, count) = h.liveList(1, tick);
        assertEq(count, 0, "every live order was reached");
        h.checkLists();
    }
}

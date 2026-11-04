// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";

/// @notice Audit round 2 (2026-10-08), the one finding that was still live at the
///         branch tip: `getOrdersAtTick` and `_findBestActiveTick` walk a tick's queue from
///         `head` to `queue.length` with no cap. `matchLimit` bounds the matching
///         loop and `MAX_HEAD_ADVANCE = 32` bounds automatic shared-head cleanup.
///         Tick cancellation separately bounds its caller-owned history scan.
///         Neither bounds these views, and no view advances `head`.
///
///         The state that makes it bite: every order at a tick is cancelled, and the
///         last cancel lands on queue index 0, so `_advanceHead` moves the head 32
///         entries and stops. The tick is now logically empty, its bitmap bit is
///         still set, and `head < queue.length`, so `_findBestActiveTick` walks the
///         whole zeroed remainder on every quote. Reads do not heal it: a crossing
///         taker or explicit `advanceHead` maintenance must move the prefix.
///
///         An earlier review justified the 32-step cap with
///         "leaving `head` on a zeroed entry is safe because every reader treats
///         `head == length` as empty". In this state `head != length`, and the
///         readers scan the gap instead.
///
///         Bounding a view is not a fix: it would make `getImpliedPrice` quote a
///         wrong price and `getOrdersAtTick` under-report depth. An O(1) live-order
///         count per tick would, but it charges every rest, fill and cancel to fix a
///         read path. The remedy taken (2026-10-08, owner decision) is
///         `advanceHead`: permissionless, it moves a stranded head past spent entries
///         at roughly one cold storage read each, against the ~230,000 gas per entry
///         the attacker paid to create them, and it costs no trade anything. The
///         first three tests pin the cost of the stranded state; the last two pin the
///         cure.
contract UnboundedPriceViewTest is DualTokenBase {
    /// Loose bounds, not tight assertions: absolute gas moves with the compiler, and
    /// what matters is the shape — two orders of magnitude between an empty book and
    /// a stranded tick that holds nothing.
    uint256 internal constant EMPTY_BOOK_CEILING = 60_000;
    uint256 internal constant STRANDED_500_FLOOR = 600_000;

    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    /// Rest `n` minimal YES asks at one tick from `n` distinct makers, then cancel
    /// them in reverse placement order so the final cancel is queue index 0.
    function _strandATick(uint16 yesTick, uint256 n) internal {
        uint16 noTick = 1000 - yesTick;
        for (uint256 i; i < n; ++i) {
            address maker = address(uint160(0xD0000 + i));
            usdc.mint(maker, 10e6);
            vm.startPrank(maker);
            usdc.approve(address(orderEngine), type(uint256).max);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, noTick, 1e18, 256));
            vm.stopPrank();
        }
        for (uint256 i = n; i > 0; --i) {
            vm.prank(address(uint160(0xD0000 + (i - 1))));
            orderEngine.cancel(market, 1, yesTick);
        }
    }

    function test_everyQuoteViewPaysForAStrandedTickThatHoldsNothing() public {
        uint256 g = gasleft();
        orderEngine.getImpliedPrice(market);
        uint256 baseline = g - gasleft();
        assertLt(baseline, EMPTY_BOOK_CEILING, "empty-book baseline");

        _strandATick(600, 500);

        // The tick is empty; all three views still walk the remaining 468 spent
        // entries after the final cancel's automatic 32-entry head advance.
        (uint256 amount, uint256 count) = orderEngine.getOrdersAtTick(market, 1, 600);
        assertEq(amount, 0, "no depth left at the tick");
        assertEq(count, 0, "no live orders left at the tick");

        g = gasleft();
        orderEngine.getImpliedPrice(market);
        uint256 impliedPrice = g - gasleft();
        g = gasleft();
        orderEngine.getOrdersAtTick(market, 1, 600);
        uint256 ordersAtTick = g - gasleft();
        g = gasleft();
        orderEngine.getBestTick(market, 1);
        uint256 bestTick = g - gasleft();

        emit log_named_uint("getImpliedPrice, empty book", baseline);
        emit log_named_uint("getImpliedPrice, 500 stranded", impliedPrice);
        emit log_named_uint("getOrdersAtTick, 500 stranded", ordersAtTick);
        emit log_named_uint("getBestTick,     500 stranded", bestTick);

        assertGt(impliedPrice, STRANDED_500_FLOOR, "getImpliedPrice scales with it");
        assertGt(ordersAtTick, STRANDED_500_FLOOR, "getOrdersAtTick scales with it");
        assertGt(bestTick, STRANDED_500_FLOOR, "getBestTick scales with it");
    }

    /// The consumer-visible failure: past some depth the node refuses the call and
    /// the UI gets no quote at all, rather than a slow one.
    function test_theQuoteStopsAnsweringUnderAnEthCallGasCap() public {
        _strandATick(600, 1600);

        (bool answeredAt3M,) = address(orderEngine).staticcall{gas: 3_000_000}(
            abi.encodeWithSignature("getImpliedPrice(address)", market)
        );
        (bool answeredAt20M,) = address(orderEngine).staticcall{gas: 20_000_000}(
            abi.encodeWithSignature("getImpliedPrice(address)", market)
        );

        assertFalse(answeredAt3M, "1600 stranded entries exceed a 3M eth_call budget");
        assertTrue(answeredAt20M, "and fit in 20M, so this is cost, not a revert");
    }

    /// Nothing a reader does advances `head`, and no crossing taker arrives in a
    /// one-sided market, so the cost persists. This is what rules out "it heals".
    function test_theCostPersistsWithoutACrossingTaker() public {
        _strandATick(600, 500);

        uint256 g = gasleft();
        orderEngine.getImpliedPrice(market);
        uint256 before = g - gasleft();

        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 300, 5e18, 256)); // activity, but at another tick

        g = gasleft();
        orderEngine.getImpliedPrice(market);
        uint256 later = g - gasleft();

        emit log_named_uint("before 5 days and a rest elsewhere", before);
        emit log_named_uint("after", later);
        assertGt(later, STRANDED_500_FLOOR, "five days of other activity clears none");
    }

    /// Two bounded permissionless calls clear the remaining 1,568 entries from the
    /// 1,600-order fixture, and every quote view is back to its empty-book cost.
    function test_advanceHeadRestoresTheQuoteViews() public {
        _strandATick(600, 1600);

        uint256 g = gasleft();
        orderEngine.advanceHead(market, 1, 600, 1024);
        orderEngine.advanceHead(market, 1, 600, 1024);
        uint256 cleanup = g - gasleft();
        emit log_named_uint("advanceHead over 1600 stranded entries", cleanup);

        g = gasleft();
        orderEngine.getImpliedPrice(market);
        uint256 after_ = g - gasleft();
        assertLt(after_, EMPTY_BOOK_CEILING, "quotes cost what an empty book costs");
        assertEq(orderEngine.getBestTick(market, 1), 1000, "and the tick is gone");
        (bool answeredAt3M,) = address(orderEngine).staticcall{gas: 3_000_000}(
            abi.encodeWithSignature("getImpliedPrice(address)", market)
        );
        assertTrue(answeredAt3M, "answers under the budget it failed before");
        // Cheaper to clear than to create by two orders of magnitude.
        assertLt(cleanup, 1600 * 5000, "well under 5,000 gas per entry to clear");
    }

    /// It skips only spent entries: a live order stops it, and its priority, depth
    /// and fill are untouched.
    function test_advanceHeadNeverSkipsALiveOrder() public {
        _strandATick(600, 40);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 5e18, 256)); // live ASK at 600, behind the spent run
        (uint256 depthBefore, uint256 countBefore) =
            orderEngine.getOrdersAtTick(market, 1, 600);

        orderEngine.advanceHead(market, 1, 600, 1024);

        (uint256 depthAfter, uint256 countAfter) =
            orderEngine.getOrdersAtTick(market, 1, 600);
        assertEq(depthAfter, depthBefore, "depth unchanged");
        assertEq(countAfter, countBefore, "the live order is still there");
        assertEq(orderEngine.getBestTick(market, 1), 600, "and still quoted");

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 5e18, 256));
        assertEq(orderEngine.getNet(market, bob), -5e18, "and still fills");
    }
}

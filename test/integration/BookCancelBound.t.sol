// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {OrderEngine} from "src/OrderEngine.sol";

/// @notice Regressions for another maker's padding of the shared tick queue.
/// @dev These tests cover bounded shared-head advancement and compaction. The
/// caller's separate history scan is covered by BookMakerCancelBoundTest; padding
/// another maker's history does not increase this caller's cancellation work.
contract BookCancelBoundTest is DualTokenBase {
    /// NO price every pad and victim order pays.
    uint16 constant TICK = 300;
    /// Where a NO buy at TICK rests on the single YES axis: an ASK at
    /// `1000 - TICK`. Cancels and views address the order by that side and tick.
    uint16 constant ASK_TICK = 700;
    uint8 constant BID = 0;
    uint8 constant ASK = 1;
    uint256 constant PADS = 200;

    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    function test_paddedTickCancelIsBoundedAndMatchingResumes() public {
        uint128 minSize = orderEngine.getMinRestingOrder(TICK);

        // Victim rests the live head order.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, 10e18, 256));

        // Griefer pads the same tick behind it, then cancels every pad.
        for (uint256 i; i < PADS; ++i) {
            vm.prank(alice);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, minSize, 256));
        }
        for (uint256 i; i < PADS; ++i) {
            vm.prank(alice);
            orderEngine.cancel(market, ASK, ASK_TICK);
        }
        (uint256 total, uint256 count) =
            orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(total, 10e18);
        assertEq(count, 1);

        // Victim's cancel is bounded regardless of the padding.
        uint256 usdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        orderEngine.cancel(market, ASK, ASK_TICK);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 400_000, "victim cancel must not scale with padding");
        assertGt(usdc.balanceOf(bob), usdcBefore, "refund paid");
        (total, count) = orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(total + count, 0, "tick reads empty");
        assertEq(orderEngine.getBestTick(market, ASK), 1000, "no active ask");

        // A crossing taker with no resting liquidity rests instead of filling.
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 1e18, 256));
        (uint256 yes,) = orderEngine.getPosition(market, alice);
        assertEq(yes, 0, "nothing to fill against");
        vm.prank(alice);
        orderEngine.cancel(market, BID, 700);

        // New liquidity appended behind the residual zeroed entries still fills.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, 5e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 5e18, 256));
        (yes,) = orderEngine.getPosition(market, alice);
        assertEq(yes, 5e18, "taker matched through the padded queue");
        (, uint256 no) = orderEngine.getPosition(market, bob);
        assertEq(no, 5e18);
        (total, count) = orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(total + count, 0);
    }

    /// The griefer keeps front pads LIVE so the head never advances,
    /// then zeroes the back pads with O(1) `cancelById`, leaving hundreds of dead
    /// entries between the head and the victim's later order. `cancel()` resolves
    /// through the caller's bounded placement-history scan, not the shared queue.
    function test_victimBehindLiveFrontPadsAndZeroedBackPadsCancelsInO1() public {
        uint128 minSize = orderEngine.getMinRestingOrder(TICK);
        uint256 nextId = 1; // fresh state per test: ids are sequential from 1
        uint256 frontPads = 20;

        // Griefer: live front pads.
        for (uint256 i; i < frontPads; ++i) {
            vm.prank(alice);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, minSize, 256));
            nextId++;
        }
        // Griefer: back pads, then zero them by id (O(1) each; head stays at 0).
        uint256 firstBackPad = nextId;
        for (uint256 i; i < PADS; ++i) {
            vm.prank(alice);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, minSize, 256));
            nextId++;
        }
        for (uint256 i; i < PADS; ++i) {
            vm.prank(alice);
            orderEngine.cancelById(uint64(firstBackPad + i));
        }
        (uint256 total, uint256 count) =
            orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(count, frontPads, "only the live front pads remain");

        // Victim rests two orders behind the zeroed region.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, 10e18, 256));
        uint64 victimFirst = uint64(nextId++);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, TICK, 7e18, 256));
        uint64 victimSecond = uint64(nextId++);

        // The victim has no spent own history; other makers' pads are not scanned.
        uint256 usdcBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        orderEngine.cancel(market, ASK, ASK_TICK);
        uint256 used = gasBefore - gasleft();
        assertLt(used, 150_000, "victim cancel must not walk the padded queue");
        assertGt(usdc.balanceOf(bob), usdcBefore, "first order refunded");
        (total, count) = orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(count, frontPads + 1, "second victim order still live");
        assertEq(total, uint256(minSize) * frontPads + 7e18);

        // cancel() cancelled the EARLIEST live order: the first id is now dead.
        vm.prank(bob);
        vm.expectRevert(OrderEngine.OrderNotFound.selector);
        orderEngine.cancelById(victimFirst);
        // And cancel() again resolves the second one, agreeing with cancelById.
        vm.prank(bob);
        orderEngine.cancel(market, ASK, ASK_TICK);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.OrderNotFound.selector);
        orderEngine.cancelById(victimSecond);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.NothingToCancel.selector);
        orderEngine.cancel(market, ASK, ASK_TICK);
        (total, count) = orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(count, frontPads, "victim fully out");

        // Matching still consumes the live front pads and nothing else.
        _consumeFrontPads(uint128(uint256(minSize) * frontPads));
    }

    function _consumeFrontPads(uint128 amount) private {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, amount, 256));
        (uint256 total, uint256 count) =
            orderEngine.getOrdersAtTick(market, ASK, ASK_TICK);
        assertEq(total + count, 0, "front pads filled, tick empty");
        (uint256 yes,) = orderEngine.getPosition(market, bob);
        assertEq(yes, amount);
    }
}

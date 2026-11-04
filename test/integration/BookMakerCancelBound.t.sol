// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// @notice Tick cancellation bounds the caller's own history, including filled
/// and ID-cancelled entries, while preserving progress and earliest-live priority.
contract BookMakerCancelBoundTest is DualTokenBase {
    uint8 private constant ASK = 1;
    uint16 private constant YES_TICK = 600;
    uint16 private constant NO_TICK = 400;

    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    function test_idCancelledHistoryMakesBoundedProgressWithoutOtherMakerInterference()
        public
    {
        uint64 otherFirst = _restBuy(alice, 2e18);
        _cancelledHistory(128);
        uint64 first = _restBuy(bob, 3e18);
        uint64 otherSecond = _restBuy(alice, 4e18);
        uint64 second = _restBuy(bob, 5e18);
        uint256 bobBalance = usdc.balanceOf(bob);
        uint256 reserved = _cashReserved(bob);

        for (uint256 cursor = 32; cursor <= 128; cursor += 32) {
            _cancelExpect(cursor, 0);
            assertEq(usdc.balanceOf(bob), bobBalance, "progress refunds no live order");
            assertEq(_cashReserved(bob), reserved, "progress preserves reservation");
            assertEq(orderEngine.getOrder(first).amount, 3e18);
            assertEq(orderEngine.getOrder(second).amount, 5e18);
            assertEq(orderEngine.getOrder(otherFirst).amount, 2e18);
            assertEq(orderEngine.getOrder(otherSecond).amount, 4e18);
        }

        _cancelExpect(129, first);
        assertEq(orderEngine.getOrder(first).amount, 0);
        assertEq(orderEngine.getOrder(second).amount, 5e18, "later own order stays live");
        assertEq(usdc.balanceOf(bob) - bobBalance, 1_200_000);
        assertEq(_cashReserved(bob), 2_000_000);
        _cancelExpect(130, second);
        assertEq(_cashReserved(bob), 0);
        _expectNothingToCancel();

        // The other maker's cursor and orders were never changed by Bob's calls.
        vm.prank(alice);
        assertEq(orderEngine.cancel(market, ASK, YES_TICK), otherFirst);
        assertEq(orderEngine.getOrder(otherSecond).amount, 4e18);
        vm.prank(alice);
        assertEq(orderEngine.cancel(market, ASK, YES_TICK), otherSecond);
    }

    function test_filledHistoryDoesNotSkipEarliestPartiallyFilledOrder() public {
        for (uint256 i; i < 65; ++i) {
            _restBuy(bob, 1e18);
        }
        uint64 first = _restBuy(bob, 2e18);
        uint64 second = _restBuy(bob, 3e18);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, YES_TICK, 66e18, 256));

        assertEq(orderEngine.getOrder(first).amount, 1e18, "earliest live is partial");
        assertEq(orderEngine.getOrder(second).amount, 3e18);
        assertEq(_cashReserved(bob), 1_600_000);
        _cancelExpect(32, 0);
        _cancelExpect(64, 0);
        assertEq(_cashReserved(bob), 1_600_000, "filled-history scans release nothing");
        uint256 bobBalance = usdc.balanceOf(bob);
        _cancelExpect(66, first);
        assertEq(usdc.balanceOf(bob) - bobBalance, 400_000, "only remainder refunded");
        assertEq(orderEngine.getOrder(second).amount, 3e18);
        (, uint256 noOwned) = orderEngine.getPosition(market, bob);
        assertEq(noOwned, 66e18, "filled ownership is unchanged");
        _cancelExpect(67, second);
        _expectNothingToCancel();
    }

    function test_deadTailProgressPersistsThenNewAppendedOrderRemainsReachable() public {
        _cancelledHistory(33);
        uint256 bobBalance = usdc.balanceOf(bob);
        _cancelExpect(32, 0);
        _cancelExpect(33, 0);
        assertEq(usdc.balanceOf(bob), bobBalance);
        _expectNothingToCancel();
        uint64 next = _restBuy(bob, 2e18);
        _cancelExpect(34, next);
        _expectNothingToCancel();
    }

    function test_emptyOwnHistoryRevertsWithoutCancellingAnotherMaker() public {
        uint64 other = _restBuy(alice, 2e18);
        _expectNothingToCancel();
        assertEq(orderEngine.getOrder(other).amount, 2e18);
    }

    function test_liveOrderInLastScanSlotIsCancelled() public {
        _cancelledHistory(31);
        uint64 first = _restBuy(bob, 2e18);
        _cancelExpect(32, first);
        _expectNothingToCancel();
    }

    function test_liveOrderBeyondScanBudgetWaitsForNextCall() public {
        _cancelledHistory(32);
        uint64 first = _restBuy(bob, 2e18);
        _cancelExpect(32, 0);
        assertEq(orderEngine.getOrder(first).amount, 2e18);
        _cancelExpect(33, first);
        _expectNothingToCancel();
    }

    function test_progressPreservesCoveredSellReservationsAndGrossOwnership() public {
        vm.prank(bob);
        orderEngine.split(market, 100e18, 100e6, uint64(block.timestamp + 1 days));
        for (uint256 i; i < 65; ++i) {
            uint64 id = _restSell(1e18);
            vm.prank(bob);
            orderEngine.cancelById(id);
        }
        uint64 first = _restSell(2e18);
        uint64 second = _restSell(3e18);
        _assertSellInventory(5e18);
        _cancelExpect(32, 0);
        _assertSellInventory(5e18);
        _cancelExpect(64, 0);
        _assertSellInventory(5e18);
        _cancelExpect(66, first);
        _assertSellInventory(3e18);
        assertEq(orderEngine.getOrder(second).amount, 3e18);
        _cancelExpect(67, second);
        _assertSellInventory(0);
        _expectNothingToCancel();
    }

    function _restBuy(address maker, uint128 amount) private returns (uint64) {
        vm.prank(maker);
        return orderEngine.placeOrder(market, BookTestOrders.buy(0, NO_TICK, amount, 256))
        .orderId;
    }

    function _restSell(uint128 amount) private returns (uint64) {
        vm.prank(bob);
        return orderEngine.placeOrder(
            market, BookTestOrders.sell(1, YES_TICK, amount, 256)
        )
        .orderId;
    }

    function _cancelledHistory(uint256 count) private {
        for (uint256 i; i < count; ++i) {
            uint64 id = _restBuy(bob, 1e18);
            vm.prank(bob);
            orderEngine.cancelById(id);
        }
    }

    function _cancelExpect(uint256 nextCursor, uint64 cancelledId) private {
        vm.expectEmit(true, true, false, true, address(orderEngine));
        emit IOrderEngine.MakerCancelProgress(
            market, bob, ASK, YES_TICK, nextCursor, cancelledId
        );
        vm.prank(bob);
        uint256 beforeGas = gasleft();
        uint64 result = orderEngine.cancel(market, ASK, YES_TICK);
        uint256 used = beforeGas - gasleft();
        assertEq(result, cancelledId, "return identifies progress or exact cancellation");
        assertLt(used, 400_000, "one call remains bounded with long own history");
    }

    function _expectNothingToCancel() private {
        vm.prank(bob);
        vm.expectRevert(OrderEngine.NothingToCancel.selector);
        orderEngine.cancel(market, ASK, YES_TICK);
    }

    function _cashReserved(address maker) private view returns (uint256 cashReserved) {
        (,,,, cashReserved) = orderEngine.getInventory(market, maker);
    }

    function _assertSellInventory(uint256 expectedYesReserved) private view {
        (
            uint256 yesOwned,
            uint256 noOwned,
            uint256 yesReserved,
            uint256 noReserved,
            uint256 cashReserved
        ) = orderEngine.getInventory(market, bob);
        assertEq(yesOwned, 100e18);
        assertEq(noOwned, 100e18);
        assertEq(yesReserved, expectedYesReserved);
        assertEq(noReserved, 0);
        assertEq(cashReserved, 0);
    }
}

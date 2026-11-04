// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {ExactTransferToken} from "./AmmExactTransfers.t.sol";
import {OrderEngine} from "src/OrderEngine.sol";

contract BookExactTransfersTest is DualTokenBase {
    ExactTransferToken internal token;

    function setUp() public override {
        super.setUp();
        token = new ExactTransferToken();
        _deployStack(address(token));
        address[2] memory holders = [alice, bob];
        for (uint256 i; i < holders.length; ++i) {
            token.mint(holders[i], 100_000e18);
            vm.prank(holders[i]);
            token.approve(address(orderEngine), type(uint256).max);
        }
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        _createMarket();
    }

    function _open() private {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 256));
    }

    function test_senderExtraFeeCannotOverchargeRestingOrder() public {
        uint256 before = token.balanceOf(bob);
        token.configure(1, bob);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        assertEq(token.balanceOf(bob), before);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_recipientTaxCannotDischargeSettlement() public {
        _open();
        _resolveAndSettle(1);
        uint256 before = token.balanceOf(alice);
        token.configure(2, alice);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.settlePosition(market);
        assertEq(orderEngine.getNet(market, alice), int256(100e18));
        assertEq(orderEngine.getCollateralBacking(market), 100e18);
        assertEq(token.balanceOf(alice), before);
    }

    function test_recipientTaxCannotUnderpayClosingTaker() public {
        _open();
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 100e18, 256));
        uint256 before = token.balanceOf(bob);
        token.configure(2, bob);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.placeOrder(market, BookTestOrders.sell(0, 400, 100e18, 256));
        assertEq(orderEngine.getNet(market, bob), -int256(100e18));
        assertEq(orderEngine.getNet(market, alice), int256(100e18));
        assertEq(token.balanceOf(bob), before);
    }

    function test_falseAfterTransferCannotCreateSecondMakerPayment() public {
        _open();
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 100e18, 256));
        uint256 before = token.balanceOf(alice);
        token.configure(3, alice);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.placeOrder(market, BookTestOrders.sell(0, 400, 100e18, 256));
        assertEq(token.balanceOf(alice), before);
        assertEq(orderEngine.deferredOf(alice), 0);
        assertEq(orderEngine.getNet(market, alice), int256(100e18));
    }

    function test_blockedMakerDefersAndInexactDeferredClaimRollsBack() public {
        _open();
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 100e18, 256));
        uint256 before = token.balanceOf(alice);
        token.configure(4, alice);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(0, 400, 100e18, 256));
        uint256 owed = orderEngine.deferredOf(alice);
        assertGt(owed, 0);
        assertEq(token.balanceOf(alice), before);
        token.configure(2, alice);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.claimDeferred();
        assertEq(orderEngine.deferredOf(alice), owed);
        token.configure(0, address(0));
        vm.prank(alice);
        assertEq(orderEngine.claimDeferred(), owed);
        assertEq(token.balanceOf(alice) - before, owed);
        assertEq(orderEngine.totalDeferred(), 0);
    }

    function test_collectionAndPayoutCallbacksCannotReenter() public {
        token.arm(
            address(orderEngine),
            abi.encodeCall(
                orderEngine.placeOrder, (market, BookTestOrders.buy(0, 400, 100e18, 256))
            )
        );
        _open();
        assertFalse(token.callbackSucceeded());
        _resolveAndSettle(1);
        token.arm(
            address(orderEngine), abi.encodeCall(orderEngine.settlePosition, (market))
        );
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 100e18);
        assertFalse(token.callbackSucceeded());
    }

    function test_complementaryBuyCashUsesMakerReservationsWithoutCreatingRoundingBacking()
        public
    {
        vm.startPrank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, 3, 256));
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, 3, 256));
        vm.stopPrank();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 500, 6, 64));
        // Each maker already reserved ceil(3/2)=2 native units. Each complete-set
        // mint needs only 3-2=1 more unit from the taker, plus one aggregate fee.
        assertEq(before - token.balanceOf(alice), 3);
        assertEq(orderEngine.getCollateralBacking(market), 6);
        assertEq(token.balanceOf(address(orderEngine)), 6);
        assertEq(token.balanceOf(address(bookVault)), 1);
    }

    function test_grossDebitSeparatelyRoundsMatchedAndRestingNativeLegs() public {
        _deployStack(address(usdc));
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(orderEngine), type(uint256).max);
        _createMarket();
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, 3e12, 256));
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 500, 6e12, 64));
        // Maker's two-unit reservation funds part of the three-unit mint.
        // Taker pays one matched unit + two resting units + one fee = four.
        assertEq(before - usdc.balanceOf(alice), 4);
        assertEq(orderEngine.getCollateralBacking(market), 5);
        assertEq(orderEngine.getOrderCash(market), 2);
        assertEq(orderEngine.getShareBacking(market), 3);
    }

    function test_recipientTaxCannotUnderpayCompleteSetMerge() public {
        vm.prank(alice);
        orderEngine.split(market, 100e18, 100e18, uint64(block.timestamp + 1 days));
        uint256 before = token.balanceOf(alice);
        token.configure(2, alice);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.merge(market, 100e18, 100e18, uint64(block.timestamp + 1 days));
        (uint256 yes, uint256 no) = orderEngine.getPosition(market, alice);
        assertEq(yes, 100e18);
        assertEq(no, 100e18);
        assertEq(orderEngine.getCollateralBacking(market), 100e18);
        assertEq(token.balanceOf(alice), before);
    }
}

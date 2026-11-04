// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";

/// Explicit inventory sales replace the former signed-net close wrapper.
contract CloseOrdersTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
        usdc.mint(trader, 10_000e6);
        vm.prank(trader);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.prank(alice);
        orderEngine.split(market, 100e18, 100e6, uint64(block.timestamp + 1));
    }

    function terms(uint128 amount, uint16 tick, bool rest)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p = BookTestOrders.sell(1, tick, amount, 64);
        p.rest = rest;
    }

    function test_saleNeedsNoCashOrApproval() public {
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 100e18, 64));
        usdc.burn(alice, usdc.balanceOf(alice));
        vm.startPrank(alice);
        usdc.approve(address(orderEngine), 0);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, terms(100e18, 700, false));
        vm.stopPrank();
        assertEq(r.filled, 100e18);
        assertEq(r.tokenIn, 0);
        assertEq(r.tokenOut, 798e5);
        assertEq(r.fee, 2e5);
        assertEq(usdc.balanceOf(alice), r.tokenOut);
    }

    function test_saleCannotExceedAvailableInventory() public {
        vm.prank(alice);
        vm.expectRevert(OrderEngine.InsufficientInventory.selector);
        orderEngine.placeOrder(market, terms(101e18, 800, true));
    }

    function test_overlappingSalesCannotReserveSameShares() public {
        vm.startPrank(alice);
        orderEngine.placeOrder(market, terms(100e18, 800, true));
        vm.expectRevert(OrderEngine.InsufficientInventory.selector);
        orderEngine.placeOrder(market, terms(1e18, 900, true));
        vm.stopPrank();
        (uint256 y,, uint256 reserved,,) = orderEngine.getInventory(market, alice);
        assertEq(y, 100e18);
        assertEq(reserved, y);
    }

    function test_partialSaleRestsInventoryWithoutCash() public {
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 40e18, 64));
        vm.prank(alice);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, terms(100e18, 800, true));
        assertEq(r.filled, 40e18);
        assertGt(r.orderId, 0);
        assertEq(r.tokenIn, 0);
        assertEq(r.tokenOut, 3192e4);
        (uint256 y,, uint256 reserved,,) = orderEngine.getInventory(market, alice);
        assertEq(y, 60e18);
        assertEq(reserved, 60e18);
        vm.prank(alice);
        orderEngine.cancelById(r.orderId);
        (,, reserved,,) = orderEngine.getInventory(market, alice);
        assertEq(reserved, 0);
    }

    function test_saleCashBoundAndSubmissionExpiryRollback() public {
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 100e18, 64));
        IOrderEngine.OrderParams memory p = terms(100e18, 800, false);
        p.minTokenOut = 80e6;
        vm.prank(alice);
        vm.expectRevert(OrderEngine.CashLimit.selector);
        orderEngine.placeOrder(market, p);
        assertEq(orderEngine.fillCount(), 0);
        p.minTokenOut = 0;
        vm.warp(p.validUntil + 1);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.InvalidOrderTerms.selector);
        orderEngine.placeOrder(market, p);
    }

    function test_noFillIOCReverts() public {
        vm.prank(alice);
        vm.expectRevert(OrderEngine.NothingFilled.selector);
        orderEngine.placeOrder(market, terms(100e18, 800, false));
    }

    function test_settlementLeavesReservedSharesCancellableAndClaimable() public {
        vm.prank(alice);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, terms(100e18, 800, true));
        _resolveAndSettle(1);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 0);
        vm.prank(alice);
        orderEngine.cancelById(r.orderId);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 100e6);
    }

    function test_restingExpiryIsIndependentOfSubmissionExpiry() public {
        IOrderEngine.OrderParams memory p = terms(100e18, 800, true);
        p.validUntil = uint64(block.timestamp + 1);
        p.expiry = uint64(block.timestamp + 100);
        vm.prank(alice);
        IOrderEngine.OrderResult memory r = orderEngine.placeOrder(market, p);
        vm.warp(p.validUntil + 1);
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 40e18, 64));
        assertEq(orderEngine.getOrder(r.orderId).amount, 60e18);
        vm.warp(p.expiry);
        orderEngine.advanceHead(market, 1, 800, 1);
        assertEq(orderEngine.getOrder(r.orderId).amount, 0);
    }

    function test_postOnlyCannotTake() public {
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 100e18, 64));
        IOrderEngine.OrderParams memory p = terms(100e18, 800, true);
        p.postOnly = true;
        vm.prank(alice);
        vm.expectRevert(OrderEngine.PostOnlyWouldTrade.selector);
        orderEngine.placeOrder(market, p);
    }

    function test_matchLimitExhaustionDiscardsCrossingRemainder() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, terms(40e18, 600, true));
        vm.prank(alice);
        orderEngine.placeOrder(market, terms(40e18, 700, true));
        vm.prank(bob);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 100e18, 1));
        assertEq(r.filled, 40e18);
        assertEq(r.orderId, 0);
        assertEq(orderEngine.getBestTick(market, 0), 1000);
        assertEq(orderEngine.getBestTick(market, 1), 700);
    }

    function test_matchLimitExhaustionDiscardsSellRemainder() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 40e18, 64));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 40e18, 64));
        IOrderEngine.OrderParams memory p = terms(100e18, 600, true);
        p.matchLimit = 1;
        vm.prank(alice);
        IOrderEngine.OrderResult memory r = orderEngine.placeOrder(market, p);
        assertEq(r.filled, 40e18);
        assertEq(r.orderId, 0);
        assertEq(orderEngine.getBestTick(market, 0), 700);
        assertEq(orderEngine.getBestTick(market, 1), 1000);
    }

    function test_selfMatchCancelsMakerWithoutTradingIt() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 10e18, 64));
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 100e18, 64));
        IOrderEngine.OrderParams memory p = terms(100e18, 800, false);
        p.matchLimit = 2;
        vm.prank(alice);
        IOrderEngine.OrderResult memory r = orderEngine.placeOrder(market, p);
        assertEq(r.filled, 100e18);
        assertEq(orderEngine.fillCount(), 1);
    }
}

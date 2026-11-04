// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {TruthMarket} from "src/TruthMarket.sol";

/// @notice A market resolved, vetoed back to LIVE and finally settled, with book
///         orders resting across the round trip.
/// @dev A veto before the deadline leaves trading closed. Resting orders stay,
///      and a new order cannot take them. The veto must not strand the
///      reservation or let the position settle early. The second resolution
///      pays the inventory the veto left in place.
contract VetoRoundTripTest is DualTokenBase {
    address internal guardian = address(0x6A12D);

    function setUp() public override {
        super.setUp();
        adjudicator.approveGuardian(guardian);
        // `trader` is the AMM actor in the shared harness and holds no book token.
        usdc.mint(trader, 1_000_000e6);
        vm.prank(trader);
        usdc.approve(address(orderEngine), type(uint256).max);
        _createMarket();
    }

    function _resolve(uint8 outcome) internal {
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("data"));
    }

    function test_restingOrdersSurviveAVetoAndTheSecondResolutionPays() public {
        // Alice long 10 against bob at 0.60.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        assertEq(orderEngine.getNet(market, alice), 10e18);

        // Both then rest orders that must survive the round trip: alice offers 4 of
        // her long at 0.70 (an ASK at YES 700), bob bids 0.30 for 10 (a BID at 300).
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 700, 4e18, 256));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 300, 10e18, 256));
        uint256 backingBefore = orderEngine.getCollateralBacking(market);

        // RESOLVING: trading shuts, but a cancel must still work, and settlement
        // must not open early.
        _resolve(1);
        assertFalse(TruthMarket(market).isTradingOpen(), "resolving closes trading");
        vm.prank(trader);
        vm.expectRevert();
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 1e18, 256));
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("MarketNotSettled()")));
        orderEngine.settlePosition(market);

        // Veto -> LIVE. Trading stays closed, and the orders are still there.
        vm.prank(guardian);
        adjudicator.dispute(market);
        assertEq(uint8(TruthMarket(market).state()), uint8(TruthMarket.MarketState.LIVE));
        assertTrue(TruthMarket(market).resolutionAttempted());
        assertFalse(
            TruthMarket(market).isTradingOpen(),
            "a veto before the deadline leaves trading closed"
        );
        vm.prank(trader);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 4e18, 256));
        assertEq(
            orderEngine.getCollateralBacking(market),
            backingBefore,
            "a veto moves no collateral"
        );
        (uint256 askAmount, uint256 askCount) =
            orderEngine.getOrdersAtTick(market, 1, 700);
        (uint256 bidAmount, uint256 bidCount) =
            orderEngine.getOrdersAtTick(market, 0, 300);
        assertEq(askCount, 1);
        assertEq(askAmount, 4e18, "alice's ask survived");
        assertEq(bidCount, 1);
        assertEq(bidAmount, 10e18, "bob's bid survived");

        // Second resolution, the other way. Cancel the surviving orders, then
        // settle the inventory the veto left in place.
        _resolve(0);
        vm.warp(block.timestamp + 1 hours + 1);
        adjudicator.settle(market);
        vm.prank(alice);
        orderEngine.cancel(market, 1, 700);
        vm.prank(bob);
        orderEngine.cancel(market, 0, 300);

        vm.prank(bob);
        uint256 bobPayout = orderEngine.settlePosition(market);
        assertEq(bobPayout, 10e6, "bob's 10 short wins under NO");
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 0, "her long is worthless");
        assertEq(
            orderEngine.getCollateralBacking(market), 0, "the market unwound to zero"
        );
        _assertSystemSolvent();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// @notice O-1. A veto before the deadline leaves trading and new liquidity
///         closed. A pre-proposal ask and the pre-proposal AMM quote cannot fill.
///         The maker can still cancel. LP redemption opens at settlement.
contract AuditM1Test is DualTokenBase {
    address internal guardian = address(0x6A12D);
    address internal attacker = address(0xA77AC4);
    uint256 internal constant ASK = 10e18;
    uint16 internal constant STALE_TICK = 200;

    function setUp() public override {
        super.setUp();
        adjudicator.approveGuardian(guardian);
        _createMarket();
        usdc.mint(attacker, 1_000_000e6);
        east.mint(attacker, 10_000e18);
        vm.startPrank(attacker);
        usdc.approve(address(orderEngine), type(uint256).max);
        east.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    function test_O1_vetoBeforeDeadlineDoesNotFillStaleQuotes() public {
        vm.prank(bob);
        orderEngine.split(market, ASK, type(uint256).max - 1, uint64(block.timestamp + 1));
        vm.prank(bob);
        orderEngine.placeOrder(
            market, BookTestOrders.sell(1, STALE_TICK, uint128(ASK), 8)
        );

        (,, uint256 priceBefore) = amm.getMarketState(market);
        assertLt(priceBefore, 0.6e18, "fixture starts near even");
        assertGt(priceBefore, 0.4e18, "fixture starts near even");
        assertLt(block.timestamp, TruthMarket(market).deadline(), "still before deadline");

        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("YES"));
        assertFalse(TruthMarket(market).isTradingOpen(), "proposal closes trading");

        // Same block as the veto. No time passes, so the deadline has not arrived.
        vm.prank(guardian);
        adjudicator.dispute(market);
        assertEq(uint8(TruthMarket(market).state()), uint8(TruthMarket.MarketState.LIVE));
        assertTrue(TruthMarket(market).resolutionAttempted(), "the marker stays set");
        assertFalse(TruthMarket(market).isTradingOpen(), "trading stays closed");
        assertFalse(TruthMarket(market).isLiquidityOpen(), "new liquidity stays closed");
        (,, uint256 priceAfter) = amm.getMarketState(market);
        assertEq(priceAfter, priceBefore, "the veto itself does not move the AMM");

        (uint256 depth, uint256 count) =
            orderEngine.getOrdersAtTick(market, 1, STALE_TICK);
        assertEq(depth, ASK, "the pre-proposal ask is still resting");
        assertEq(count, 1);
        vm.prank(attacker);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, int256(1e18), type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, STALE_TICK, uint128(ASK), 8));
        (uint256 depthAfter,) = orderEngine.getOrdersAtTick(market, 1, STALE_TICK);
        assertEq(depthAfter, ASK, "the resting ask did not fill");

        vm.prank(creator);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(
            market,
            1e18,
            IAMMEngine.LiquidityLimits(
                1, 1, 1, 2, uint64(block.timestamp), bytes32(uint256(1))
            )
        );

        vm.prank(bob);
        orderEngine.cancel(market, 1, STALE_TICK);
        (uint256 depthCancelled,) = orderEngine.getOrdersAtTick(market, 1, STALE_TICK);
        assertEq(depthCancelled, 0, "the maker can still cancel");

        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("YES"));
        vm.warp(block.timestamp + 1 hours + 1);
        adjudicator.settle(market);
        assertEq(TruthMarket(market).winningOutcome(), 1);
        vm.prank(attacker);
        vm.expectRevert();
        orderEngine.settlePosition(market);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        assertGt(amm.redeemLP(market, creatorLP), 0, "LP redemption opens at settlement");
        _assertSystemSolvent();
    }
}

/// @notice L-1 regression. Cancelled orders are unlinked, so a live head plus
///         more than `MAX_DEAD_SKIPS` spent slots does not stop a taker. `advanceHead`
///         still will not walk past that live head.
contract AuditL1Test is DualTokenBase {
    uint16 internal constant TICK = 500;
    uint8 internal constant ASK = 1;
    address internal carol = address(0xCA201);
    uint128 internal dust;

    function setUp() public override {
        super.setUp();
        _createMarket();
        dust = orderEngine.getMinRestingOrder(TICK);
        usdc.mint(carol, 5_000_000e6);
        vm.prank(carol);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.prank(bob);
        orderEngine.split(market, 2000e18, type(uint256).max - 1, _until());
        vm.prank(alice);
        orderEngine.split(market, 2000e18, type(uint256).max - 1, _until());
    }

    function _until() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function test_L1_spentRunBehindLiveHeadDoesNotBlockDeeperTicks() public {
        assertEq(orderEngine.MAX_DEAD_SKIPS(), 512);

        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, dust, 8));
        uint256 pads = orderEngine.MAX_DEAD_SKIPS() + 1;
        for (uint256 i; i < pads; ++i) {
            vm.prank(bob);
            IOrderEngine.OrderResult memory pad =
                orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, dust, 8));
            vm.prank(bob);
            orderEngine.cancelById(pad.orderId);
        }
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, 1000e18, 8));

        // Array compaction still stops on the live head. Matching does not.
        orderEngine.advanceHead(market, ASK, TICK, 1024);
        (uint256 depthBefore, uint256 countBefore) =
            orderEngine.getOrdersAtTick(market, ASK, TICK);
        assertEq(depthBefore, dust + 1000e18, "both live orders are still on the tick");
        assertEq(countBefore, 2);

        vm.prank(carol);
        IOrderEngine.OrderResult memory taken = orderEngine.placeOrder(
            market, BookTestOrders.buy(1, TICK, uint128(dust) + 1000e18, 256)
        );
        assertEq(taken.filled, uint128(dust) + 1000e18, "taker reaches the deeper order");
        assertEq(taken.orderId, 0, "the crossing size fills completely");
        (uint256 depthAfter, uint256 countAfter) =
            orderEngine.getOrdersAtTick(market, ASK, TICK);
        assertEq(depthAfter, 0, "both live orders filled");
        assertEq(countAfter, 0);
        _assertSystemSolvent();
    }
}


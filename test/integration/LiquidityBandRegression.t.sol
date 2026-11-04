// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";

/// @notice Replays a positive-profit in-band attack against exact
///         quote-state protection, both capital policies, and scaled sponsor depth.
/// @dev A stale add now reverts: this proves bounded execution, not inclusion or yield.
contract LiquidityBandRegressionTest is DualTokenBase {
    uint256 internal constant B0 = 100e18;
    uint256 internal constant DB = 100e18;
    LPPositionManager internal manager;
    uint256 internal bootstrap;
    address internal attacker = address(0xA77);
    address internal victim = address(0x1C71);

    function setUp() public override {
        super.setUp();
        address[3] memory extra = [attacker, victim, creator];
        for (uint256 i; i < extra.length; i++) {
            east.mint(extra[i], 1_000_000e18);
            vm.prank(extra[i]);
            east.approve(address(amm), type(uint256).max);
        }
        manager = LPPositionManager(amm.positionManager());
        _createDepth(B0);
    }

    function _createDepth(uint256 depth) internal {
        IMarketFactory.MarketParams memory params = _marketParams(
            "Liquidity band regression",
            0,
            uint64(block.timestamp + 20 days),
            address(east),
            depth,
            0.5e18
        );
        vm.prank(creator);
        (market, bootstrap) = marketFactory.createMarket(params);
    }

    function test_scaledInBandSandwichCannotExecuteWithStaleQuote() public {
        for (uint256 policy; policy < 2; policy++) {
            IAmmFeeVault.AmmConfig memory cfg = _ammConfig();
            if (policy == 0) {
                cfg.capitalBps = 0;
                cfg.lpBps = 8000;
            }
            vault.publishAmmConfig(cfg);
            for (uint256 scale = 1; scale <= 100; scale *= 100) {
                _createDepth(B0 * scale);
                IAMMEngine.LiquidityLimits memory limits =
                    _liquidityLimits(market, DB * scale);
                limits.maxTokenIn *= 2;
                limits.minLpOut = 1;
                limits.minYesPrice = 0.45e18;
                limits.maxYesPrice = 0.55e18;
                uint256 quoteBlock = block.number;
                uint256 beforeAttacker = east.balanceOf(attacker);
                uint256 beforeVictim = east.balanceOf(victim);
                vm.prank(attacker);
                amm.tradePositions(market, 1, int256(20e18 * scale), type(uint256).max);
                (,, uint256 moved) = amm.getMarketState(market);
                assertGt(moved, limits.minYesPrice);
                assertLt(moved, limits.maxYesPrice);
                vm.prank(victim);
                vm.expectRevert(AMMEngine.StaleLiquidityQuote.selector);
                amm.increaseLiquidity(market, DB * scale, limits);
                assertEq(block.number, quoteBlock, "trade and stale add share a block");
                assertEq(east.balanceOf(victim), beforeVictim);
                assertEq(manager.positionCount(market), 1);
                vm.prank(attacker);
                amm.tradePositions(market, 1, -int256(20e18 * scale), 0);

                int256 profit = int256(east.balanceOf(attacker)) - int256(beforeAttacker);
                assertLt(profit, 0, "failed attack loses fees");
                (uint256 yes, uint256 no) = amm.getPosition(market, attacker);
                assertEq(yes + no, 0);
                emit log_named_int("attempted sandwich net token profit", profit);
                _assertSystemSolvent();
            }
        }
    }

    function test_quotedAdditionThenTradingRemainsSolventAcrossAllOutcomes() public {
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, DB);
        vm.prank(victim);
        (uint256 receipt,) = amm.increaseLiquidity(market, DB, limits);
        vm.prank(attacker);
        amm.tradePositions(market, 1, 100e18, type(uint256).max);
        vm.prank(attacker);
        amm.tradePositions(market, 1, -100e18, 0);

        _assertSystemSolvent();
        for (uint8 outcome; outcome < 3; outcome++) {
            uint256 snap = vm.snapshotState();
            _settleAndClaimAll(receipt, outcome);
            vm.revertToState(snap);
        }
    }

    function _settleAndClaimAll(uint256 receipt, uint8 outcome) internal {
        _resolveAndSettle(outcome);
        _assertSystemSolvent();

        // Attacker is flat and already received both immediate sell payouts.
        (uint256 y, uint256 n) = amm.getPosition(market, attacker);
        assertEq(y + n, 0, "attacker flat at settlement");

        uint256[2] memory receipts = [bootstrap, receipt];
        address[2] memory owners = [creator, victim];
        for (uint256 i; i < 2; i++) {
            uint256 expected = manager.residual(receipts[i], outcome);
            assertGt(expected, 0, "residual clamped to zero");
            uint256 units = manager.balanceOf(owners[i], receipts[i]);
            assertGt(units, 0, "owner holds receipt units");

            uint256 before = east.balanceOf(owners[i]);
            vm.prank(owners[i]);
            amm.redeemLPPosition(market, receipts[i], units);
            uint256 floor = amm.floorEntitlementOf(market, owners[i]);
            assertGt(floor, 0, "floor entitlement is positive");
            vm.prank(owners[i]);
            amm.claimFloor(market);
            uint256 paidFloor = east.balanceOf(owners[i]) - before;
            assertEq(paidFloor, floor, "floor paid in full");
            // Full redemption pays exactly the residual (18-dec, no native rounding).
            assertEq(paidFloor, expected, "floor equals residual");
            _assertSystemSolvent();

            // LP fee dividends: both entries earned from the attacker's trades.
            uint256 feeBefore = east.balanceOf(owners[i]);
            vm.prank(owners[i]);
            uint256 dividend = vault.claimLPDividendForPosition(market, receipts[i]);
            assertGt(dividend, 0, "LP dividend paid");
            assertEq(
                east.balanceOf(owners[i]) - feeBefore, dividend, "dividend transferred"
            );
        }
        assertEq(amm.claimableFloorLiability(market), 0, "no floor liability left");

        // Operator and committed resolution-recipient buckets.
        uint256 protocolBucket =
            vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(east));
        assertGt(protocolBucket, 0, "protocol fees accrued");
        vm.prank(treasury);
        assertEq(vault.claimOperatorFees(market), protocolBucket);

        uint256 adjBucket =
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east));
        assertGt(adjBucket, 0, "adjudicator fees accrued");
        vm.prank(address(adjudicator));
        assertEq(vault.claimResolutionFees(market), adjBucket);

        _assertSystemSolvent();
        emit log_named_uint("outcome settled and fully claimed", outcome);
    }

    // ── L-1: near-max add bricks fee-bearing trades ──

    /// Review L-1 follow-up: liquidity admission is now capped at `MAX_ADMITTED_DEPTH`
    /// (half the 1e36 arithmetic domain) so an accepted add can no longer park `b` on the
    /// bound where every fee-bearing trade reverts. The old sequence (add `1e36 - b`, then
    /// trade) reverted at the trade; it now reverts at the quote/admission step, and an add
    /// that lands exactly on the admitted cap leaves trading and further quoting usable.
    /// Funding is still ~3.5e35 WAD, far beyond any real supply; this is on record as an
    /// arithmetic-headroom check, not an economic cap.
    function test_nearMaxAddIsRefusedAndAdmittedCapKeepsTradingOpen() public {
        uint256 b = amm.getLiquidity(market);
        uint256 cap = PositionPricing.MAX_ADMITTED_DEPTH;

        // Past the admitted cap: refused before any transfer.
        vm.expectRevert(PositionPricing.Domain.selector);
        amm.quoteLiquidity(market, 1e36 - b);
        vm.expectRevert(PositionPricing.Domain.selector);
        amm.quoteLiquidity(market, cap - b + 1);

        // Exactly on the admitted cap: accepted, and the market keeps working.
        uint256 hugeB = cap - b;
        (uint256 needed,,) = amm.quoteLiquidity(market, hugeB);
        assertGe(needed, 3.46e35, "required funding lower");
        assertLe(needed, 3.47e35, "required funding upper");
        emit log_named_uint("Token-A WAD required to reach the admitted cap", needed);
        east.mint(alice, needed);
        vm.prank(alice);
        east.approve(address(amm), type(uint256).max);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, hugeB);
        vm.prank(alice);
        (, uint256 deposit) = amm.increaseLiquidity(market, hugeB, limits);
        assertEq(deposit, needed, "deposit equals quote");
        assertEq(amm.getLiquidity(market), cap, "b sits exactly on the admitted cap");

        // Fee-bearing trades still validate: CAPITAL growth has half the domain of headroom.
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        assertGt(amm.getLiquidity(market), cap, "b grew by capitalWad");

        // Further adds are refused (b already exceeds the admitted cap), by Domain.
        vm.expectRevert(PositionPricing.Domain.selector);
        amm.quoteLiquidity(market, 1);
    }
}

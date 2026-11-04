// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {LPPositionToken} from "src/LPPositionToken.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {PositionCollateral} from "./SeparateLPPositions.t.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";

/// @notice Regressions for the 2026-09-06 second-model review findings:
///         zero-unit position claims must keep their checkpoint, the finalization
///         event must identify the terminal kind and venue, the committed resolver
///         recipient receives fees without impersonation, and the timeout
///         boundary ordering must be on record.
contract ReviewFollowupsTest is DualTokenBase {
    PositionCollateral internal collateral;
    LPPositionManager internal manager;
    uint256 internal bootstrap;

    function _prepare6() internal {
        collateral = new PositionCollateral(6);
        for (uint256 i; i < 3; i++) {
            address holder = i == 0 ? creator : i == 1 ? trader : alice;
            collateral.mint(holder, 1_000_000e6);
            vm.startPrank(holder);
            collateral.approve(address(marketFactory), type(uint256).max);
            collateral.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        uint64 dl = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory p =
            _marketParams("Review follow-ups", 0, dl, address(collateral), 25e18, 0.5e18);
        vm.prank(creator);
        (market, bootstrap) = marketFactory.createMarket(p);
        manager = LPPositionManager(amm.positionManager());
    }

    function _band() internal view returns (IAMMEngine.LiquidityLimits memory) {
        return _liquidityLimits(market, 25e18);
    }

    /// Codex L-1: two individually sub-unit entitlements whose sum is payable. The
    /// per-position claim must return zero without reverting so the checkpoint survives,
    /// and the second claim then pays the combined whole unit.
    function test_zeroUnitPositionClaimKeepsCheckpoint() public {
        _prepare6();
        IAMMEngine.LiquidityLimits memory limits = _band();
        vm.prank(alice);
        (uint256 r1,) = amm.increaseLiquidity(market, 25e18, limits);
        limits = _band();
        vm.prank(alice);
        (uint256 r2,) = amm.increaseLiquidity(market, 25e18, limits);
        // Small trade: the LP fee share of each alice entry is a fraction of one 6-dec
        // native unit while the two entries together exceed one unit.
        vm.prank(trader);
        amm.tradePositions(market, 1, 2.1e15, type(uint256).max);
        _resolveAndSettle(1);
        // Fee accounting is in native units: the LP bucket holds 3 units, alice's two
        // equal entries each earn just under one unit after conservative index rounding.
        assertEq(vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(collateral)), 3);

        uint256 before = collateral.balanceOf(alice);
        vm.prank(alice);
        uint256 first = vault.claimLPDividendForPosition(market, r1);
        assertEq(first, 0, "first entry alone is below one native unit");
        assertEq(collateral.balanceOf(alice), before, "nothing transferred");
        vm.prank(alice);
        uint256 second = vault.claimLPDividendForPosition(market, r2);
        assertGt(second, 0, "combined checkpoints pay a whole unit");
        assertEq(collateral.balanceOf(alice) - before, second, "native units transferred");
        // Nothing further is claimable; the aggregate path agrees.
        vm.prank(alice);
        assertEq(vault.claimLPDividend(market), 0);
    }

    /// Timeout is explicit in the event even when the resolution bucket is empty.
    function test_finalizedEventReportsVenueAndTimeoutKind() public {
        _createMarket();
        vm.warp(
            uint256(TruthMarket(market).deadline()) + marketFactory.invalidationBuffer()
                + 1
        );
        vm.expectEmit(true, true, false, true, address(vault));
        emit VenueFeeVault.MarketFinalized(
            market, 0, uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
        vault.finalize(market);
        vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
        vault.claimResolutionFees(market);
    }

    /// Anyone can trigger payment to the frozen resolver recipient; the caller
    /// cannot redirect it or impersonate the adjudicator to collect it.
    function test_resolutionFeesPayFrozenRecipientPermissionlessly() public {
        _createMarket();
        _seedAmmPosition();
        _resolveAndSettle(1);
        uint256 owed =
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east));
        assertGt(owed, 0, "adjudicated settlement retains adjudicator fees");
        address recipient = adjudicator.resolutionRecipient();
        uint256 recipientBefore = east.balanceOf(recipient);
        uint256 callerBefore = east.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = vault.claimResolutionFees(market);
        assertEq(paid, owed);
        assertEq(east.balanceOf(recipient) - recipientBefore, owed);
        assertEq(east.balanceOf(alice), callerBefore);
        assertEq(
            east.balanceOf(address(adjudicator)), 0, "nothing stranded on the adjudicator"
        );
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east)), 0
        );
    }

    /// Audit L1 / OA-M1 (supersedes Codex Info-3): a proposal that cannot finish its
    /// veto window before `deadline + invalidationBuffer` is rejected up front, so the
    /// only terminal transition reachable from a late proposal is no longer a
    /// third-party invalidation that flips the outcome and redirects adjudicator fees.
    function test_lateProposalInsideVetoWindowIsRejected() public {
        _createMarket();
        _seedAmmPosition();
        uint256 boundary =
            uint256(TruthMarket(market).deadline()) + marketFactory.invalidationBuffer();
        uint256 veto = adjudicator.vetoPeriod();

        vm.warp(boundary - veto / 2);
        vm.prank(resolver);
        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
        adjudicator.resolve(market, 1, keccak256("too late"));

        vm.warp(boundary - veto); // veto would end exactly at the boundary: rejected
        vm.prank(resolver);
        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
        adjudicator.resolve(market, 1, keccak256("still too late"));

        // Latest admissible proposal settles strictly before the timeout opens.
        vm.warp(boundary - veto - 1);
        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("yes"));
        uint256 adjFees =
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east));
        assertGt(adjFees, 0);
        vm.warp(boundary - 1);
        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
        TruthMarket(market).invalidate();
        adjudicator.settle(market);
        vault.finalize(market);
        assertEq(
            uint8(TruthMarket(market).settlementKind()),
            uint8(ITruthMarket.SettlementKind.ADJUDICATED)
        );
        assertEq(TruthMarket(market).winningOutcome(), 1);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east)),
            adjFees,
            "adjudicated: fees retained"
        );
    }

    /// OA-L6: a zero-proceeds sell changes shares without moving seller tokens.
    function test_zeroProceedsSellMovesNoTokens() public {
        _createMarket();
        _seedAmmPosition();
        uint256 cashBefore = east.balanceOf(trader);
        (uint256 yesBefore,) = amm.getPosition(market, trader);
        (uint256 cost,, uint256 net,) = amm.getPositionQuote(market, 1, -1);
        assertEq(cost, 0, "1 wei sale sits inside the series-error band");
        assertEq(net, 0);
        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -1, 0);
        assertEq(proceeds, 0);
        (uint256 yesAfter,) = amm.getPosition(market, trader);
        assertEq(yesBefore - yesAfter, 1);
        assertEq(east.balanceOf(trader), cashBefore);
        _assertSystemSolvent();
    }

    /// OA-M3: the headroom view reports both the trade domain and the admission cap.
    function test_liquidityHeadroomView() public {
        _createMarket();
        uint256 b = amm.getLiquidity(market);
        (uint256 tradeRoom, uint256 admitRoom) = amm.liquidityHeadroom(market);
        assertEq(tradeRoom, 1e36 - b);
        assertEq(admitRoom, 5e35 - b);
        _seedAmmPosition();
        uint256 b2 = amm.getLiquidity(market);
        assertGt(b2, b, "fee capital grew b");
        (uint256 tradeRoom2,) = amm.liquidityHeadroom(market);
        assertEq(tradeRoom2, 1e36 - b2);
        vm.expectRevert(AMMEngine.NotInitialized.selector);
        amm.liquidityHeadroom(address(0xDEAD));
    }
}

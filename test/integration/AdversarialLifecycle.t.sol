// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";

/**
 * @title Adversarial lifecycle suite
 * @notice Every claim and every mint attempted in every non-permitting state,
 *         the reversible-pause edge and finalize-vs-first-burn on the real stack.
 *         Position payouts and LP redemption share one final outcome.
 */
contract AdversarialLifecycleTest is DualTokenBase {
    // ============================================
    // A proposal closes trading. A veto leaves it closed. Settlement does too.
    // ============================================

    function test_ResolveVeto_KeepsTradingClosedBeforeTheDeadline() public {
        address guardian = address(0x64A4D);
        adjudicator.approveGuardian(guardian); // committed before profile freezing
        _createMarket();
        TruthMarket tm = TruthMarket(market);
        assertTrue(tm.isTradingOpen());
        assertTrue(tm.isLiquidityOpen());
        assertFalse(tm.resolutionAttempted());

        // A successful resolve closes both predicates.
        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("early"));
        assertTrue(tm.resolutionAttempted());
        assertFalse(tm.isTradingOpen());
        assertFalse(tm.isLiquidityOpen());
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);

        // Guardian veto returns LIVE and leaves both venues closed.
        vm.prank(guardian);
        adjudicator.dispute(market);
        assertTrue(tm.resolutionAttempted(), "veto leaves the marker set");
        assertFalse(tm.isTradingOpen(), "veto before the deadline stays closed");
        assertFalse(
            tm.isLiquidityOpen(), "veto before the deadline keeps liquidity closed"
        );
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
    }

    function test_ResolveSettle_DoesNotReopen() public {
        _createMarket();
        _resolveAndSettle(1);
        assertFalse(TruthMarket(market).isTradingOpen(), "settlement is terminal");
        assertFalse(TruthMarket(market).isLiquidityOpen(), "liquidity stays closed");
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
    }

    // ============================================
    // Bootstrap vs incremental mints around startTime
    // ============================================

    function test_PreStart_BootstrapMintOK_TradingClosed() public {
        _createMarketWithStart(
            uint64(block.timestamp + 1 days), uint64(block.timestamp + 20 days)
        );
        // Bootstrap mint happened inside createMarket, before startTime:
        assertGt(lp.balanceOf(creator), 0, "bootstrap mint pre-start OK");
        assertTrue(orderEngine.isMarketRegistered(market), "book registered atomically");
        assertTrue(TruthMarket(market).isLiquidityOpen(), "no start lower bound");
        assertFalse(TruthMarket(market).isTradingOpen());

        // Incremental mints (trades) closed until startTime
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);

        vm.warp(block.timestamp + 1 days);
        assertTrue(TruthMarket(market).isTradingOpen(), "opens at startTime");
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
    }

    // ============================================
    // Claims / mutations in every non-permitting state
    // ============================================

    function test_NonPermittingStates_AllGuarded() public {
        _createMarket();
        _seedAmmPosition();

        // Before settlement: redeemLP + adjudicator claim + LP pull all closed
        // (redeemLP's lazy finalize fires first — NotFinalizable pre-settlement)
        vm.prank(creator);
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        amm.redeemLP(market, 1e18);

        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        bookVault.claimResolutionFees(market);

        vm.prank(creator);
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        vault.claimLPDividend(market); // earning-time fees remain settlement-gated

        // Top-ups remain disabled.
        vm.prank(creator);
        vm.expectRevert(AMMEngine.TopUpsDisabled.selector);
        amm.increaseLiquidityFromCreator(market, 1e18);

        // SETTLED: trading closed
        _resolveAndSettle(1);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
    }

    function test_DeadlineBoundary_ClosesBothVenuesAtExactDeadline() public {
        uint64 dl = uint64(block.timestamp + 3 days);
        _createMarketWithStart(0, dl);
        assertTrue(orderEngine.isMarketRegistered(market), "book registered at creation");

        vm.warp(uint256(dl) - 1);
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 500, 1e18, 256)); // the book accepts a resting order

        vm.warp(dl);
        assertTrue(TruthMarket(market).isLive(), "compatibility predicate stays live");
        assertFalse(TruthMarket(market).isTradingOpen(), "deadline is exclusive");
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 500, 1e18, 256));
    }

    // ============================================
    // Resolution marker: successful authorized calls only
    // ============================================

    function test_ResolutionAttemptMarker_OnlySuccessfulAuthorizedResolve() public {
        _createMarket();
        TruthMarket tm = TruthMarket(market);

        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        tm.resolve(1);
        assertFalse(tm.resolutionAttempted(), "unauthorized call cannot set marker");

        vm.prank(address(adjudicator));
        vm.expectRevert(TruthMarket.InvalidOutcome.selector);
        tm.resolve(3);
        assertFalse(tm.resolutionAttempted(), "reverted call cannot set marker");

        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("valid"));
        assertTrue(tm.resolutionAttempted());
    }

    // ============================================
    // Settlement opens both position payouts and LP redemption
    // ============================================

    function test_FinalOutcome_OpensPositionAndFeeClaimsTogether() public {
        _createMarket();
        _seedAmmPosition();
        _resolveAndSettle(1);
        vault.finalize(market);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 400e18);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        assertGt(amm.redeemLP(market, creatorLP), 0);
        _assertSystemSolvent();
    }

    function test_PartialLPBurn_InterleavedWithWinnerAndFeeClaims() public {
        _createMarket();
        _seedAmmPosition();
        _resolveAndSettle(1);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP / 2);
        assertGe(amm.getMarketCollateral(market), 400e18);
        vm.prank(creator);
        vault.claimLPDividend(market);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 400e18);
        uint256 remainingLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, remainingLP);
        assertEq(vault.lpEntitlementOf(market, creator, address(usdc)), 0);
        _assertSystemSolvent();
    }

    // ============================================
    // Finalize race: book value remains outside LP on invalidation
    // ============================================

    function test_FirstBurn_TriggersInvalidationAndRedirect() public {
        _createMarket();
        _seedAmmPosition();
        // Book fees fully allocate to resolution/refund and protocol claims.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 10));
        uint256 adjPot =
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 protocolPot =
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        assertGt(adjPot, 0);
        assertGt(protocolPot, 0);

        // The adjudicator abandons the market; invalidation becomes eligible
        vm.warp(block.timestamp + 20 days + 7 days + 1);

        // The FIRST burn lazily finalizes and permissionlessly invalidates.
        // The independent book resolution allocation becomes a payer refund.
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP);

        assertEq(
            uint8(TruthMarket(market).settlementKind()),
            uint8(2), // INVALIDATED
            "first claimant made settlement happen"
        );
        assertEq(
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc)),
            adjPot,
            "AMM finalization never debits the book"
        );
        assertEq(
            vault.lpEntitlementOf(market, creator, address(usdc)),
            0,
            "LP receives zero book token"
        );
        assertEq(bookVault.claimTimeoutRefund(market, alice), adjPot);
        assertEq(bookVault.claimProtocolFees(market), protocolPot);
        assertEq(bookVault.totalLiabilitiesOf(address(usdc)), 0);
        _assertSystemSolvent();
    }
}

/**
 * @title Audit-fix regressions (PR #46 blind audit — H2 rounding, H3 window)
 */
contract AuditFixRegressionTest is DualTokenBase {
    // ── H2: inbound WAD->native rounds UP; a round trip cannot extract unbacked value ──
    /// @dev Complementary buys mint outcome inventory; complementary sells merge
    ///      it. Aligned share amounts can still have fractional-native price legs.
    ///      The full round trip must not extract unfunded collateral.
    function test_H2_OpenCloseRoundTrip_NoUnbackedExtraction() public {
        _createMarket();
        _seedAmmPosition();
        // 6-dec book token, share unit = 1e12. Three units at 0.5 cost 1.5 units
        // per leg, preserving the native-rounding witness with valid v5 sizing.
        uint128 amt = 3e12;
        uint256 before = usdc.balanceOf(alice) + usdc.balanceOf(bob);

        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, amt, 256)); // rests: ASK at 500
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 500, amt, 256)); // opens: alice +amt, bob -amt
        assertEq(orderEngine.getNet(market, alice), int256(uint256(amt)));

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 500, amt, 256)); // reserves Alice's YES
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(0, 500, amt, 256)); // merges both inventories
        assertEq(orderEngine.getNet(market, alice), 0);
        assertEq(orderEngine.getNet(market, bob), 0);
        (uint256 yesSupply, uint256 noSupply) = orderEngine.getSupplies(market);
        assertEq(yesSupply, 0);
        assertEq(noSupply, 0);

        assertLe(
            usdc.balanceOf(alice) + usdc.balanceOf(bob),
            before,
            "an open/close round trip must not extract value"
        );
        // The engine still covers whatever it books as backing.
        assertGe(
            usdc.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market),
            "backing must be covered by real balance"
        );
    }

    // H3: only finite timeout bounds and resolution-profile compatibility apply.
    function test_H3_BufferAcceptsOneHourAndThirtyDays() public {
        marketFactory.setInvalidationBuffer(1 hours);
        assertEq(marketFactory.invalidationBuffer(), 1 hours);
        adjudicator =
            new ManualAdjudicator(address(this), address(marketFactory), 30 minutes);
        _createMarket();
        assertEq(TruthMarket(market).invalidationBuffer(), 1 hours);
        marketFactory.setInvalidationBuffer(30 days);
        assertEq(marketFactory.invalidationBuffer(), 30 days);
    }

    function test_H3_BufferRejectsOutsideBounds() public {
        vm.expectRevert(MarketFactory.InvalidBuffer.selector);
        marketFactory.setInvalidationBuffer(1 hours - 1);
        vm.expectRevert(MarketFactory.InvalidBuffer.selector);
        marketFactory.setInvalidationBuffer(30 days + 1);
    }

    function test_H3_VetoMustRemainShorterThanBuffer() public {
        marketFactory.setInvalidationBuffer(1 hours);
        IMarketFactory.MarketParams memory p = _marketParams(
            "veto equals buffer",
            0,
            uint64(block.timestamp + 20 days),
            address(east),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.createMarket(p);
    }
}

/**
 * @title Round-2 audit fix regressions (bounded walk over spent queue entries)
 */
contract AuditFixR2Test is DualTokenBase {
    // ── CLOB: spent (zombie) interior entries must not cause an unbounded gas
    //    walk, and must not use the taker's matchLimit either: a maker could
    //    otherwise burn a taker's whole budget with cancelled orders. matchLimit
    //    counts live entries; the walk over spent entries has its own bound of
    //    Cancelled orders are unlinked, so they are not walked at all. ──
    function test_MatchLimit_CountsLiveEntriesNotCancelledZombies() public {
        _createMarket();
        _seedAmmPosition();

        // Bob rests NO@400: one live blocker, then several orders he cancels,
        // then a second live order behind the zombies.
        // Order ids are global and sequential from 1; nothing places book
        // orders before this, so id1 is the blocker, id2..id6 the zombies,
        // id7 the far live order.
        vm.startPrank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256)); // id1 live (head)
        for (uint256 i = 0; i < 5; i++) {
            orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256)); // id2..id6, cancelled below
        }
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256)); // id7 live (far liquidity)
        for (uint64 id = 2; id <= 6; id++) {
            orderEngine.cancelById(id); // zombies between head and the far order
        }
        vm.stopPrank();

        // Alice crosses YES@600 with a SMALL matchLimit. The five zombie skips
        // do not count against it, so two live entries of budget reach both
        // live orders in one call. The call must NOT revert.
        (uint256 y0,) = orderEngine.getPosition(market, alice);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 20e18, 2)); // matchLimit = 2
        (uint256 y1,) = orderEngine.getPosition(market, alice);
        assertEq(y1 - y0, 20e18, "zombie skips do not use the match budget");
        (uint256 total, uint256 count) = orderEngine.getOrdersAtTick(market, 1, 600);
        assertEq(total + count, 0, "the tick is fully traversed");
    }
}

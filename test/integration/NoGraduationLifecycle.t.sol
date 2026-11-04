// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase, IAmmFeeVault, IBookFeeVault} from "../base/DualTokenBase.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {TruthMarket} from "src/TruthMarket.sol";

/**
 * @title No-graduation lifecycle matrix
 * @notice Both venues register atomically at creation and trade iff
 *         TruthMarket.isTradingOpen(). Every row of the lifecycle matrix is
 *         exercised on the REAL stack for the AMM and the USDG book together:
 *         registration, pre-start, exact start, resolving, veto leaves trading closed, exact
 *         deadline (including after a veto), terminal states, unwind paths after
 *         trading closes, final-outcome parity, fully allocated USDG, timeout refunds, and creation-only pause.
 *
 *         Fixture rates are test values; every assertion is a relationship
 *         (rate x fee basis, split sums, assigned recipients), never a policy constant.
 */
contract NoGraduationLifecycleTest is DualTokenBase {
    function manager() internal view returns (LPPositionManager) {
        return LPPositionManager(amm.positionManager());
    }

    address guardian = address(0x64A4D);

    function setUp() public override {
        super.setUp();
        adjudicator.approveGuardian(guardian);
    }

    // ============================================
    // Helpers
    // ============================================

    function _bookFillOk() internal {
        // Bob rests BUY NO@400 (collateral reserved), Alice takes
        // YES@600 and crosses: one fee-bearing fill through the real book.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 5));
    }

    /// Alice takes 100 YES from bob at 0.60: alice +100, bob -100.
    function _openAliceLong100() internal {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 256));
    }

    /// Alice reserves 50 held YES for sale at 0.30; bob bids 0.20 for 100 YES.
    /// The sell posts inventory without new cash. 300 > 200, so
    /// they rest side by side without crossing.
    function _restNonCrossingPair() internal {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 300, 50e18, 256));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 200, 100e18, 256));
    }

    function _cancelNonCrossingPair() internal {
        vm.prank(alice);
        orderEngine.cancel(market, 1, 300);
        vm.prank(bob);
        orderEngine.cancel(market, 0, 200);
    }

    function _ammTradeOk() internal {
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
    }

    function _assertBothVenuesClosed() internal {
        assertFalse(TruthMarket(market).isTradingOpen());
        vm.prank(trader);
        vm.expectRevert(AMMEngine.MarketNotLive.selector);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 5));
        // A resting (collateral-entry) order is also refused by the book path.
        vm.prank(bob);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
    }

    function _assertBothVenuesOpen() internal {
        assertTrue(TruthMarket(market).isTradingOpen());
        _ammTradeOk();
        _bookFillOk();
    }

    function _resolve(uint8 outcome) internal {
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("data"));
    }

    function _veto() internal {
        vm.prank(guardian);
        adjudicator.dispute(market);
    }

    // ============================================
    // 1. Atomic dual registration, no activation transaction
    // ============================================

    function test_Create_RegistersBothVenuesAtomically() public {
        uint256 count0 = marketFactory.getMarketCount();
        _createMarket();
        assertEq(marketFactory.getMarketCount(), count0 + 1);
        assertEq(vault.tokenAOf(market), address(east), "vault registered");
        assertEq(amm.tokenAOf(market), address(east), "AMM initialized");
        assertTrue(orderEngine.isMarketRegistered(market), "OrderEngine registered");
        assertTrue(orderEngine.isMarketRegistered(market), "SoothBook registered");
        assertGt(lp.balanceOf(creator), 0, "bootstrap LP minted");

        // The book trades from startTime with zero AMM volume and no owner,
        // keeper, or threshold call in between.
        uint256 vault0 = usdc.balanceOf(address(bookVault));
        _bookFillOk();
        assertGt(
            usdc.balanceOf(address(bookVault)) - vault0, 0, "book fee with no AMM volume"
        );
    }

    function test_Create_SecondRegistrationOfSameMarketIsImpossible() public {
        _createMarket();
        vm.prank(address(marketFactory));
        vm.expectRevert(OrderEngine.MarketAlreadyRegistered.selector);
        orderEngine.registerMarket(market, address(usdc), 0.5e18);
        vm.prank(address(marketFactory));
        vm.expectRevert(VenueFeeVault.AlreadyRegistered.selector);
        vault.registerMarket(market, address(east), 18, 1, address(this));
    }

    function test_NoGraduationSurfaceRemains() public {
        _createMarket();
        (bool ok1,) = address(marketFactory)
            .call(abi.encodeWithSignature("notifyGraduation(address)", market));
        assertFalse(ok1, "notifyGraduation removed");
        (bool ok2,) = address(marketFactory)
            .call(abi.encodeWithSignature("isGraduated(address)", market));
        assertFalse(ok2, "isGraduated removed");
        (bool ok3,) = address(vault)
            .call(abi.encodeWithSignature("reportPreGradFee(address,uint256)", market, 1));
        assertFalse(ok3, "reportPreGradFee removed");
        (bool ok4,) =
            address(vault).call(abi.encodeWithSignature("isMintingOpen(address)", market));
        assertFalse(ok4, "isMintingOpen removed");
        (bool ok5,) = address(marketFactory)
            .call(abi.encodeWithSignature("setDefaultTrialPeriod(uint64)", uint64(1)));
        assertFalse(ok5, "trial period removed");
    }

    // ============================================
    // 2. Lifecycle matrix on both venues
    // ============================================

    function test_LifecycleMatrix_BothVenues() public {
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 dl = uint64(block.timestamp + 20 days);
        _createMarketWithStart(start, dl);
        TruthMarket tm = TruthMarket(market);

        // Registered but pre-start: both closed, liquidity predicate open.
        assertTrue(orderEngine.isMarketRegistered(market));
        assertTrue(tm.isLiquidityOpen());
        vm.warp(uint256(start) - 1);
        _assertBothVenuesClosed();

        // Exact start: both open.
        vm.warp(start);
        _assertBothVenuesOpen();

        // The inherited three-day trial point is meaningless: still trading.
        vm.warp(uint256(start) + 3 days + 1);
        _assertBothVenuesOpen();

        // Resolving: both closed, marker set, liquidity closed.
        _resolve(1);
        assertTrue(tm.resolutionAttempted());
        assertFalse(tm.isLiquidityOpen());
        _assertBothVenuesClosed();

        // Veto before the deadline returns LIVE and leaves both venues closed.
        _veto();
        assertEq(uint8(tm.state()), uint8(TruthMarket.MarketState.LIVE));
        assertTrue(tm.resolutionAttempted(), "veto leaves the marker set");
        assertFalse(tm.isLiquidityOpen(), "liquidity stays closed");
        _assertBothVenuesClosed();

        // The deadline does not reopen a market that has already been proposed.
        vm.warp(uint256(dl) - 1);
        _assertBothVenuesClosed();
        vm.warp(dl);
        assertTrue(tm.isLive(), "compatibility predicate ignores deadline");
        _assertBothVenuesClosed();

        // A veto landing after the deadline restores LIVE but not trading.
        _resolve(0);
        _veto();
        assertEq(uint8(tm.state()), uint8(TruthMarket.MarketState.LIVE));
        _assertBothVenuesClosed();

        // Terminal: settle; both closed forever.
        _resolveAndSettle(1);
        assertTrue(tm.isSettled());
        _assertBothVenuesClosed();
        assertFalse(tm.isLiquidityOpen());
    }

    function test_Terminal_PermissionlessInvalidation_ClosesBoth() public {
        _createMarket();
        _assertBothVenuesOpen();
        uint64 dl = TruthMarket(market).deadline();
        vm.warp(uint256(dl) + uint256(TruthMarket(market).invalidationBuffer()));
        TruthMarket(market).invalidate();
        assertEq(uint8(TruthMarket(market).settlementKind()), uint8(2), "INVALIDATED");
        _assertBothVenuesClosed();
        assertFalse(TruthMarket(market).isLiquidityOpen());
    }

    function test_FailedResolve_DoesNotCloseLiquidityOrTrading() public {
        _createMarket();
        TruthMarket tm = TruthMarket(market);

        // Unauthorized direct call.
        vm.prank(trader);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        tm.resolve(1);
        // Bad outcome from the adjudicator address itself.
        vm.prank(address(adjudicator));
        vm.expectRevert(TruthMarket.InvalidOutcome.selector);
        tm.resolve(3);
        // Wrong resolver through the adjudicator.
        vm.prank(trader);
        vm.expectRevert();
        adjudicator.resolve(market, 1, keccak256("x"));

        assertFalse(tm.resolutionAttempted(), "no failed call sets the marker");
        assertTrue(tm.isLiquidityOpen());
        _assertBothVenuesOpen();
    }

    // ============================================
    // 3. Resolve/veto cycles never move custody
    // ============================================

    function testFuzz_ResolveVetoCycles_LeaveCustodyUnchanged(uint8 cycles) public {
        cycles = uint8(bound(cycles, 1, adjudicator.GUARDIAN_VETO_CAP()));
        _createMarket();
        _seedAmmPosition();
        _bookFillOk();
        vm.prank(trader);
        amm.tradePositions(market, 1, -50e18, 0); // an immediate seller payout

        uint256 coll0 = amm.getMarketCollateral(market);
        uint256 sellerCash0 = east.balanceOf(trader);
        uint256 vaultEast0 = vault.totalLiabilitiesOf(address(east));
        uint256 vaultUsdc0 = bookVault.totalLiabilitiesOf(address(usdc));
        uint256 backing0 = orderEngine.getCollateralBacking(market);
        uint256 lpSupply0 = lp.totalSupply();

        for (uint256 i = 0; i < cycles; i++) {
            _resolve(uint8(i % 2));
            _assertBothVenuesClosed();
            _veto();
            assertTrue(TruthMarket(market).resolutionAttempted());
            assertFalse(TruthMarket(market).isLiquidityOpen());
            assertFalse(TruthMarket(market).isTradingOpen());
        }

        assertEq(amm.getMarketCollateral(market), coll0, "collateral unchanged");
        assertEq(east.balanceOf(trader), sellerCash0, "paid proceeds unchanged");
        assertEq(vault.totalLiabilitiesOf(address(east)), vaultEast0);
        assertEq(bookVault.totalLiabilitiesOf(address(usdc)), vaultUsdc0);
        assertEq(orderEngine.getCollateralBacking(market), backing0, "backing unchanged");
        assertEq(lp.totalSupply(), lpSupply0, "no LP minted by lifecycle transitions");

        assertFalse(
            TruthMarket(market).isTradingOpen(),
            "trading stays closed after the last veto"
        );
        _assertSystemSolvent();
    }

    // ============================================
    // 4. Liquidity predicate gates separate-entry public additions
    // ============================================

    function _fundLiquidityProvider() internal {
        east.mint(creator, 10_000e18);
        vm.prank(creator);
        east.approve(address(amm), type(uint256).max);
    }

    function test_TopUp_OpenBeforeStart_ClosedAfterResolveVetoDeadlineSettle() public {
        _fundLiquidityProvider();
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 dl = uint64(block.timestamp + 20 days);
        _createMarketWithStart(start, dl);
        TruthMarket tm = TruthMarket(market);

        // Before start: liquidity open, trading closed, top-up mints LP.
        assertTrue(tm.isLiquidityOpen());
        assertFalse(tm.isTradingOpen());
        uint256 lp0 = lp.balanceOf(creator);
        uint256 b0 = amm.getLiquidity(market);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 1e18);
        vm.prank(creator);
        (uint256 receipt,) = amm.increaseLiquidity(market, 1e18, limits);
        assertGt(manager().balanceOf(creator, receipt), 0, "separate entry minted");
        assertEq(lp.balanceOf(creator), lp0, "bootstrap is not diluted");
        assertEq(amm.getLiquidity(market), b0 + 1e18);

        // Resolving: closed.
        vm.warp(start);
        _resolve(1);
        vm.prank(creator);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(market, 1e18, limits);

        // Veto before the deadline leaves new liquidity closed.
        _veto();
        assertFalse(tm.isTradingOpen());
        assertFalse(tm.isLiquidityOpen());
        vm.prank(creator);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(market, 1e18, limits);

        // Settled: closed.
        _resolveAndSettle(1);
        vm.prank(creator);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(market, 1e18, limits);
    }

    function test_TopUp_ClosedAtExactDeadline_WithoutAnyResolution() public {
        _fundLiquidityProvider();
        uint64 dl = uint64(block.timestamp + 3 days);
        _createMarketWithStart(0, dl);

        vm.warp(uint256(dl) - 1);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 1e18);
        vm.prank(creator);
        amm.increaseLiquidity(market, 1e18, limits);

        vm.warp(dl);
        assertFalse(TruthMarket(market).resolutionAttempted());
        assertFalse(TruthMarket(market).isLiquidityOpen(), "closed by time alone");
        vm.prank(creator);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(market, 1e18, limits);
    }

    // ============================================
    // 5. Unwind paths stay usable after trading closes
    // ============================================

    function test_UnwindAfterDeadline_CancelMergeAndSettleAfterDirectPayout() public {
        uint64 dl = uint64(block.timestamp + 20 days);
        _createMarketWithStart(0, dl);
        _seedAmmPosition();

        // Book state: Alice is long 100 and rests a closing ask for 50 of them;
        // Bob, short 100, rests a bid. Neither crosses (ask 300 > bid 200).
        _openAliceLong100();
        vm.prank(alice);
        orderEngine.split(market, 10e18, 10e6, uint64(block.timestamp + 1 days));
        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        _restNonCrossingPair();
        assertEq(
            usdc.balanceOf(alice),
            aliceUsdc0,
            "sell reserves owned shares without new cash"
        );
        assertGt(bobUsdc0 - usdc.balanceOf(bob), 0);

        // AMM state: direct sell payout immediately before the deadline.
        vm.warp(uint256(dl) - 1);
        uint256 traderEast0 = east.balanceOf(trader);
        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -100e18, 0);

        vm.warp(dl);
        _assertBothVenuesClosed();

        // Cancellation releases the sell reservation and refunds the opening bid.
        // Gross ownership remains intact throughout the resting order.
        _cancelNonCrossingPair();
        assertEq(orderEngine.getNet(market, alice), 100e18, "the long survives cancel");
        assertEq(usdc.balanceOf(alice), aliceUsdc0, "sell cancellation moves no cash");
        assertApproxEqAbs(usdc.balanceOf(bob), bobUsdc0, 1, "bid refunded");
        vm.prank(alice);
        assertEq(
            orderEngine.merge(market, 10e18, 10e6, uint64(block.timestamp + 1 days)), 10e6
        );
        assertEq(
            usdc.balanceOf(alice), aliceUsdc0 + 10e6, "complete set merges after deadline"
        );

        assertEq(
            east.balanceOf(trader) - traderEast0,
            proceeds,
            "sale paid before deadline and remains paid after cutoff"
        );

        // Settlement and claims after the terminal state.
        _resolveAndSettle(1);
        vm.prank(alice);
        uint256 bookPayout = orderEngine.settlePosition(market);
        assertEq(bookPayout, 100e6, "book settles the long by final outcome");
        vm.prank(trader);
        uint256 ammPayout = amm.settlePosition(market);
        assertEq(ammPayout, 300e18);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP);
        vm.prank(creator);
        amm.claimFloor(market);
        _assertSystemSolvent();
    }

    function test_UnwindAfterInvalidation_CancelAndSettle() public {
        _createMarket();
        _seedAmmPosition();
        _openAliceLong100();
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        _restNonCrossingPair();

        TruthMarket tm = TruthMarket(market);
        vm.warp(uint256(tm.deadline()) + uint256(tm.invalidationBuffer()));
        tm.invalidate();
        _assertBothVenuesClosed();

        _cancelNonCrossingPair();
        assertApproxEqAbs(usdc.balanceOf(bob), bobUsdc0, 1);

        // INVALID pays half of each owned outcome: Alice's 100 YES and Bob's
        // 100 NO draw 50 apiece and empty the backing.
        vm.prank(alice);
        uint256 bookPayout = orderEngine.settlePosition(market);
        assertEq(bookPayout, 50e6, "INVALID pays gross owned shares / 2 on the book");
        vm.prank(bob);
        assertEq(orderEngine.settlePosition(market), 50e6, "and the same to the short");
        assertEq(orderEngine.getCollateralBacking(market), 0, "fully unwound");
        vm.prank(trader);
        uint256 ammPayout = amm.settlePosition(market);
        assertEq(ammPayout, 200e18, "INVALID pays (yes+no)/2 on the AMM");
        assertGe(
            usdc.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market),
            "backing never underflows through cancel + settle"
        );
        _assertSystemSolvent();
    }

    function test_CancelAfterVetoAndAfterSettle() public {
        _createMarket();
        uint256 bobUsdc0 = usdc.balanceOf(bob);
        vm.startPrank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        vm.stopPrank();
        _resolve(1);
        // Resting orders can be cancelled while resolving.
        vm.prank(bob);
        orderEngine.cancel(market, 1, 600); // NO at 400 rests as an ASK at YES 600
        uint256 afterResolvingCancel = usdc.balanceOf(bob);
        assertGt(afterResolvingCancel, bobUsdc0 - 100e6, "resolving cancel returns cash");
        assertLt(afterResolvingCancel, bobUsdc0, "the second order stays reserved");

        _veto();
        assertFalse(
            TruthMarket(market).isTradingOpen(),
            "veto before the deadline leaves trading closed"
        );
        _resolveAndSettle(0);
        // The order left resting through the veto can still be cancelled after settlement.
        vm.prank(bob);
        orderEngine.cancel(market, 1, 600);
        assertApproxEqAbs(usdc.balanceOf(bob), bobUsdc0, 2);
    }

    // ============================================
    // 6. Both venues settle by the final outcome; sell proceeds have already been paid
    // ============================================

    function test_FinalOutcome_BothVenuesSettleWithoutFurtherAdjudicatorAction() public {
        _createMarket();
        _seedAmmPosition();
        _bookFillOk();
        uint256 beforeSell = east.balanceOf(trader);
        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -50e18, 0);
        assertEq(east.balanceOf(trader) - beforeSell, proceeds);
        _resolveAndSettle(1);
        (uint256 aliceYes,) = orderEngine.getPosition(market, alice);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), aliceYes / 1e12);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 350e18);
        assertEq(east.balanceOf(trader) - beforeSell, proceeds + 350e18);
        vault.finalize(market);
        _assertSystemSolvent();
    }

    function test_DirectSellPayouts_PersistDuringResolvingAndAttested() public {
        _createMarket();
        _seedAmmPosition();
        uint256 before = east.balanceOf(trader);
        vm.startPrank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -25e18, 0);
        uint256 proceeds2 = amm.tradePositions(market, 1, -25e18, 0);
        vm.stopPrank();
        assertEq(east.balanceOf(trader) - before, proceeds + proceeds2);
        _resolve(1);
        assertTrue(TruthMarket(market).isResolving());
        assertEq(east.balanceOf(trader) - before, proceeds + proceeds2);
        adjudicator.attest(market, bytes(""));
        assertTrue(TruthMarket(market).isAttested());
        assertEq(east.balanceOf(trader) - before, proceeds + proceeds2);
        _assertSystemSolvent();
    }

    // ============================================
    // 7. Fully allocated book fees and source-payer timeout refunds
    // ============================================

    function test_BookRevenue_FullyAllocated_TimeoutRefundsOriginalPayer() public {
        _createMarket();
        _bookFillOk();
        uint256 resolution =
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 protocol =
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        assertGt(resolution, 0);
        assertEq(
            resolution + protocol,
            bookVault.totalLiabilitiesOf(address(usdc)),
            "no unowned remainder"
        );
        assertEq(
            bookVault.refundableResolutionOf(market, alice),
            resolution,
            "original taker paid fee"
        );
        assertEq(
            bookVault.refundableResolutionOf(market, bob),
            0,
            "maker did not pay taker fee"
        );
        assertEq(
            bookVault.sweepUnattributedSurplus(address(usdc)),
            0,
            "allocated revenue is a liability"
        );

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        bookVault.claimProtocolFees(market);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, protocol);
        assertEq(bookVault.totalLiabilitiesOf(address(usdc)), resolution);
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        bookVault.claimTimeoutRefund(market, alice);

        TruthMarket tm = TruthMarket(market);
        vm.warp(uint256(tm.deadline()) + uint256(tm.invalidationBuffer()));
        bookVault.finalize(market);
        assertEq(uint8(tm.settlementKind()), uint8(2));
        vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
        bookVault.claimResolutionFees(market);
        uint256 aliceBefore = usdc.balanceOf(alice);
        // Anyone may trigger payment, but the original fee payer receives it.
        vm.prank(bob);
        assertEq(bookVault.claimTimeoutRefund(market, alice), resolution);
        assertEq(usdc.balanceOf(alice) - aliceBefore, resolution);
        assertEq(bookVault.totalLiabilitiesOf(address(usdc)), 0);
        assertEq(bookVault.sweepUnattributedSurplus(address(usdc)), 0);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP);
        assertEq(vault.lpEntitlementOf(market, creator, address(usdc)), 0);
        _assertSystemSolvent();
    }

    // ============================================
    // 8. Separate venue fees, b growth, and volume independence
    // ============================================

    function test_SeparateVenueFees_AreRelationshipsNotShared() public {
        IAmmFeeVault.AmmConfig memory cfg = _ammConfig();
        IBookFeeVault.BookConfig memory bookCfg = _bookConfig();
        cfg.feeBps = 250;
        bookCfg.feeBps = 50;
        vault.publishAmmConfig(cfg);
        bookVault.publishBookConfig(bookCfg);
        _createMarket();
        assertEq(vault.feeBpsOf(market), 250);
        assertEq(bookVault.feeBpsOf(market), 50);

        // AMM: fee = cost * ammFeeBps; b grows by CAPITAL share only.
        (uint256 cost, uint256 fee,,) = amm.getPositionQuote(market, 1, 10e18);
        assertEq(fee, (cost * 250) / 10_000);
        uint256 b0 = amm.getLiquidity(market);
        uint256 vaultEast0 = east.balanceOf(address(vault));
        vm.prank(trader);
        amm.tradePositions(market, 1, 10e18, type(uint256).max);
        uint256 capital = (fee * cfg.capitalBps) / 10_000;
        assertEq(amm.getLiquidity(market) - b0, capital, "b grows by capitalWad only");
        assertEq(
            east.balanceOf(address(vault)) - vaultEast0,
            fee - capital,
            "AMM revenue share reaches the vault"
        );

        // Book: taker fee = 50 bps of min(0.6, 0.4) x 10 = 4 USDC, independent of
        // AMM volume. The basis is the cheaper leg, not the taker's own 6 USDC.
        uint256 vaultUsdc0 = usdc.balanceOf(address(bookVault));
        _bookFillOk();
        assertApproxEqAbs(
            usdc.balanceOf(address(bookVault)) - vaultUsdc0, (4e6 * 50) / 10_000, 1
        );

        // A later config version does not change this market's pinned rates.
        cfg.feeBps = 400;
        bookCfg.feeBps = 400;
        vault.publishAmmConfig(cfg);
        bookVault.publishBookConfig(bookCfg);
        assertEq(vault.feeBpsOf(market), 250);
        assertEq(bookVault.feeBpsOf(market), 50);
    }

    // ============================================
    // 9. Early resolution with zero volume; creation-only pause
    // ============================================

    function test_EarlyResolveZeroVolume_LPRedeemsFullFloor() public {
        _createMarket();
        _resolveAndSettle(1);
        uint256 deposit = amm.getMarketCollateral(market);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        uint256 floorShare = amm.redeemLP(market, creatorLP);
        assertEq(floorShare, deposit, "no positions: full deposit is the floor");
        uint256 bal0 = east.balanceOf(creator);
        vm.prank(creator);
        amm.claimFloor(market);
        assertEq(east.balanceOf(creator) - bal0, deposit);
        _assertSystemSolvent();
    }

    function test_CreationPause_ExistingVenuesContinue() public {
        _createMarket();
        marketFactory.setCreationPaused(true);
        _assertBothVenuesOpen();
        marketFactory.setCreationPaused(false);
        _assertBothVenuesOpen();
    }

    // ============================================
    // 10. Arbitrary claim order with the book live from start
    // ============================================

    function test_ClaimOrderIndependent_WithBookFromStart() public {
        _createMarket();
        _seedAmmPosition();
        _bookFillOk();
        vm.prank(trader);
        amm.tradePositions(market, 1, -50e18, 0);
        _resolveAndSettle(1);

        uint256 snap = vm.snapshotState();
        // Order A: positions, LP burn, floor, dividends, vault claims.
        vm.prank(trader);
        amm.settlePosition(market);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.startPrank(creator);
        amm.redeemLP(market, creatorLP);
        amm.claimFloor(market);
        vault.claimLPDividend(market);
        vm.stopPrank();
        vault.claimResolutionFees(market);
        uint256 traderA = east.balanceOf(trader);
        uint256 creatorA = east.balanceOf(creator);
        uint256 aliceA = usdc.balanceOf(alice);
        _assertSystemSolvent();

        vm.revertToState(snap);
        // Order B: reverse.
        vault.claimResolutionFees(market);
        vm.startPrank(creator);
        amm.redeemLP(market, creatorLP);
        vault.claimLPDividend(market);
        amm.claimFloor(market);
        vm.stopPrank();
        vm.prank(alice);
        orderEngine.settlePosition(market);
        vm.prank(trader);
        amm.settlePosition(market);
        assertEq(east.balanceOf(trader), traderA, "trader payout independent of order");
        assertEq(east.balanceOf(creator), creatorA, "creator payout independent of order");
        assertEq(usdc.balanceOf(alice), aliceA, "book payout independent of order");
        assertEq(usdc.balanceOf(creator), 0, "LP never receives USDG");
        _assertSystemSolvent();
    }
}

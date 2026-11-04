// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {FactoryFixture, FactoryToken} from "./FactoryFixture.sol";
import {NodeTypes} from "../../src/factory/NodeTypes.sol";
import {MarketFactory} from "../../src/MarketFactory.sol";
import {LPPositionManager} from "../../src/LPPositionManager.sol";
import {TruthMarket} from "../../src/TruthMarket.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {IAMMEngine} from "../../src/interfaces/IAMMEngine.sol";
import {IOrderEngine} from "../../src/interfaces/IOrderEngine.sol";
import {IAmmFeeVault} from "../../src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../../src/interfaces/IBookFeeVault.sol";
import {AdjudicatorBase} from "../../src/adjudicators/AdjudicatorBase.sol";
import {ManualAdjudicator} from "../../src/adjudicators/ManualAdjudicator.sol";
import {DecimalMath} from "../../src/libraries/DecimalMath.sol";
import {NodeRoles} from "../../src/policy/NodeRoles.sol";

contract FactoryMarketsTest is FactoryFixture {
    NodeTypes.Addresses internal a;
    ManualAdjudicator internal adjudicator;
    MarketFactory internal marketFactory;
    address internal sponsor = address(0x5A05);

    function setUp() public override {
        super.setUp();
        a = _deployNode(admin, bytes32(uint256(100)));
        adjudicator = _activate(a, admin);
        marketFactory = MarketFactory(a.marketFactory);
        _fund(admin, a.marketFactory, stable);
        _fund(admin, a.marketFactory, community);
    }

    function _create(address token) internal returns (address market) {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, token);
        vm.prank(admin);
        (market,) = marketFactory.createMarket(p);
    }

    function _assertDualRegistered(address market, address token) internal view {
        assertEq(TruthMarket(market).marketFactory(), a.marketFactory);
        assertTrue(TruthMarket(market).isTradingOpen());
        assertEq(IAMMEngine(a.amm).tokenAOf(market), token);
        assertTrue(IOrderEngine(a.book).isMarketRegistered(market));
        assertGt(IAmmFeeVault(a.ammVault).marketConfigVersion(market), 0);
        assertGt(IBookFeeVault(a.bookVault).marketConfigVersion(market), 0);
    }

    function _admitSponsor(FactoryToken token) internal {
        vm.prank(admin);
        marketFactory.setCreatorAllowed(sponsor, true);
        _fund(sponsor, a.marketFactory, token);
    }

    function _assertBootstrapOwnership(
        address market,
        uint256 positionId,
        uint256 expectedDepositWad
    ) internal view {
        LPPositionManager manager = LPPositionManager(a.positionManager);
        assertEq(TruthMarket(market).creator(), sponsor);
        (address creator, uint256 receipt,,,, uint256 depositWad) =
            marketFactory.markets(market);
        assertEq(creator, sponsor);
        assertEq(receipt, positionId);
        assertEq(depositWad, expectedDepositWad);
        assertEq(manager.positionMarket(positionId), market);
        assertEq(manager.totalSupply(positionId), expectedDepositWad);
        assertEq(manager.balanceOf(sponsor, positionId), expectedDepositWad);
        assertEq(manager.balanceOf(admin, positionId), 0);
        assertEq(manager.balanceOf(protocol, positionId), 0);
        assertEq(manager.balanceOf(a.marketFactory, positionId), 0);
    }

    function _assertCallerFundedBootstrap(FactoryToken token) internal {
        _admitSponsor(token);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(token));
        vm.prank(sponsor);
        token.approve(a.marketFactory, p.maxInputNative);
        uint256[4] memory beforeBalances = [
            token.balanceOf(sponsor),
            token.balanceOf(a.amm),
            token.balanceOf(admin),
            token.balanceOf(protocol)
        ];
        vm.prank(sponsor);
        (address market, uint256 positionId) = marketFactory.createMarket(p);
        uint256 paid = beforeBalances[0] - token.balanceOf(sponsor);
        assertGt(paid, 0);
        assertLe(paid, p.maxInputNative);
        assertEq(token.balanceOf(a.amm) - beforeBalances[1], paid);
        assertEq(token.balanceOf(admin), beforeBalances[2]);
        assertEq(token.balanceOf(protocol), beforeBalances[3]);
        assertEq(token.allowance(sponsor, a.marketFactory), p.maxInputNative - paid);
        assertEq(token.balanceOf(a.marketFactory), 0);
        assertEq(token.balanceOf(a.book), 0);
        assertEq(token.balanceOf(a.ammVault), 0);
        assertEq(token.balanceOf(a.bookVault), 0);
        _assertBootstrapOwnership(
            market, positionId, DecimalMath.toWad(paid, token.decimals())
        );
        _assertDualRegistered(market, address(token));
    }

    function test_AdmittedCallerFundsAndOwnsInitialLpSixDecimals() public {
        _assertCallerFundedBootstrap(stable);
    }

    function test_AdmittedCallerFundsAndOwnsInitialLpEighteenDecimals() public {
        _assertCallerFundedBootstrap(community);
    }

    function test_SameTokenCreationPinsBothVenueConfigsAndTerms() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        address predicted = marketFactory.predictMarketAddress(admin, p, 0);
        bytes32 terms = marketFactory.hashMarketTerms(admin, p);
        uint256 before = stable.balanceOf(admin);
        vm.prank(admin);
        (address market, uint256 lp) = marketFactory.createMarket(p);
        assertEq(market, predicted);
        assertGt(lp, 0);
        assertEq(TruthMarket(market).termsHash(), terms);
        assertEq(marketFactory.marketTermsHash(market), terms);
        assertEq(IAmmFeeVault(a.ammVault).marketConfigVersion(market), 1);
        assertEq(IBookFeeVault(a.bookVault).marketConfigVersion(market), 1);
        assertEq(IAmmFeeVault(a.ammVault).tokenAOf(market), address(stable));
        assertEq(IAmmFeeVault(a.ammVault).tokenADecimalsOf(market), 6);
        assertEq(before - stable.balanceOf(admin), stable.balanceOf(a.amm));
        assertLe(stable.balanceOf(a.amm), p.maxInputNative);
        assertEq(stable.balanceOf(a.book), 0);
        assertEq(stable.balanceOf(a.ammVault), 0);
        assertEq(stable.balanceOf(a.bookVault), 0);
    }

    function test_DistinctTokenAndRepeatedSameTokenMarkets() public {
        address first = _create(address(stable));
        address second = _create(address(community));
        address third = _create(address(stable));
        assertNotEq(first, second);
        assertNotEq(first, third);
        assertEq(marketFactory.creatorNonce(admin), 3);
        assertEq(marketFactory.getMarketCount(), 3);
        assertEq(IAmmFeeVault(a.ammVault).tokenADecimalsOf(second), 18);
        assertGt(community.balanceOf(a.amm), 0);
        assertEq(community.balanceOf(a.book), 0);
    }

    function test_StaleFeeVersionAndHashRejectBeforeFunding() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        IAmmFeeVault.AmmConfig memory config = IAmmFeeVault(a.ammVault).configByVersion(1);
        config.feeBps = 200;
        vm.prank(admin);
        IAmmFeeVault(a.ammVault).publishAmmConfig(config);
        uint256 before = stable.balanceOf(admin);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.StaleConfig.selector);
        marketFactory.createMarket(p);
        p.expectedAmmVersion = 2;
        vm.prank(admin);
        vm.expectRevert(MarketFactory.StaleConfig.selector);
        marketFactory.createMarket(p);
        assertEq(stable.balanceOf(admin), before);
        assertEq(marketFactory.creatorNonce(admin), 0);
    }

    function test_ChangedInvalidationBufferRejectsStaleSponsorCommitment() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        uint256 before = stable.balanceOf(admin);
        vm.prank(admin);
        marketFactory.setInvalidationBuffer(8 days);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidBuffer.selector);
        marketFactory.createMarket(p);
        assertEq(stable.balanceOf(admin), before);
        assertEq(marketFactory.creatorNonce(admin), 0);
        p.expectedInvalidationBuffer = 8 days;
        vm.prank(admin);
        (address market,) = marketFactory.createMarket(p);
        assertEq(TruthMarket(market).invalidationBuffer(), 8 days);
    }

    function test_FundingBoundAndExpiryRevertCloneNonceAndRegistration() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        p.maxInputNative = 1;
        address predicted = marketFactory.predictMarketAddress(admin, p, 0);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.FundingLimit.selector);
        marketFactory.createMarket(p);
        assertEq(predicted.code.length, 0);
        assertEq(marketFactory.creatorNonce(admin), 0);
        assertEq(marketFactory.getMarketCount(), 0);
        assertEq(stable.balanceOf(a.amm), 0);
        p.quoteDeadline = uint64(block.timestamp - 1);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.QuoteExpired.selector);
        marketFactory.createMarket(p);
    }

    function test_UnboundedCreationBudgetAndPostDeadlineQuoteCannotFund() public {
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        uint256 balance = stable.balanceOf(admin);
        p.maxInputNative = type(uint256).max;
        address predicted = marketFactory.predictMarketAddress(admin, p, 0);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.FundingLimit.selector);
        marketFactory.createMarket(p);
        assertEq(predicted.code.length, 0);
        p.maxInputNative = 100e6;
        p.quoteDeadline = p.deadline + 1;
        predicted = marketFactory.predictMarketAddress(admin, p, 0);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.QuoteExpired.selector);
        marketFactory.createMarket(p);
        assertEq(predicted.code.length, 0);
        assertEq(stable.balanceOf(admin), balance);
        assertEq(stable.balanceOf(a.amm), 0);
        assertEq(marketFactory.creatorNonce(admin), 0);
        assertEq(marketFactory.getMarketCount(), 0);
    }

    function test_ProfilesMustBeFrozenBoundAndExplicitlyAdmitted() public {
        ManualAdjudicator mutableProfile =
            new ManualAdjudicator(admin, a.marketFactory, 1 hours);
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.setAdjudicatorAllowed(address(mutableProfile), true);
        ManualAdjudicator wrongNode =
            new ManualAdjudicator(admin, address(0xBAD), 1 hours);
        vm.startPrank(admin);
        wrongNode.approveResolver(resolver);
        wrongNode.freezeProfile();
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.setAdjudicatorAllowed(address(wrongNode), true);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        p.expectedProfileHash = keccak256("substituted-profile");
        vm.prank(admin);
        vm.expectRevert(MarketFactory.InvalidProfile.selector);
        marketFactory.createMarket(p);
    }

    function test_PermissionlessCreatorCannotNameItsOwnResolver() public {
        vm.prank(admin);
        marketFactory.setPermissionlessCreation(true);
        _fund(sponsor, a.marketFactory, stable);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        p.adjudicatorConfig = abi.encode(sponsor, p.deadline, bytes("self-resolved"));
        address predicted = marketFactory.predictMarketAddress(sponsor, p, 0);
        uint256 before = stable.balanceOf(sponsor);
        vm.prank(sponsor);
        vm.expectRevert(AdjudicatorBase.ResolverNotApproved.selector);
        marketFactory.createMarket(p);
        assertEq(predicted.code.length, 0);
        assertEq(stable.balanceOf(sponsor), before);
        // The same account can create with a resolver the admitted profile names.
        p.adjudicatorConfig = abi.encode(resolver, p.deadline, bytes("profile resolver"));
        vm.prank(sponsor);
        (address market,) = marketFactory.createMarket(p);
        _assertDualRegistered(market, address(stable));
        assertEq(adjudicator.getMarketState(market).resolver, resolver);
        vm.prank(sponsor);
        vm.expectRevert();
        adjudicator.resolve(market, 1, keccak256("creator outcome"));
    }

    function test_FailedResolverConfigurationRollsBackFundingAndBothRegistrations()
        public
    {
        _admitSponsor(stable);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        p.adjudicatorConfig =
            abi.encode(resolver, p.deadline + 1, bytes("mismatched deadline"));
        address predicted = marketFactory.predictMarketAddress(sponsor, p, 0);
        uint256 before = stable.balanceOf(sponsor);
        LPPositionManager manager = LPPositionManager(a.positionManager);
        uint256 attemptedPositionId = manager.nextPositionId();
        // A finite allowance must be restored too; maximum approval would not
        // decrease on a successful OpenZeppelin ERC-20 transferFrom.
        vm.prank(sponsor);
        stable.approve(a.marketFactory, p.maxInputNative);
        vm.prank(sponsor);
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        marketFactory.createMarket(p);
        assertEq(predicted.code.length, 0);
        assertEq(marketFactory.creatorNonce(sponsor), 0);
        assertEq(marketFactory.getMarketCount(), 0);
        assertEq(stable.balanceOf(sponsor), before);
        assertEq(stable.allowance(sponsor, a.marketFactory), p.maxInputNative);
        assertEq(stable.balanceOf(a.marketFactory), 0);
        assertEq(stable.balanceOf(a.amm), 0);
        assertEq(stable.balanceOf(a.book), 0);
        assertEq(stable.balanceOf(a.ammVault), 0);
        assertEq(stable.balanceOf(a.bookVault), 0);
        assertEq(manager.nextPositionId(), attemptedPositionId);
        assertEq(manager.totalSupply(attemptedPositionId), 0);
        assertEq(manager.balanceOf(sponsor, attemptedPositionId), 0);
        assertEq(manager.positionMarket(attemptedPositionId), address(0));
        assertEq(manager.positionCount(predicted), 0);
        assertEq(IAMMEngine(a.amm).lpPositionOf(predicted), 0);
        assertEq(IAMMEngine(a.amm).getMarketCollateral(predicted), 0);
        assertFalse(IOrderEngine(a.book).isMarketRegistered(predicted));
        vm.expectRevert();
        IAmmFeeVault(a.ammVault).marketConfigVersion(predicted);
        vm.expectRevert();
        IBookFeeVault(a.bookVault).marketConfigVersion(predicted);
    }

    function test_CreationRejectsDeadlinePastMaximumDuration() public {
        _admitSponsor(stable);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        uint64 limit = uint64(block.timestamp) + marketFactory.MAX_MARKET_DURATION();
        vm.prank(sponsor);
        stable.approve(a.marketFactory, p.maxInputNative);
        // A deadline one below the sentinel used to pass and had no reachable timeout.
        uint64[2] memory tooFar = [limit + 1, type(uint64).max - 1];
        for (uint256 i; i < tooFar.length; ++i) {
            p.deadline = tooFar[i];
            p.adjudicatorConfig = abi.encode(resolver, p.deadline, bytes("too far"));
            vm.prank(sponsor);
            vm.expectRevert(MarketFactory.InvalidSchedule.selector);
            marketFactory.createMarket(p);
        }
        p.deadline = limit;
        p.adjudicatorConfig = abi.encode(resolver, p.deadline, bytes("at the limit"));
        vm.prank(sponsor);
        (address market,) = marketFactory.createMarket(p);
        _assertDualRegistered(market, address(stable));
    }

    function test_OnlyNodeAdminCanPauseCreationAndFundedAmmRemainsLive() public {
        address market = _create(address(stable));
        vm.prank(protocol);
        vm.expectRevert(MarketFactory.Unauthorized.selector);
        marketFactory.setCreationPaused(true);
        assertFalse(marketFactory.creationPaused());
        vm.prank(admin);
        marketFactory.setCreationPaused(true);
        vm.prank(protocol);
        vm.expectRevert(MarketFactory.Unauthorized.selector);
        marketFactory.setCreationPaused(false);
        assertTrue(marketFactory.creationPaused());
        assertFalse(marketFactory.isPaused());
        vm.startPrank(admin);
        stable.approve(a.amm, 100e6);
        IAMMEngine(a.amm).tradePositions(market, 1, int256(10e18), 10e18);
        vm.stopPrank();
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        vm.prank(admin);
        vm.expectRevert(MarketFactory.CreationClosed.selector);
        marketFactory.createMarket(p);
        vm.prank(admin);
        marketFactory.setCreationPaused(false);
        vm.prank(admin);
        (address nextMarket,) = marketFactory.createMarket(p);
        _assertDualRegistered(nextMarket, address(stable));
        vm.prank(admin);
        IAMMEngine(a.amm).tradePositions(market, 1, -int256(5e18), 0);
    }

    function test_RemovedBookAdmissionSetterCannotVetoCreation() public {
        vm.prank(protocol);
        (bool closed,) = a.marketFactory
            .call(abi.encodeWithSignature("setBookAdmissionClosed(bool)", true));
        assertFalse(closed);
        vm.prank(protocol);
        (bool reopened,) = a.marketFactory
            .call(abi.encodeWithSignature("setBookAdmissionClosed(bool)", false));
        assertFalse(reopened);
        assertFalse(marketFactory.creationPaused());
        _assertDualRegistered(_create(address(stable)), address(stable));
    }

    function test_ExistingNodeCreatesMarketsAfterDeploymentPolicyRevocation() public {
        registry.setStablecoin(address(stable), false);
        registry.revokeRelease(RELEASE);
        assertFalse(registry.supportedStablecoins(address(stable)));
        assertTrue(registry.release(RELEASE).revoked);

        _assertDualRegistered(_create(address(stable)), address(stable));
        _assertDualRegistered(_create(address(community)), address(community));
        assertEq(marketFactory.getMarketCount(), 2);
    }

    function test_NodeAdminTransferAffectsFuturePolicyButKeepsMarketSnapshots() public {
        address oldMarket = _create(address(stable));
        vm.prank(admin);
        NodeRoles(a.roles).proposeNodeAdmin(secondAdmin);
        vm.prank(secondAdmin);
        NodeRoles(a.roles).acceptNodeAdmin();
        IAmmFeeVault.AmmConfig memory config = IAmmFeeVault(a.ammVault).configByVersion(1);
        config.operatorRecipient = secondAdmin;
        config.feeBps = 200;
        vm.prank(secondAdmin);
        IAmmFeeVault(a.ammVault).publishAmmConfig(config);
        _fund(secondAdmin, a.marketFactory, stable);
        IMarketFactory.MarketParams memory p = _params(a, adjudicator, address(stable));
        vm.prank(secondAdmin);
        (address newMarket,) = marketFactory.createMarket(p);
        assertEq(IAmmFeeVault(a.ammVault).configOf(oldMarket).operatorRecipient, admin);
        assertEq(
            IAmmFeeVault(a.ammVault).configOf(newMarket).operatorRecipient, secondAdmin
        );
        vm.prank(admin);
        vm.expectRevert(MarketFactory.Unauthorized.selector);
        marketFactory.setTokenAllowed(address(community), false);
    }

    function test_AdmissionAndBufferConfigurationAreExplicit() public {
        NodeTypes.Addresses memory b = _deployNode(secondAdmin, bytes32(uint256(200)));
        MarketFactory other = MarketFactory(b.marketFactory);
        assertEq(other.invalidationBuffer(), 0);
        assertFalse(other.allowedTokens(address(stable)));
        assertFalse(other.permissionlessCreation());
        bytes32 ack = other.TOKEN_RISK_ACKNOWLEDGEMENT();
        vm.prank(protocol);
        vm.expectRevert(MarketFactory.Unauthorized.selector);
        other.setTokenAllowed(address(stable), true, ack);
        vm.prank(secondAdmin);
        other.setInvalidationBuffer(1 hours);
        assertEq(other.invalidationBuffer(), 1 hours);
    }

    function test_DefaultProfileOpensResolutionAtTheDeadline() public {
        ManualAdjudicator strict = _profile(a, admin, false);
        assertFalse(strict.earlyResolution());
        vm.prank(admin);
        marketFactory.setAdjudicatorAllowed(address(strict), true);
        IMarketFactory.MarketParams memory p = _params(a, strict, address(stable));
        vm.prank(admin);
        (address market,) = marketFactory.createMarket(p);
        _assertDualRegistered(market, address(stable));
        vm.warp(p.deadline - 1);
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionTooEarly.selector);
        strict.resolve(market, 1, keccak256("early evidence"));
        assertTrue(TruthMarket(market).isTradingOpen());
        assertTrue(TruthMarket(market).isLiquidityOpen());
        vm.warp(p.deadline);
        vm.prank(resolver);
        strict.resolve(market, 1, keccak256("evidence"));
        assertFalse(TruthMarket(market).isLiquidityOpen());
        vm.prank(guardian);
        strict.dispute(market);
        vm.prank(resolver);
        strict.resolve(market, 0, keccak256("corrected evidence"));
        vm.warp(block.timestamp + 1 hours);
        strict.settle(market);
        assertTrue(TruthMarket(market).isSettled());
        assertEq(TruthMarket(market).winningOutcome(), 0);
    }

    function test_LifecycleStickyLiquidityCutoffAcrossVetoAndTimeout() public {
        address market = _create(address(stable));
        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("first evidence"));
        assertFalse(TruthMarket(market).isLiquidityOpen());
        vm.prank(guardian);
        adjudicator.dispute(market);
        assertTrue(
            TruthMarket(market).resolutionAttempted(), "veto leaves the marker set"
        );
        assertFalse(
            TruthMarket(market).isTradingOpen(),
            "veto before the deadline leaves trading closed"
        );
        assertFalse(TruthMarket(market).isLiquidityOpen());
        vm.warp(TruthMarket(market).deadline() + TruthMarket(market).invalidationBuffer());
        TruthMarket(market).invalidate();
        assertTrue(TruthMarket(market).isSettled());
    }
}

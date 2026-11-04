// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @dev Mock MarketFactory that provides isPaused()
contract MockMarketFactory {
    function isPaused() external pure returns (bool) {
        return false;
    }
}

/// @dev Mock adjudicator with guardian whitelist for TruthMarket testing.
///      veto() calls AdjudicatorBase(adjudicator).isGuardian(), so adjudicator
///      must be a contract. resolve/accept/settle still use vm.prank(address(this)).
contract MockAdjudicator {
    mapping(address => bool) public guardians;

    function isGuardian(address account) external view returns (bool) {
        return guardians[account];
    }

    function setGuardian(address g, bool status) external {
        guardians[g] = status;
    }

    /// @dev Simulate forceInvalidate: resolve with INVALID (2), attest, settle
    function forceInvalidate(address market) external {
        TruthMarket m = TruthMarket(market);
        m.resolve(2); // INVALID = 2
        m.attest();
        m.settle();
    }
}

/**
 * @title TruthMarket Lifecycle Tests
 * @notice Comprehensive tests for market lifecycle: resolve, accept, veto, settle, invalidate
 */
contract TruthMarketLifecycleTest is Test {
    TruthMarket public market;
    TruthMarket public truthMarketImpl;
    MockMarketFactory public mockMarketFactory;
    MockAdjudicator public mockAdjudicator;

    address public creator = address(0xC0E8);
    address public guardian = address(0x6A2D);
    address public randomUser = address(0xBEEF);

    uint64 public startTime;
    uint64 public deadline;
    string constant QUESTION = "Will BTC reach $100k?";

    function setUp() public {
        startTime = uint64(block.timestamp);
        deadline = uint64(block.timestamp + 30 days);

        mockMarketFactory = new MockMarketFactory();
        mockAdjudicator = new MockAdjudicator();
        mockAdjudicator.setGuardian(guardian, true);

        truthMarketImpl = new TruthMarket();

        market = _deployTruthMarket(
            QUESTION,
            startTime,
            deadline,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator
        );
    }

    /// @dev Deploy a TruthMarket clone with immutable args
    function _deployTruthMarket(
        string memory q,
        uint64 st,
        uint64 dl,
        address adj,
        address lpe,
        address c
    ) internal returns (TruthMarket) {
        bytes memory args = abi.encodePacked(
            keccak256(bytes(q)), st, dl, adj, lpe, c, uint64(7 days), keccak256("terms")
        );
        bytes32 salt = keccak256(abi.encodePacked(q, st, dl, adj, lpe, c));
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            address(truthMarketImpl), args, salt
        );
        return TruthMarket(clone);
    }

    // ============================================
    // Constructor Tests
    // ============================================

    function test_Constructor_SetsCorrectValues() public view {
        assertEq(market.questionHash(), keccak256(bytes(QUESTION)));
        assertEq(market.deadline(), deadline);
        assertEq(market.startTime(), startTime);
        assertEq(market.creator(), creator);
        assertEq(market.adjudicator(), address(mockAdjudicator));
        assertEq(market.marketFactory(), address(mockMarketFactory));
        assertEq(market.termsHash(), keccak256("terms"));
    }

    function test_LegacyCloneWithoutTermsCommitmentIsRejected() public {
        bytes memory oldArgs = abi.encodePacked(
            keccak256(bytes(QUESTION)),
            startTime,
            deadline,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator,
            uint64(7 days)
        );
        TruthMarket old =
            TruthMarket(Clones.cloneWithImmutableArgs(address(truthMarketImpl), oldArgs));
        vm.expectRevert(TruthMarket.InvalidLength.selector);
        old.termsHash();
        vm.expectRevert(TruthMarket.InvalidLength.selector);
        old.deadline();
    }

    // ============================================
    // IsLive Tests
    // ============================================

    function test_IsLive_TrueAfterStartTime() public view {
        assertTrue(market.isLive());
    }

    function test_IsLive_FalseBeforeStartTime() public {
        uint64 futureStart = uint64(block.timestamp + 1 days);
        uint64 futureDeadline = uint64(block.timestamp + 30 days);
        TruthMarket futureMarket = _deployTruthMarket(
            QUESTION,
            futureStart,
            futureDeadline,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator
        );

        assertFalse(futureMarket.isLive());
    }

    function test_IsLive_CompatibilityStaysTruePastDeadline() public {
        // isLive() is the inherited compatibility predicate: state == LIVE and
        // timestamp >= startTime. It deliberately ignores the deadline, which is
        // why no venue may gate on it; isTradingOpen() is the canonical gate.
        vm.warp(deadline + 1);
        assertTrue(market.isLive());
        assertFalse(market.isTradingOpen());
    }

    // ============================================
    // isTradingOpen: LIVE && !resolutionAttempted && start <= now < deadline
    // ============================================

    function _futureMarket() internal returns (TruthMarket m, uint64 st, uint64 dl) {
        st = uint64(block.timestamp + 1 days);
        dl = uint64(block.timestamp + 30 days);
        m = _deployTruthMarket(
            "future",
            st,
            dl,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator
        );
    }

    function test_IsTradingOpen_ExactBoundaries() public {
        (TruthMarket m, uint64 st, uint64 dl) = _futureMarket();
        vm.warp(uint256(st) - 1);
        assertFalse(m.isTradingOpen(), "start - 1");
        vm.warp(st);
        assertTrue(m.isTradingOpen(), "exact start");
        vm.warp(uint256(dl) - 1);
        assertTrue(m.isTradingOpen(), "deadline - 1");
        vm.warp(dl);
        assertFalse(m.isTradingOpen(), "exact deadline is exclusive");
        assertTrue(m.isLive(), "compatibility predicate still true");
    }

    function test_IsTradingOpen_FalseInEveryNonLiveState() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertFalse(market.isTradingOpen(), "RESOLVING");
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertFalse(market.isTradingOpen(), "ATTESTED");
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertFalse(market.isTradingOpen(), "SETTLED");
    }

    function test_IsTradingOpen_VetoKeepsTheMarkerSet() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.veto();
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.LIVE));
        assertTrue(market.resolutionAttempted(), "veto leaves the marker set");
        assertFalse(market.isTradingOpen(), "veto before deadline stays closed");
        assertFalse(
            market.isLiquidityOpen(), "veto before deadline keeps liquidity closed"
        );

        vm.warp(deadline);
        vm.prank(address(mockAdjudicator));
        market.resolve(0);
        vm.prank(address(mockAdjudicator));
        market.veto();
        assertTrue(market.resolutionAttempted());
        assertFalse(market.isTradingOpen(), "veto at/after deadline stays closed");
        assertFalse(market.isLiquidityOpen(), "deadline keeps liquidity closed");
    }

    // ============================================
    // resolutionAttempted tracks the outstanding proposal. Liquidity has no start bound.
    // ============================================

    function test_LiquidityOpen_BeforeStartWhilePristine() public {
        (TruthMarket m, uint64 st, uint64 dl) = _futureMarket();
        vm.warp(uint256(st) - 1);
        assertFalse(m.isTradingOpen());
        assertTrue(m.isLiquidityOpen(), "no start lower bound");
        assertFalse(m.resolutionAttempted());
        vm.warp(uint256(dl) - 1);
        assertTrue(m.isLiquidityOpen());
        vm.warp(dl);
        assertFalse(m.isLiquidityOpen(), "closed by the deadline alone");
        assertFalse(m.resolutionAttempted());
    }

    function test_ResolutionAttempted_SetOnlyBySuccessfulResolve() public {
        assertFalse(market.resolutionAttempted());

        vm.prank(randomUser);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.resolve(1);
        assertFalse(market.resolutionAttempted(), "unauthorized");

        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.InvalidOutcome.selector);
        market.resolve(3);
        assertFalse(market.resolutionAttempted(), "bad outcome");

        (TruthMarket m,,) = _futureMarket();
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.BeforeStart.selector);
        m.resolve(1);
        assertFalse(m.resolutionAttempted(), "before start");
        assertTrue(market.isLiquidityOpen(), "failed resolves leave liquidity open");

        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertTrue(market.resolutionAttempted(), "successful resolve sets it");
        assertFalse(market.isLiquidityOpen());
    }

    function test_ResolutionAttempted_StaysSetAcrossVetoCycles() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(address(mockAdjudicator));
            market.resolve(uint8(i % 2));
            assertTrue(market.resolutionAttempted());
            assertFalse(market.isTradingOpen(), "an open proposal closes trading");
            vm.prank(address(mockAdjudicator));
            market.veto();
            assertTrue(market.resolutionAttempted(), "veto leaves the marker set");
            assertFalse(market.isLiquidityOpen(), "liquidity stays closed");
            assertFalse(market.isTradingOpen(), "trading stays closed");
            assertEq(market.winningOutcome(), 0);
        }
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertTrue(market.resolutionAttempted());
        assertFalse(market.isLiquidityOpen());
    }

    function test_LiquidityOpen_FalseInResolvingAttestedSettled() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertFalse(market.isLiquidityOpen(), "RESOLVING");
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertFalse(market.isLiquidityOpen(), "ATTESTED");
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertFalse(market.isLiquidityOpen(), "SETTLED");
    }

    function test_Invalidate_DoesNotNeedMarker_ClosesEverything() public {
        vm.warp(deadline + 7 days);
        market.invalidate();
        assertFalse(market.resolutionAttempted(), "permissionless path leaves it unset");
        assertFalse(market.isLiquidityOpen());
        assertFalse(market.isTradingOpen());
    }

    // ============================================
    // Resolution Tests (was "Settlement")
    // ============================================

    function test_Resolve_YESWins() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1); // YES = 1

        assertTrue(market.isResolving());
        assertEq(market.winningOutcome(), 1);
    }

    function test_Resolve_NOWins() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(0); // NO = 0

        assertTrue(market.isResolving());
        assertEq(market.winningOutcome(), 0);
    }

    function test_Resolve_INVALIDWins() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(2); // INVALID = 2

        assertTrue(market.isResolving());
        assertEq(market.winningOutcome(), 2);
    }

    function test_Resolve_PostedOutcomeHasUniformRedemption() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertEq(market.getRedemptionValue(1), 1e18);
        assertEq(market.getRedemptionValue(0), 0);
    }

    function test_Resolve_RevertWhenNotAdjudicator() public {
        vm.prank(randomUser);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.resolve(1);
    }

    function test_Resolve_RevertWhenBeforeStart() public {
        uint64 futureStart = uint64(block.timestamp + 1 days);
        uint64 futureDeadline = uint64(block.timestamp + 30 days);
        TruthMarket futureMarket = _deployTruthMarket(
            QUESTION,
            futureStart,
            futureDeadline,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator
        );

        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.BeforeStart.selector);
        futureMarket.resolve(1);
    }

    function test_Resolve_RevertWhenInvalidOutcome() public {
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.InvalidOutcome.selector);
        market.resolve(3);
    }

    function test_Resolve_InvalidOutcomeCannotOverwriteProposal() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotLive.selector);
        market.resolve(2);
        assertEq(market.winningOutcome(), 1);
        assertTrue(market.resolutionAttempted());
    }

    function test_Resolve_RevertWhenAlreadyResolving() public {
        // First proposal moves LIVE → RESOLVING.
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.RESOLVING));

        // In-place amendment must be rejected. Re-resolution requires going
        // through veto() first (typically via AdjudicatorBase.dispute()).
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotLive.selector);
        market.resolve(0);
    }

    function test_Resolve_RevertWhenAttested() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.ATTESTED));

        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotLive.selector);
        market.resolve(0);
    }

    // ============================================
    // Accept Tests
    // ============================================

    function test_Accept_Success() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(address(mockAdjudicator));
        market.attest();

        assertTrue(market.isAttested());
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.ATTESTED));
    }

    function test_Accept_RevertWhenNotResolving() public {
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotResolving.selector);
        market.attest();
    }

    function test_Accept_RevertWhenNotAdjudicator() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(randomUser);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.attest();
    }

    // ============================================
    // Veto Tests
    // ============================================

    function test_Veto_SuccessFromAttested() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(address(mockAdjudicator));
        market.attest();

        // Only adjudicator can call veto (via dispute flow)
        vm.prank(address(mockAdjudicator));
        market.veto();

        assertTrue(market.isLive());
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.LIVE));
        assertEq(market.winningOutcome(), 0);
    }

    function test_Veto_SuccessFromResolving() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(address(mockAdjudicator));
        market.veto();

        assertTrue(market.isLive());
        assertEq(market.winningOutcome(), 0);
    }

    function test_Veto_RevertWhenGuardianCallsDirectly() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        // Guardian must go through adjudicator.dispute(), not call veto() directly
        vm.prank(guardian);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.veto();
    }

    function test_Veto_RevertWhenRandomUser() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.prank(randomUser);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.veto();
    }

    function test_Veto_RevertWhenLive() public {
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotAttested.selector);
        market.veto();
    }

    // ============================================
    // Settle Tests (was "Finalize")
    // ============================================

    /// Blind audit 2026-09-10: `isAttested()` returned true for SETTLED too, so an
    /// integrator gating "attested but not yet settled" — the veto window — got the
    /// wrong answer at the one moment it matters.
    function test_isAttestedIsAttestedOnlyNotSettled() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        assertTrue(market.isAttested(), "true in ATTESTED");
        assertFalse(market.isSettled());

        vm.prank(address(mockAdjudicator));
        market.settle();

        assertTrue(market.isSettled(), "now settled");
        assertFalse(market.isAttested(), "and no longer merely attested");
    }

    function test_Settle_ByAdjudicator() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.prank(address(mockAdjudicator));
        market.settle();

        assertTrue(market.isSettled());
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.SETTLED));
    }

    function test_Settle_RevertWhenNotAttested() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        // Still RESOLVING, not ATTESTED

        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotAttested.selector);
        market.settle();
    }

    function test_Settle_RevertWhenNotAuthorized() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.prank(randomUser);
        vm.expectRevert(TruthMarket.NotAdjudicator.selector);
        market.settle();
    }

    function test_Settle_CannotVetoAfterSettle() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();

        // Even the adjudicator can't veto after SETTLED
        vm.prank(address(mockAdjudicator));
        vm.expectRevert(TruthMarket.NotAttested.selector);
        market.veto();
    }

    // ============================================
    // Invalidate Tests
    // ============================================
    // invalidationBuffer is 7 days (set in clone args). After that window
    // anyone can invalidate from any non-SETTLED state.

    function test_Invalidate_Live_AtBuffer() public {
        vm.warp(deadline + 7 days);

        market.invalidate();

        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2); // INVALID
    }

    function test_Invalidate_Resolving_AtBuffer() public {
        // Adjudicator resolved but never attested — half-bricked scenario
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertTrue(market.isResolving());

        vm.warp(deadline + 7 days);
        market.invalidate();

        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2); // INVALID, overrides resolved outcome
    }

    function test_Invalidate_Attested_AtBuffer() public {
        // Adjudicator resolved and attested but never settled
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertTrue(market.isAttested());
        assertFalse(market.isSettled());

        vm.warp(deadline + 7 days);
        market.invalidate();

        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2); // INVALID
    }

    function test_Invalidate_Live_RevertBeforeBuffer() public {
        vm.warp(deadline + 1);
        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
        market.invalidate();
    }

    function test_Invalidate_Resolving_RevertBeforeBuffer() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.warp(deadline + 1 days);
        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
        market.invalidate();
    }

    function test_Invalidate_Attested_RevertBeforeBuffer() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.warp(deadline + 1 days);
        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
        market.invalidate();
    }

    function test_Invalidate_RevertAfterAlreadySettled() public {
        // Normal settlement flow
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertTrue(market.isSettled());

        vm.warp(deadline + 7 days);
        vm.expectRevert(TruthMarket.AlreadySettled.selector);
        market.invalidate();
    }

    function test_Invalidate_RevertOnInfiniteDeadline() public {
        TruthMarket infiniteMarket = _deployTruthMarket(
            "Infinite",
            startTime,
            type(uint64).max,
            address(mockAdjudicator),
            address(mockMarketFactory),
            creator
        );

        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(TruthMarket.InfiniteDeadline.selector);
        infiniteMarket.invalidate();
    }

    function test_Invalidate_PermissionlessCaller() public {
        vm.warp(deadline + 7 days);

        vm.prank(randomUser);
        market.invalidate();

        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2);
    }

    function test_Invalidate_ReplacesPendingOutcomeAndPreservesClosure() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.warp(deadline + 7 days);
        market.invalidate();
        assertEq(market.winningOutcome(), 2);
        assertTrue(market.isSettled());
        assertTrue(market.resolutionAttempted());
        assertFalse(market.isLiquidityOpen());
        assertEq(market.getRedemptionValue(1), 0.5e18);
        assertEq(market.getRedemptionValue(0), 0.5e18);
    }

    function test_Invalidate_EmitsEvent() public {
        vm.warp(deadline + 7 days);

        vm.expectEmit(true, true, false, false);
        emit ITruthMarket.MarketInvalidated(address(market), address(this));
        market.invalidate();
    }

    // ============================================
    // Redemption Value Tests
    // ============================================

    function test_RedemptionValue_YesWins() public {
        _settleMarket(1);

        assertEq(market.getRedemptionValue(1), 1e18); // YES = 1 WAD
        assertEq(market.getRedemptionValue(0), 0); // NO = 0
    }

    function test_RedemptionValue_NoWins() public {
        _settleMarket(0);

        assertEq(market.getRedemptionValue(0), 1e18); // NO = 1 WAD
        assertEq(market.getRedemptionValue(1), 0); // YES = 0
    }

    function test_RedemptionValue_Invalid() public {
        _settleMarket(2);

        assertEq(market.getRedemptionValue(0), 0.5e18); // NO = 0.5 WAD
        assertEq(market.getRedemptionValue(1), 0.5e18); // YES = 0.5 WAD
    }

    function test_RedemptionValue_RevertWhenNotSettled() public {
        vm.expectRevert(TruthMarket.NotAttested.selector);
        market.getRedemptionValue(1);
    }

    // ============================================
    // Full Lifecycle Tests
    // ============================================

    function test_FullLifecycle_HappyPath() public {
        // LIVE
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.LIVE));
        assertTrue(market.isLive());

        // LIVE → RESOLVING
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertTrue(market.isResolving());

        // RESOLVING → ATTESTED
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertTrue(market.isAttested());

        // ATTESTED → SETTLED
        vm.prank(address(mockAdjudicator));
        market.settle();
        assertTrue(market.isSettled());

        assertEq(market.getRedemptionValue(1), 1e18);
    }

    function test_FullLifecycle_WithDispute() public {
        // Resolve → Attest → Dispute (adjudicator veto) → back to LIVE → re-resolve → settle
        vm.prank(address(mockAdjudicator));
        market.resolve(0);

        vm.prank(address(mockAdjudicator));
        market.attest();

        // Adjudicator vetoes (called by adjudicator.dispute() in real flow)
        vm.prank(address(mockAdjudicator));
        market.veto();
        assertTrue(market.isLive());

        // Re-resolve with different outcome
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.prank(address(mockAdjudicator));
        market.settle();

        assertEq(market.getRedemptionValue(1), 1e18);
    }

    // ============================================
    // C2: Adjudicator reverts cleanly after invalidate
    // ============================================

    function test_invalidate_adjudicatorResolveRevertsAfter() public {
        vm.warp(deadline + 7 days + 1);
        market.invalidate();
        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2);

        // resolve() should revert (state is SETTLED, not LIVE)
        vm.prank(address(mockAdjudicator));
        vm.expectRevert();
        market.resolve(1);
    }

    function test_invalidate_adjudicatorAttestRevertsAfter() public {
        // Drive to RESOLVING first, then invalidate
        vm.prank(address(mockAdjudicator));
        market.resolve(1);

        vm.warp(deadline + 7 days + 1);
        market.invalidate();

        // attest() should revert (market is SETTLED now)
        vm.prank(address(mockAdjudicator));
        vm.expectRevert();
        market.attest();
    }

    function test_invalidate_adjudicatorSettleRevertsAfter() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();

        vm.warp(deadline + 7 days + 1);
        market.invalidate();

        // settle() should revert (market already SETTLED)
        vm.prank(address(mockAdjudicator));
        vm.expectRevert();
        market.settle();
    }

    function test_invalidate_winningOutcomeStaysInvalid() public {
        vm.warp(deadline + 7 days + 1);
        market.invalidate();

        assertEq(market.winningOutcome(), 2, "Outcome should be INVALID (2)");
    }

    // ============================================
    // C3: Boundary disjointness — invalidate vs resolve at t == deadline + buffer
    // ============================================

    function test_boundary_resolveSucceedsBeforeBuffer() public {
        uint256 boundary = uint256(deadline) + uint256(market.invalidationBuffer());
        vm.warp(boundary - 1);

        // One second before the boundary: invalidate reverts, resolve succeeds
        vm.expectRevert(TruthMarket.DeadlineNotPassed.selector);
        market.invalidate();

        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        assertTrue(market.isResolving());
    }

    function test_boundary_invalidateSucceedsAtExactBoundary() public {
        uint256 boundary = uint256(deadline) + uint256(market.invalidationBuffer());
        vm.warp(boundary);

        // At exact boundary: invalidate succeeds (>= check)
        market.invalidate();
        assertTrue(market.isSettled());
        assertEq(market.winningOutcome(), 2);

        // After invalidate, resolve reverts (state is SETTLED → NotLive)
        vm.prank(address(mockAdjudicator));
        vm.expectRevert();
        market.resolve(1);
    }

    // ============================================
    // Helpers
    // ============================================

    function _settleMarket(uint8 outcome) internal {
        vm.prank(address(mockAdjudicator));
        market.resolve(outcome);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();
    }

    // ============================================
    // SettlementKind (FeeVault invalidation detector)
    // ============================================

    function test_SettlementKind_UnsetBeforeSettlement() public {
        assertEq(uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.UNSET));

        // Still UNSET mid-lifecycle (RESOLVING / ATTESTED)
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        assertEq(uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.UNSET));
    }

    function test_SettlementKind_AdjudicatedOnSettle() public {
        vm.prank(address(mockAdjudicator));
        market.resolve(1);
        vm.prank(address(mockAdjudicator));
        market.attest();
        vm.prank(address(mockAdjudicator));
        market.settle();

        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.ADJUDICATED)
        );
    }

    function test_SettlementKind_InvalidatedOnPermissionlessInvalidation() public {
        vm.warp(deadline + 7 days);
        market.invalidate();

        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
    }
}

/**
 * @title TruthMarket Immutable Args Decoding Tests
 * @notice Verifies that the 148-byte packed layout is encoded and decoded correctly
 *         across different input values, boundary conditions, and multiple clones.
 */
contract TruthMarketImmutableArgsTest is Test {
    TruthMarket public truthMarketImpl;
    MockMarketFactory public mockMarketFactory;
    MockAdjudicator public mockAdjudicator;

    function setUp() public {
        truthMarketImpl = new TruthMarket();
        mockMarketFactory = new MockMarketFactory();
        mockAdjudicator = new MockAdjudicator();
    }

    function _deployClone(
        bytes32 qHash,
        uint64 st,
        uint64 dl,
        address adj,
        address lpe,
        address c,
        bytes32 salt
    ) internal returns (TruthMarket) {
        bytes memory args = abi.encodePacked(
            qHash, st, dl, adj, lpe, c, uint64(7 days), keccak256("terms")
        );
        assertEq(args.length, 148, "Packed args must be exactly 148 bytes");
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            address(truthMarketImpl), args, salt
        );
        return TruthMarket(clone);
    }

    /// @notice Verify each field decodes to the exact value that was encoded
    function test_ImmutableArgs_BasicDecoding() public {
        bytes32 qHash = keccak256(bytes("Will ETH hit $10k?"));
        uint64 st = 1_700_000_000;
        uint64 dl = 1_702_000_000;
        address adj = address(mockAdjudicator);
        address lpe = address(mockMarketFactory);
        address c = address(0xC0FFEE);

        TruthMarket m = _deployClone(qHash, st, dl, adj, lpe, c, keccak256("basic"));

        assertEq(m.questionHash(), qHash, "questionHash mismatch");
        assertEq(m.startTime(), st, "startTime mismatch");
        assertEq(m.deadline(), dl, "deadline mismatch");
        assertEq(m.adjudicator(), adj, "adjudicator mismatch");
        assertEq(m.marketFactory(), lpe, "marketFactory mismatch");
        assertEq(m.creator(), c, "creator mismatch");
    }

    /// @notice Boundary: all-zero fields (except adjudicator/marketFactory which are contracts)
    function test_ImmutableArgs_ZeroValues() public {
        bytes32 qHash = bytes32(0);
        uint64 st = 0;
        uint64 dl = 0;
        address adj = address(mockAdjudicator);
        address lpe = address(mockMarketFactory);
        address c = address(0);

        TruthMarket m = _deployClone(qHash, st, dl, adj, lpe, c, keccak256("zeros"));

        assertEq(m.questionHash(), bytes32(0), "zero questionHash");
        assertEq(m.startTime(), 0, "zero startTime");
        assertEq(m.deadline(), 0, "zero deadline");
        assertEq(m.adjudicator(), adj, "adjudicator");
        assertEq(m.marketFactory(), lpe, "marketFactory");
        assertEq(m.creator(), address(0), "zero creator");
    }

    /// @notice Boundary: max uint64 values for timestamps
    function test_ImmutableArgs_MaxTimestamps() public {
        bytes32 qHash = keccak256("max-time");
        uint64 st = type(uint64).max;
        uint64 dl = type(uint64).max;
        address adj = address(mockAdjudicator);
        address lpe = address(mockMarketFactory);
        address c = address(type(uint160).max); // 0xFFFF...FFFF

        TruthMarket m = _deployClone(qHash, st, dl, adj, lpe, c, keccak256("max"));

        assertEq(m.startTime(), type(uint64).max, "max startTime");
        assertEq(m.deadline(), type(uint64).max, "max deadline");
        assertEq(m.creator(), address(type(uint160).max), "max address creator");
    }

    /// @notice Two clones from the same impl with different args must decode independently
    function test_ImmutableArgs_TwoClonesIndependent() public {
        bytes32 qHash1 = keccak256("Market A");
        bytes32 qHash2 = keccak256("Market B");
        uint64 st1 = 1000;
        uint64 st2 = 2000;
        uint64 dl1 = 3000;
        uint64 dl2 = 4000;
        address c1 = address(0xA);
        address c2 = address(0xB);

        TruthMarket m1 = _deployClone(
            qHash1,
            st1,
            dl1,
            address(mockAdjudicator),
            address(mockMarketFactory),
            c1,
            keccak256("clone1")
        );
        TruthMarket m2 = _deployClone(
            qHash2,
            st2,
            dl2,
            address(mockAdjudicator),
            address(mockMarketFactory),
            c2,
            keccak256("clone2")
        );

        // Clone 1
        assertEq(m1.questionHash(), qHash1);
        assertEq(m1.startTime(), st1);
        assertEq(m1.deadline(), dl1);
        assertEq(m1.creator(), c1);

        // Clone 2 — different values
        assertEq(m2.questionHash(), qHash2);
        assertEq(m2.startTime(), st2);
        assertEq(m2.deadline(), dl2);
        assertEq(m2.creator(), c2);

        // Cross-check: they must differ
        assertTrue(m1.questionHash() != m2.questionHash(), "hashes must differ");
        assertTrue(m1.creator() != m2.creator(), "creators must differ");
    }

    /// @notice Verify raw bytes match the encoding layout exactly
    function test_ImmutableArgs_RawBytesLayout() public {
        bytes32 qHash = keccak256("layout-test");
        uint64 st = 0xAABBCCDDEEFF0011;
        uint64 dl = 0x1122334455667788;
        address adj = address(mockAdjudicator);
        address lpe = address(mockMarketFactory);
        address c = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

        uint64 invBuf = uint64(7 days);
        bytes memory args =
            abi.encodePacked(qHash, st, dl, adj, lpe, c, invBuf, keccak256("terms"));

        _verifyRawOffsets(args, qHash, st, dl, adj, lpe, c, invBuf);

        // Now deploy and confirm the contract's decoder agrees with our manual decode
        TruthMarket m = _deployClone(qHash, st, dl, adj, lpe, c, keccak256("layout"));
        _verifyDeployedImmutables(m, qHash, st, dl, adj, lpe, c);
    }

    /// @notice Fuzz test: random inputs must round-trip through encode → deploy → decode
    function testFuzz_ImmutableArgs_RoundTrip(
        bytes32 qHash,
        uint64 st,
        uint64 dl,
        address adj,
        address lpe,
        address c
    ) public {
        // Use unique salt from all inputs to avoid CREATE2 collisions
        bytes32 salt = keccak256(abi.encodePacked(qHash, st, dl, adj, lpe, c));

        bytes memory args = abi.encodePacked(
            qHash, st, dl, adj, lpe, c, uint64(7 days), keccak256("terms")
        );
        address clone = Clones.cloneDeterministicWithImmutableArgs(
            address(truthMarketImpl), args, salt
        );
        TruthMarket m = TruthMarket(clone);

        assertEq(m.questionHash(), qHash, "fuzz: questionHash");
        assertEq(m.startTime(), st, "fuzz: startTime");
        assertEq(m.deadline(), dl, "fuzz: deadline");
        assertEq(m.adjudicator(), adj, "fuzz: adjudicator");
        assertEq(m.marketFactory(), lpe, "fuzz: marketFactory");
        assertEq(m.creator(), c, "fuzz: creator");
        assertEq(m.termsHash(), keccak256("terms"), "fuzz: termsHash");
    }

    // ============================================
    // Internal helpers (extracted to reduce stack depth)
    // ============================================

    function _verifyRawOffsets(
        bytes memory args,
        bytes32 qHash,
        uint64 st,
        uint64 dl,
        address adj,
        address lpe,
        address c,
        uint64 invBuf
    ) internal pure {
        bytes32 extractedHash;
        uint64 extractedSt;
        uint64 extractedDl;
        address extractedAdj;
        address extractedLpe;
        address extractedC;
        uint64 extractedInvBuf;

        assembly {
            let ptr := add(args, 32)
            extractedHash := mload(ptr)
            extractedSt := shr(192, mload(add(ptr, 32)))
            extractedDl := shr(192, mload(add(ptr, 40)))
            extractedAdj := shr(96, mload(add(ptr, 48)))
            extractedLpe := shr(96, mload(add(ptr, 68)))
            extractedC := shr(96, mload(add(ptr, 88)))
            extractedInvBuf := shr(192, mload(add(ptr, 108)))
        }

        assert(extractedHash == qHash);
        assert(extractedSt == st);
        assert(extractedDl == dl);
        assert(extractedAdj == adj);
        assert(extractedLpe == lpe);
        assert(extractedC == c);
        assert(extractedInvBuf == invBuf);
    }

    function _verifyDeployedImmutables(
        TruthMarket m,
        bytes32 qHash,
        uint64 st,
        uint64 dl,
        address adj,
        address lpe,
        address c
    ) internal view {
        assert(m.questionHash() == qHash);
        assert(m.startTime() == st);
        assert(m.deadline() == dl);
        assert(m.adjudicator() == adj);
        assert(m.marketFactory() == lpe);
        assert(m.creator() == c);
        assert(m.termsHash() == keccak256("terms"));
    }
}

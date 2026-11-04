// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";

contract ProofAdjudicator is AdjudicatorBase {
    constructor(address factory) AdjudicatorBase(msg.sender, factory, 1 hours) {}

    function _requiresAttestation() internal pure override returns (bool) {
        return true;
    }

    function _verifyAttestation(address, bytes calldata) internal pure override {}
}

/// @notice Frozen local/demo resolver profiles; this suite does not prove truth.
contract FrozenAdjudicatorProfileTest is Test {
    ManualAdjudicator internal adjudicator;
    TruthMarket internal implementation;
    address internal guardian = address(0x600D);
    address internal resolver = address(0xA11CE);
    address internal recipient = address(0xFEED);
    uint64 internal deadline;

    function setUp() public {
        implementation = new TruthMarket();
        adjudicator = new ManualAdjudicator(address(this), address(this), 1 hours);
        adjudicator.approveGuardian(guardian);
        adjudicator.setResolutionRecipient(recipient);
        adjudicator.approveResolver(resolver);
        adjudicator.setEarlyResolution(true);
        deadline = uint64(block.timestamp + 1 days);
    }

    function _market(address marketFactory, address adj) internal returns (TruthMarket) {
        bytes memory args = abi.encodePacked(
            keccak256("question"),
            uint64(0),
            deadline,
            adj,
            marketFactory,
            address(this),
            uint64(2 days),
            keccak256("complete terms")
        );
        return TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
    }

    function _configure(TruthMarket market) internal {
        adjudicator.configureMarket(
            address(market), abi.encode(resolver, deadline, bytes(""))
        );
    }

    function test_FundingCannotBindUnfrozenProfile() public {
        TruthMarket market = _market(address(this), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.UnfrozenProfile.selector);
        _configure(market);
        adjudicator.freezeProfile();
        _configure(market);
        assertEq(adjudicator.getMarketState(address(market)).resolver, resolver);
    }

    function test_FrozenHashBindsEffectiveGuardiansResolversRecipientAndDomain() public {
        address second = address(0xB0B);
        adjudicator.approveGuardian(second);
        adjudicator.approveGuardian(second);
        adjudicator.revokeGuardian(guardian);
        address[] memory guardians = adjudicator.guardians();
        assertEq(guardians.length, 1);
        assertEq(guardians[0], second);
        address secondResolver = address(0xCA11);
        adjudicator.approveResolver(secondResolver);
        adjudicator.approveResolver(secondResolver);
        adjudicator.revokeResolver(resolver);
        adjudicator.revokeResolver(resolver);
        address[] memory resolvers = adjudicator.resolvers();
        assertEq(resolvers.length, 1);
        assertEq(resolvers[0], secondResolver);
        adjudicator.freezeProfile();
        bytes32 expected = keccak256(
            abi.encode(
                "SOOTH_FACTORY_RESOLVER_PROFILE_V3",
                block.chainid,
                address(adjudicator),
                address(adjudicator).codehash,
                address(this),
                uint48(1 hours),
                recipient,
                guardians,
                resolvers,
                true,
                bytes("")
            )
        );
        assertEq(adjudicator.profileHash(), expected);
        assertTrue(adjudicator.profileFrozen());
        assertTrue(adjudicator.isGuardian(second));
        assertFalse(adjudicator.isGuardian(guardian));
        assertTrue(adjudicator.isResolver(secondResolver));
        assertFalse(adjudicator.isResolver(resolver));
    }

    function test_ResolverSetAndEarlyRuleChangeTheProfileHash() public {
        ManualAdjudicator other =
            new ManualAdjudicator(address(this), address(this), 1 hours);
        other.approveGuardian(guardian);
        other.setResolutionRecipient(recipient);
        vm.expectRevert(AdjudicatorBase.NoResolver.selector);
        other.freezeProfile();
        vm.expectRevert(AdjudicatorBase.ZeroAddress.selector);
        other.approveResolver(address(0));
        vm.startPrank(resolver);
        vm.expectRevert();
        other.approveResolver(resolver);
        vm.expectRevert();
        other.revokeResolver(resolver);
        vm.expectRevert();
        other.setEarlyResolution(true);
        vm.stopPrank();
        other.approveResolver(resolver);
        assertFalse(other.earlyResolution());
        uint256 beforeFreeze = vm.snapshotState();
        bytes32[3] memory hashes;
        for (uint256 i; i < 3; ++i) {
            if (i == 1) other.approveResolver(address(0xCA11));
            if (i == 2) other.setEarlyResolution(true);
            other.freezeProfile();
            hashes[i] = other.profileHash();
            vm.revertToState(beforeFreeze);
        }
        assertNotEq(hashes[0], hashes[1]);
        assertNotEq(hashes[0], hashes[2]);
        assertNotEq(hashes[1], hashes[2]);
    }

    function test_CreatorCannotNameAResolverOutsideTheProfile() public {
        adjudicator.freezeProfile();
        TruthMarket market = _market(address(this), address(adjudicator));
        address creatorChosen = address(0xC0FFEE);
        vm.expectRevert(AdjudicatorBase.ResolverNotApproved.selector);
        adjudicator.configureMarket(
            address(market), abi.encode(creatorChosen, deadline, bytes(""))
        );
        _configure(market);
        vm.prank(creatorChosen);
        vm.expectRevert(IAdjudicator.NotResolver.selector);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
    }

    function test_OnlyTheSelectedResolverCanPropose() public {
        address otherResolver = address(0xB0B);
        adjudicator.approveResolver(otherResolver);
        adjudicator.freezeProfile();
        TruthMarket market = _market(address(this), address(adjudicator));
        _configure(market);
        vm.prank(otherResolver);
        vm.expectRevert(IAdjudicator.NotResolver.selector);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        vm.expectRevert(IAdjudicator.NotResolver.selector);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        assertTrue(market.isTradingOpen());
        vm.prank(resolver);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        assertEq(adjudicator.getMarketState(address(market)).outcome, 1);
        assertFalse(market.isTradingOpen());
    }

    function test_ResolutionOpensAtDeadlineUnlessProfileAllowsEarly() public {
        ManualAdjudicator strict =
            new ManualAdjudicator(address(this), address(this), 1 hours);
        strict.approveResolver(resolver);
        strict.freezeProfile();
        TruthMarket market = _market(address(this), address(strict));
        strict.configureMarket(address(market), abi.encode(resolver, deadline, bytes("")));
        // A market that never reaches a deadline could never be resolved here.
        uint64 finite = deadline;
        deadline = type(uint64).max;
        TruthMarket endless = _market(address(this), address(strict));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        strict.configureMarket(
            address(endless), abi.encode(resolver, type(uint64).max, bytes(""))
        );
        deadline = finite;
        vm.warp(deadline - 1);
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionTooEarly.selector);
        strict.resolve(address(market), 1, keccak256("evidence"));
        assertTrue(market.isTradingOpen());
        assertTrue(market.isLiquidityOpen());
        vm.warp(deadline);
        vm.prank(resolver);
        strict.resolve(address(market), 1, keccak256("evidence"));
        vm.prank(guardian);
        vm.expectRevert(IAdjudicator.NotGuardian.selector);
        strict.dispute(address(market));
        vm.warp(deadline + 1 hours);
        strict.settle(address(market));
        assertEq(market.winningOutcome(), 1);
    }

    function test_EarlyProfileRejectsZeroAndInfiniteDeadlines() public {
        adjudicator.freezeProfile();
        uint64 finite = deadline;
        deadline = 0;
        TruthMarket zero = _market(address(this), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(zero), abi.encode(resolver, uint64(0), bytes(""))
        );
        deadline = type(uint64).max;
        TruthMarket endless = _market(address(this), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(endless), abi.encode(resolver, type(uint64).max, bytes(""))
        );
        deadline = finite;
        TruthMarket market = _market(address(this), address(adjudicator));
        _configure(market);
        assertEq(adjudicator.getMarketState(address(market)).deadline, finite);
    }

    function test_ConfigureRejectsDeadlinePastMaximumDuration() public {
        adjudicator.freezeProfile();
        uint64 finite = deadline;
        uint64 limit = uint64(block.timestamp) + adjudicator.MAX_MARKET_DURATION();
        deadline = limit + 1;
        TruthMarket tooFar = _market(address(this), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(tooFar), abi.encode(resolver, deadline, bytes(""))
        );
        deadline = limit;
        TruthMarket atLimit = _market(address(this), address(adjudicator));
        adjudicator.configureMarket(
            address(atLimit), abi.encode(resolver, deadline, bytes(""))
        );
        assertEq(adjudicator.getMarketState(address(atLimit)).deadline, limit);
        deadline = finite;
    }

    function _proofProfile() internal returns (ProofAdjudicator proof) {
        proof = new ProofAdjudicator(address(this));
        proof.approveGuardian(guardian);
        proof.approveResolver(resolver);
        proof.setEarlyResolution(true);
        proof.freezeProfile();
    }

    function test_VetoPeriodRunsFromTheCompletedAttestation() public {
        ProofAdjudicator proof = _proofProfile();
        TruthMarket market = _market(address(this), address(proof));
        proof.configureMarket(address(market), abi.encode(resolver, deadline, bytes("")));
        vm.prank(resolver);
        proof.resolve(address(market), 1, keccak256("evidence"));
        // The proof is withheld until the period that began at the proposal has ended.
        vm.warp(block.timestamp + 1 hours + 1);
        proof.attest(address(market), "");
        assertEq(
            proof.getMarketState(address(market)).vetoEndsAt, block.timestamp + 1 hours
        );
        assertFalse(proof.canSettle(address(market)));
        vm.expectRevert(IAdjudicator.VetoWindowActive.selector);
        proof.settle(address(market));
        // Guardians still have the full period to review the proof.
        vm.warp(block.timestamp + 1 hours - 1);
        vm.prank(guardian);
        proof.dispute(address(market));
        assertFalse(
            market.isTradingOpen(), "veto before the deadline leaves trading closed"
        );
        vm.prank(resolver);
        proof.resolve(address(market), 0, keccak256("corrected"));
        proof.attest(address(market), "");
        vm.warp(block.timestamp + 1 hours);
        proof.settle(address(market));
        assertEq(market.winningOutcome(), 0);
    }

    function test_AttestationMustLeaveTheFullVetoPeriodBeforeCutoff() public {
        ProofAdjudicator proof = _proofProfile();
        TruthMarket market = _market(address(this), address(proof));
        proof.configureMarket(address(market), abi.encode(resolver, deadline, bytes("")));
        uint256 cutoff = uint256(deadline) + 2 days;
        vm.prank(resolver);
        proof.resolve(address(market), 1, keccak256("evidence"));
        vm.warp(cutoff - 1 hours);
        vm.expectRevert(IAdjudicator.DeadlinePassed.selector);
        proof.attest(address(market), "");
        vm.warp(cutoff - 1 hours - 1);
        proof.attest(address(market), "");
        vm.warp(cutoff - 1);
        proof.settle(address(market));
        assertEq(market.winningOutcome(), 1);
    }

    function test_ResolverReplacesAProposalThatWasNeverAttested() public {
        ProofAdjudicator proof = _proofProfile();
        TruthMarket market = _market(address(this), address(proof));
        proof.configureMarket(address(market), abi.encode(resolver, deadline, bytes("")));
        vm.prank(resolver);
        proof.resolve(address(market), 1, keccak256("no proof can match this"));
        bytes memory unattested = abi.encodeWithSelector(
            IAdjudicator.InvalidPhase.selector,
            proof.PHASE_ATTESTED(),
            proof.PHASE_RESOLVED()
        );
        vm.prank(guardian);
        vm.expectRevert(unattested);
        proof.dispute(address(market));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(guardian);
        vm.expectRevert(unattested);
        proof.dispute(address(market));
        vm.prank(guardian);
        vm.expectRevert(IAdjudicator.NotResolver.selector);
        proof.resolve(address(market), 0, keccak256("not the resolver"));
        vm.prank(resolver);
        proof.resolve(address(market), 0, keccak256("corrected"));
        IAdjudicator.MarketState memory st = proof.getMarketState(address(market));
        assertEq(st.phase, proof.PHASE_RESOLVED());
        assertEq(st.outcome, 0);
        assertEq(st.dataHash, keccak256("corrected"));
        assertEq(st.vetoEndsAt, block.timestamp + 1 hours);
        assertEq(market.winningOutcome(), 0);
        assertFalse(market.isTradingOpen());
        assertFalse(market.isLiquidityOpen());
        proof.attest(address(market), "");
        // An attested proposal can only be replaced through a guardian dispute.
        bytes memory wrongPhase = abi.encodeWithSelector(
            IAdjudicator.InvalidPhase.selector,
            proof.PHASE_ACTIVE(),
            proof.PHASE_ATTESTED()
        );
        vm.prank(resolver);
        vm.expectRevert(wrongPhase);
        proof.resolve(address(market), 1, keccak256("again"));
        vm.warp(block.timestamp + 1 hours);
        proof.settle(address(market));
        assertEq(market.winningOutcome(), 0);
    }

    function test_ProfileWithoutAttestationCannotReplaceAnUndisputedProposal() public {
        adjudicator.freezeProfile();
        TruthMarket market = _market(address(this), address(adjudicator));
        _configure(market);
        vm.prank(resolver);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        vm.warp(block.timestamp + 1 hours + 1);
        bytes memory wrongPhase = abi.encodeWithSelector(
            IAdjudicator.InvalidPhase.selector,
            adjudicator.PHASE_ACTIVE(),
            adjudicator.PHASE_RESOLVED()
        );
        vm.prank(resolver);
        vm.expectRevert(wrongPhase);
        adjudicator.resolve(address(market), 0, keccak256("changed mind"));
        adjudicator.settle(address(market));
        assertEq(market.winningOutcome(), 1);
    }

    function test_NoGuardianRecipientOrAuthorityMutationAfterFreeze() public {
        adjudicator.freezeProfile();
        bytes32 profile = adjudicator.profileHash();
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.approveGuardian(resolver);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.revokeGuardian(guardian);
        address[] memory empty = new address[](0);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.batchUpdateGuardians(empty, empty);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.setResolutionRecipient(resolver);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.approveResolver(guardian);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.revokeResolver(resolver);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.setEarlyResolution(false);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.transferOwnership(resolver);
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.renounceOwnership();
        vm.expectRevert(AdjudicatorBase.FrozenProfile.selector);
        adjudicator.freezeProfile();
        assertEq(adjudicator.profileHash(), profile);
        assertEq(adjudicator.resolutionRecipient(), recipient);
        assertTrue(adjudicator.isResolver(resolver));
        assertTrue(adjudicator.earlyResolution());
    }

    function test_ProfileRejectsWrongNodeAdjudicatorDeadlineAndZeroResolver() public {
        adjudicator.freezeProfile();
        TruthMarket wrongNode = _market(address(0xBAD), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        _configure(wrongNode);
        TruthMarket wrongAdj = _market(address(this), address(0xBAD));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        _configure(wrongAdj);
        TruthMarket market = _market(address(this), address(adjudicator));
        vm.expectRevert(AdjudicatorBase.InvalidMarketBinding.selector);
        adjudicator.configureMarket(
            address(market), abi.encode(resolver, deadline + 1, bytes(""))
        );
        vm.expectRevert(AdjudicatorBase.ZeroAddress.selector);
        adjudicator.configureMarket(
            address(market), abi.encode(address(0), deadline, bytes(""))
        );
    }

    function test_FrozenGuardianVetoDoesNotReopenTradingOrLiquidity() public {
        adjudicator.freezeProfile();
        TruthMarket market = _market(address(this), address(adjudicator));
        _configure(market);
        assertTrue(market.isLiquidityOpen());
        vm.prank(resolver);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        assertFalse(market.isLiquidityOpen());
        vm.prank(guardian);
        adjudicator.dispute(address(market));
        assertFalse(
            market.isTradingOpen(), "veto before the deadline leaves trading closed"
        );
        assertFalse(market.isLiquidityOpen());
        vm.prank(resolver);
        adjudicator.resolve(address(market), 2, keccak256("honest INVALID"));
        vm.warp(block.timestamp + 1 hours);
        adjudicator.settle(address(market));
        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.ADJUDICATED)
        );
        assertEq(market.winningOutcome(), 2);
    }

    function test_TimeoutRemainsPermissionlessWithFrozenProfile() public {
        adjudicator.freezeProfile();
        TruthMarket market = _market(address(this), address(adjudicator));
        _configure(market);
        vm.prank(resolver);
        adjudicator.resolve(address(market), 1, keccak256("evidence"));
        vm.warp(uint256(deadline) + 2 days);
        vm.prank(address(0xBEEF));
        market.invalidate();
        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
        assertFalse(adjudicator.canSettle(address(market)));
    }
}

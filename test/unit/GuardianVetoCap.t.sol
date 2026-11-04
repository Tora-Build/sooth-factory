// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";

/// @notice Attestation-required profile with an empty proof. Dispute is
///         refused until that proof, and every accepted veto counts.
contract CapProofAdjudicator is AdjudicatorBase {
    constructor(address factory) AdjudicatorBase(msg.sender, factory, 1 hours) {}

    function _requiresAttestation() internal pure override returns (bool) {
        return true;
    }

    function _verifyAttestation(address, bytes calldata) internal pure override {}
}

/// @notice O-2. A resolver cannot outlast a guardian's veto cap into a settlement.
///         The counted veto that reaches the cap locks the market. Timeout INVALID
///         is the remaining terminal path on a finite deadline.
contract GuardianVetoCapTest is Test {
    ManualAdjudicator internal adjudicator;
    TruthMarket internal implementation;
    address internal guardian = address(0x600D);
    address internal other = address(0x600E);
    address internal resolver = address(0xA11CE);
    uint64 internal deadline;

    function setUp() public {
        implementation = new TruthMarket();
        adjudicator = new ManualAdjudicator(address(this), address(this), 1 hours);
        adjudicator.approveGuardian(guardian);
        adjudicator.approveGuardian(other);
        adjudicator.setResolutionRecipient(address(0xFEED));
        adjudicator.approveResolver(resolver);
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        deadline = uint64(block.timestamp + 30 days);
    }

    function _market() internal returns (TruthMarket market) {
        bytes memory args = abi.encodePacked(
            keccak256("cap question"),
            uint64(block.timestamp),
            deadline,
            address(adjudicator),
            address(this),
            address(this),
            uint64(7 days),
            keccak256("cap terms")
        );
        market = TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
        adjudicator.configureMarket(
            address(market), abi.encode(resolver, deadline, bytes(""))
        );
    }

    function _propose(TruthMarket market, uint8 outcome) internal {
        vm.prank(resolver);
        adjudicator.resolve(address(market), outcome, keccak256(abi.encode(outcome)));
    }

    function test_LastCountedVetoLocksTheMarketForEveryGuardian() public {
        TruthMarket market = _market();
        assertEq(adjudicator.GUARDIAN_VETO_CAP(), 3);
        for (uint256 i; i < adjudicator.GUARDIAN_VETO_CAP(); ++i) {
            _propose(market, 1);
            vm.prank(guardian);
            adjudicator.dispute(address(market));
            assertEq(adjudicator.guardianVetoCount(address(market), guardian), i + 1);
            assertFalse(market.isTradingOpen(), "a veto leaves trading closed");
        }
        assertTrue(adjudicator.resolutionLocked(address(market)));
        assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.LIVE));
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionVetoLocked.selector);
        adjudicator.resolve(address(market), 1, keccak256("fourth"));
        assertEq(adjudicator.guardianVetoCount(address(market), other), 0);
        assertFalse(market.isSettled());
    }

    function test_CappedGuardianCannotForceTimeoutTheNextProposalSettles() public {
        TruthMarket market = _market();
        for (uint256 i; i < adjudicator.GUARDIAN_VETO_CAP(); ++i) {
            _propose(market, 0);
            vm.prank(guardian);
            adjudicator.dispute(address(market));
        }
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionVetoLocked.selector);
        adjudicator.resolve(address(market), 1, keccak256("wrong"));
        vm.warp(uint256(deadline) + 7 days);
        market.invalidate();
        assertEq(market.winningOutcome(), 2);
        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
        assertTrue(market.isSettled());
    }

    function test_CapIsPerMarket() public {
        TruthMarket first = _market();
        TruthMarket second = _market();
        for (uint256 i; i < adjudicator.GUARDIAN_VETO_CAP(); ++i) {
            _propose(first, 1);
            vm.prank(guardian);
            adjudicator.dispute(address(first));
        }
        assertTrue(adjudicator.resolutionLocked(address(first)));
        _propose(second, 0);
        vm.prank(guardian);
        adjudicator.dispute(address(second));
        assertEq(adjudicator.guardianVetoCount(address(second), guardian), 1);
        assertFalse(adjudicator.resolutionLocked(address(second)));
        assertTrue(second.isLive());
        vm.prank(resolver);
        adjudicator.resolve(address(second), 1, keccak256("still open"));
        assertEq(uint8(second.state()), uint8(TruthMarket.MarketState.RESOLVING));
    }

    /// Repeated vetoes before the proof revert, spend nothing, and leave the
    /// resolver free to replace the proposal. An attested proposal can still
    /// be vetoed, `attest` restarts the full window, and the third veto locks.
    function test_UnattestedDisputesCannotStallAndAttestedVetoesStillCount() public {
        CapProofAdjudicator proof = new CapProofAdjudicator(address(this));
        proof.approveGuardian(guardian);
        proof.approveResolver(resolver);
        proof.setResolutionRecipient(address(0xFEED));
        proof.setEarlyResolution(true);
        proof.freezeProfile();
        bytes memory args = abi.encodePacked(
            keccak256("proof cap"),
            uint64(block.timestamp),
            deadline,
            address(proof),
            address(this),
            address(this),
            uint64(7 days),
            keccak256("proof terms")
        );
        TruthMarket market =
            TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
        proof.configureMarket(address(market), abi.encode(resolver, deadline, bytes("")));
        bytes memory unattested = abi.encodeWithSelector(
            IAdjudicator.InvalidPhase.selector,
            proof.PHASE_ATTESTED(),
            proof.PHASE_RESOLVED()
        );

        for (uint256 i; i < 5; ++i) {
            vm.prank(resolver);
            proof.resolve(address(market), 1, keccak256("unattested"));
            vm.prank(guardian);
            vm.expectRevert(unattested);
            proof.dispute(address(market));
            assertEq(proof.guardianVetoCount(address(market), guardian), 0);
            assertFalse(proof.resolutionLocked(address(market)));
            assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.RESOLVING));
        }

        vm.prank(resolver);
        proof.resolve(address(market), 0, keccak256("replacement"));
        proof.attest(address(market), "");
        assertEq(
            proof.getMarketState(address(market)).vetoEndsAt,
            uint64(block.timestamp) + uint64(proof.vetoPeriod())
        );
        vm.prank(guardian);
        proof.dispute(address(market));
        assertEq(proof.guardianVetoCount(address(market), guardian), 1);
        assertFalse(proof.resolutionLocked(address(market)));
        assertTrue(market.isLive(), "an attested veto still returns the market");

        for (uint256 i = 1; i < proof.GUARDIAN_VETO_CAP(); ++i) {
            vm.prank(resolver);
            proof.resolve(address(market), 0, keccak256("attested"));
            proof.attest(address(market), "");
            assertEq(
                proof.getMarketState(address(market)).vetoEndsAt,
                uint64(block.timestamp) + uint64(proof.vetoPeriod())
            );
            vm.prank(guardian);
            proof.dispute(address(market));
            assertEq(proof.guardianVetoCount(address(market), guardian), i + 1);
        }
        assertTrue(proof.resolutionLocked(address(market)));
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionVetoLocked.selector);
        proof.resolve(address(market), 1, keccak256("after lock"));
    }
}

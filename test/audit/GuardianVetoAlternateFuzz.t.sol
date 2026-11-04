// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";

/// @notice Attestation-required profile with an empty proof. Every counted
///         veto in this file is preceded by `resolve` and `attest`.
contract AlternateVetoAdjudicator is AdjudicatorBase {
    constructor(address factory) AdjudicatorBase(msg.sender, factory, 1 hours) {}

    function _requiresAttestation() internal pure override returns (bool) {
        return true;
    }

    function _verifyAttestation(address, bytes calldata) internal pure override {}
}

/// @notice Two to four guardians veto one market in a fuzzed order, with
///         resolve/attest between vetoes.
/// @dev `guardianVetoCount` never exceeds `GUARDIAN_VETO_CAP` (3). The lock
///      flips on the veto that stores 3 (`AdjudicatorBase.sol` 302-311).
///      A fourth `dispute` does not reach `GuardianVetoCapReached`
///      (`AdjudicatorBase.sol` 303). The veto that stores 3 also sets
///      `PHASE_DISPUTED` (`AdjudicatorBase.sol` 314) and `resolutionLocked`,
///      and `resolve` then reverts `ResolutionVetoLocked`
///      (`AdjudicatorBase.sol` 168). The next `dispute` fails the phase check
///      (`AdjudicatorBase.sol` 295-300) before the cap check. The market ends
///      as timeout INVALID.
contract GuardianVetoAlternateFuzzTest is Test {
    AlternateVetoAdjudicator internal adjudicator;
    TruthMarket internal market;
    address internal resolver = address(0xA11CE);
    address[4] internal guardians;
    uint64 internal deadline;
    uint64 internal constant BUFFER = 7 days;

    function setUp() public {
        guardians[0] = address(0x600D);
        guardians[1] = address(0x600E);
        guardians[2] = address(0x600F);
        guardians[3] = address(0x6010);
        TruthMarket implementation = new TruthMarket();
        adjudicator = new AlternateVetoAdjudicator(address(this));
        for (uint256 i; i < guardians.length; ++i) {
            adjudicator.approveGuardian(guardians[i]);
        }
        adjudicator.approveResolver(resolver);
        adjudicator.setResolutionRecipient(address(0xFEED));
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        deadline = uint64(block.timestamp + 30 days);
        bytes memory args = abi.encodePacked(
            keccak256("alternate veto"),
            uint64(block.timestamp),
            deadline,
            address(adjudicator),
            address(this),
            address(this),
            BUFFER,
            keccak256("alternate veto terms")
        );
        market = TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
        adjudicator.configureMarket(
            address(market), abi.encode(resolver, deadline, bytes(""))
        );
        assertEq(adjudicator.GUARDIAN_VETO_CAP(), 3);
    }

    function _resolveAndAttest() internal {
        vm.prank(resolver);
        adjudicator.resolve(address(market), 1, keccak256("reading"));
        adjudicator.attest(address(market), "");
        assertEq(adjudicator.getPhase(address(market)), adjudicator.PHASE_ATTESTED());
    }

    function _assertCounts(uint256 n) internal view returns (bool lockedByCap) {
        for (uint256 i; i < guardians.length; ++i) {
            uint256 count = adjudicator.guardianVetoCount(address(market), guardians[i]);
            assertLe(count, adjudicator.GUARDIAN_VETO_CAP(), "count above the cap");
            if (i < n && count == adjudicator.GUARDIAN_VETO_CAP()) lockedByCap = true;
            if (i >= n) assertEq(count, 0, "idle guardian counted a veto");
        }
        assertEq(adjudicator.resolutionLocked(address(market)), lockedByCap);
    }

    function _cappedGuardian(uint256 n) internal view returns (address capped) {
        for (uint256 i; i < n; ++i) {
            if (
                adjudicator.guardianVetoCount(address(market), guardians[i])
                    == adjudicator.GUARDIAN_VETO_CAP()
            ) return guardians[i];
        }
    }

    /// @dev Drive vetoes in `choices` order until the pigeonhole forces a lock,
    ///      then show the fourth attempt and the timeout.
    function testFuzz_guardiansAlternateUntilOneLocks(uint8 nRaw, uint256 choices)
        public
    {
        uint256 n = bound(uint256(nRaw), 2, 4);
        uint256 maxSteps = 2 * n + 1;
        bool locked;
        for (uint256 step; step < maxSteps; ++step) {
            uint256 g = uint256(uint8(choices >> ((step % 32) * 8))) % n;
            _resolveAndAttest();
            uint256 before = adjudicator.guardianVetoCount(address(market), guardians[g]);
            assertLt(before, adjudicator.GUARDIAN_VETO_CAP());
            vm.prank(guardians[g]);
            adjudicator.dispute(address(market));
            assertEq(
                adjudicator.guardianVetoCount(address(market), guardians[g]), before + 1
            );
            assertEq(uint8(market.state()), uint8(TruthMarket.MarketState.LIVE));
            assertFalse(market.isSettled());
            locked = _assertCounts(n);
            if (locked) break;
        }
        assertTrue(locked, "some guardian reached the cap");

        address capped = _cappedGuardian(n);
        assertTrue(capped != address(0));
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionVetoLocked.selector);
        adjudicator.resolve(address(market), 1, keccak256("after-lock"));

        // Fourth dispute. Phase is DISPUTED, so this reverts before line 303.
        // The phase getters are external calls and must run before `prank`.
        bytes memory disputed = abi.encodeWithSelector(
            IAdjudicator.InvalidPhase.selector,
            adjudicator.PHASE_ATTESTED(),
            adjudicator.PHASE_DISPUTED()
        );
        vm.prank(capped);
        vm.expectRevert(disputed);
        adjudicator.dispute(address(market));
        assertEq(
            adjudicator.guardianVetoCount(address(market), capped),
            adjudicator.GUARDIAN_VETO_CAP()
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IAdjudicator.InvalidPhase.selector,
                adjudicator.PHASE_ATTESTED(),
                adjudicator.PHASE_DISPUTED()
            )
        );
        adjudicator.settle(address(market));

        vm.warp(uint256(deadline) + BUFFER);
        market.invalidate();
        assertEq(market.winningOutcome(), 2);
        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
        assertTrue(market.isSettled());
    }
}

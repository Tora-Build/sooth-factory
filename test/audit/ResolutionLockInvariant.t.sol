// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";

/// @notice A market with `resolutionLocked` set stays unsettled until timeout
///         INVALID. Proposals and settlement after the lock are refused.
contract ResolutionLockHandler is Test {
    ManualAdjudicator public adjudicator;
    TruthMarket public market;
    address internal constant GUARDIAN = address(0x600D);
    address internal constant RESOLVER = address(0xA11CE);
    uint64 public deadline;

    function setUp() public {
        TruthMarket implementation = new TruthMarket();
        adjudicator = new ManualAdjudicator(address(this), address(this), 1 hours);
        adjudicator.approveGuardian(GUARDIAN);
        adjudicator.approveResolver(RESOLVER);
        adjudicator.setResolutionRecipient(address(0xFEED));
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        deadline = uint64(block.timestamp + 30 days);
        bytes memory args = abi.encodePacked(
            keccak256("lock invariant"),
            uint64(block.timestamp),
            deadline,
            address(adjudicator),
            address(this),
            address(this),
            uint64(7 days),
            keccak256("lock terms")
        );
        market = TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
        adjudicator.configureMarket(
            address(market), abi.encode(RESOLVER, deadline, bytes(""))
        );
    }

    function proposeAndVeto(uint8 outcome) external {
        if (market.isSettled() || adjudicator.resolutionLocked(address(market))) return;
        if (market.state() != TruthMarket.MarketState.LIVE) return;
        uint256 cutoff = uint256(deadline) + market.invalidationBuffer();
        if (block.timestamp + adjudicator.vetoPeriod() >= cutoff) return;
        vm.prank(RESOLVER);
        adjudicator.resolve(address(market), outcome % 3, keccak256("lock"));
        vm.prank(GUARDIAN);
        adjudicator.dispute(address(market));
    }

    function tryLockedResolve() external {
        if (!adjudicator.resolutionLocked(address(market))) return;
        vm.prank(RESOLVER);
        try adjudicator.resolve(address(market), 1, keccak256("after lock")) {
            assertTrue(false, "locked market accepted a proposal");
        } catch (bytes memory data) {
            assertEq(bytes4(data), AdjudicatorBase.ResolutionVetoLocked.selector);
        }
        assertFalse(market.isSettled());
    }

    function tryLockedSettle() external {
        if (!adjudicator.resolutionLocked(address(market))) return;
        try adjudicator.settle(address(market)) {
            assertTrue(false, "locked market settled an outcome");
        } catch {}
        assertFalse(market.isSettled());
    }

    function warp(uint16 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 3 days));
    }

    function invalidateIfDue() external {
        if (market.isSettled()) return;
        if (block.timestamp < uint256(deadline) + market.invalidationBuffer()) return;
        market.invalidate();
        if (!adjudicator.resolutionLocked(address(market))) return;
        assertEq(market.winningOutcome(), 2);
        assertEq(
            uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
    }

    function checkLockedEndsInvalid() external view {
        if (!adjudicator.resolutionLocked(address(market))) return;
        if (market.isSettled()) {
            assertEq(market.winningOutcome(), 2);
            assertEq(
                uint8(market.settlementKind()),
                uint8(ITruthMarket.SettlementKind.INVALIDATED)
            );
        } else {
            assertEq(
                uint8(market.settlementKind()), uint8(ITruthMarket.SettlementKind.UNSET)
            );
        }
    }
}

contract ResolutionLockInvariantTest is Test {
    ResolutionLockHandler internal h;

    function setUp() public {
        h = new ResolutionLockHandler();
        h.setUp();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = h.proposeAndVeto.selector;
        selectors[1] = h.proposeAndVeto.selector;
        selectors[2] = h.tryLockedResolve.selector;
        selectors[3] = h.tryLockedSettle.selector;
        selectors[4] = h.warp.selector;
        selectors[5] = h.invalidateIfDue.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_lockedMarketEndsOnlyAsTimeoutInvalid() public view {
        h.checkLockedEndsInvalid();
    }
}

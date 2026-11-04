// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";

/// @notice A finite-deadline market is settled by the cutoff. Resolver and
///         guardian actions are arbitrary. Past `deadline + buffer` the handler
///         invalidates whatever is still open.
contract FiniteDeadlineHandler is Test {
    ManualAdjudicator public adjudicator;
    TruthMarket public market;
    uint64 public deadline;
    uint64 public constant BUFFER = 1 days;
    address internal constant GUARDIAN = address(0x600D);
    address internal constant RESOLVER = address(0xA11CE);

    function setUp() public {
        TruthMarket implementation = new TruthMarket();
        adjudicator = new ManualAdjudicator(address(this), address(this), 1 hours);
        adjudicator.approveGuardian(GUARDIAN);
        adjudicator.approveResolver(RESOLVER);
        adjudicator.setResolutionRecipient(address(0xFEED));
        adjudicator.setEarlyResolution(true);
        adjudicator.freezeProfile();
        deadline = uint64(block.timestamp + 2 days);
        bytes memory args = abi.encodePacked(
            keccak256("finite deadline"),
            uint64(block.timestamp),
            deadline,
            address(adjudicator),
            address(this),
            address(this),
            BUFFER,
            keccak256("finite terms")
        );
        market = TruthMarket(Clones.cloneWithImmutableArgs(address(implementation), args));
        adjudicator.configureMarket(
            address(market), abi.encode(RESOLVER, deadline, bytes(""))
        );
    }

    function propose(uint8 outcome) external {
        if (market.isSettled() || adjudicator.resolutionLocked(address(market))) return;
        if (market.state() != TruthMarket.MarketState.LIVE) return;
        uint256 cutoff = uint256(deadline) + BUFFER;
        if (block.timestamp + adjudicator.vetoPeriod() >= cutoff) return;
        vm.prank(RESOLVER);
        adjudicator.resolve(address(market), outcome % 3, keccak256("finite"));
    }

    function veto() external {
        if (market.isSettled() || !market.isResolving()) return;
        if (block.timestamp >= uint256(deadline) + BUFFER) return;
        IAdjudicator.MarketState memory st = adjudicator.getMarketState(address(market));
        if (block.timestamp >= st.vetoEndsAt) return;
        if (
            adjudicator.guardianVetoCount(address(market), GUARDIAN)
                >= adjudicator.GUARDIAN_VETO_CAP()
        ) return;
        vm.prank(GUARDIAN);
        adjudicator.dispute(address(market));
    }

    function settle() external {
        if (!adjudicator.canSettle(address(market))) return;
        adjudicator.settle(address(market));
    }

    function warp(uint32 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 12 hours));
        if (market.isSettled()) return;
        if (block.timestamp < uint256(deadline) + BUFFER) return;
        market.invalidate();
    }

    function checkFinalized() external view {
        bool due = block.timestamp >= uint256(deadline) + BUFFER;
        if (adjudicator.resolutionLocked(address(market)) && market.isSettled()) {
            assertEq(market.winningOutcome(), 2);
            assertEq(
                uint8(market.settlementKind()),
                uint8(ITruthMarket.SettlementKind.INVALIDATED)
            );
        }
        if (!due) {
            if (market.isSettled()) {
                assertEq(
                    uint8(market.settlementKind()),
                    uint8(ITruthMarket.SettlementKind.ADJUDICATED)
                );
            }
            return;
        }
        assertTrue(market.isSettled(), "finite market unsettled after the cutoff");
        uint8 kind = uint8(market.settlementKind());
        assertTrue(
            kind == uint8(ITruthMarket.SettlementKind.ADJUDICATED)
                || kind == uint8(ITruthMarket.SettlementKind.INVALIDATED)
        );
        if (kind == uint8(ITruthMarket.SettlementKind.INVALIDATED)) {
            assertEq(market.winningOutcome(), 2);
        } else {
            assertLe(market.winningOutcome(), 2);
        }
    }
}

contract FiniteDeadlineInvariantTest is Test {
    FiniteDeadlineHandler internal h;

    function setUp() public {
        h = new FiniteDeadlineHandler();
        h.setUp();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = h.propose.selector;
        selectors[1] = h.veto.selector;
        selectors[2] = h.settle.selector;
        selectors[3] = h.warp.selector;
        selectors[4] = h.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_finiteDeadlineFinalizesByCutoff() public view {
        h.checkFinalized();
    }
}

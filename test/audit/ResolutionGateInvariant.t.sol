// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuditHandler} from "./EngineInvariant.t.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// @notice O-1 as a state machine. The profile allows early resolution, so a
///         proposal and a guardian veto can both land before the deadline.
/// @dev The `raw*` actions do not read the trading gate. They call the engines
///      and record what the engines allow. The first proposal closes trading
///      for the rest of the market, including after a veto.
contract GateHandler is AuditHandler {
    uint256 public proposals;
    uint256 public vetoes;
    uint256 public tradesBefore;
    uint256 public refusedAfter;
    bytes32 public ammAtProposal;
    uint256 public fillsAtProposal;
    uint256 public collateralAtProposal;

    function ammState() public view returns (bytes32) {
        (uint256 qYes, uint256 qNo, uint256 price) = amm.getMarketState(market);
        return keccak256(abi.encode(qYes, qNo, price, amm.getLiquidity(market)));
    }

    function proposeEarly(uint8 outcome) external {
        TruthMarket truth = TruthMarket(market);
        if (truth.state() != TruthMarket.MarketState.LIVE) return;
        if (adjudicator.resolutionLocked(market)) return;
        uint256 cutoff = uint256(truth.deadline()) + truth.invalidationBuffer();
        if (block.timestamp + adjudicator.vetoPeriod() >= cutoff) return;
        ammAtProposal = ammState();
        fillsAtProposal = orderEngine.fillCount();
        collateralAtProposal = amm.getMarketCollateral(market);
        vm.prank(resolver);
        adjudicator.resolve(market, outcome % 3, keccak256("gate"));
        proposedAt = block.timestamp;
        ++proposals;
    }

    function vetoNow() external {
        TruthMarket truth = TruthMarket(market);
        if (!truth.isResolving() && !truth.isAttested()) return;
        if (block.timestamp >= proposedAt + adjudicator.vetoPeriod()) return;
        if (
            adjudicator.guardianVetoCount(market, GUARDIAN)
                >= adjudicator.GUARDIAN_VETO_CAP()
        ) return;
        vm.prank(GUARDIAN);
        adjudicator.dispute(market);
        ++vetoes;
    }

    function _allowed(string memory what) internal {
        TruthMarket truth = TruthMarket(market);
        assertTrue(
            truth.state() == TruthMarket.MarketState.LIVE && !truth.resolutionAttempted(),
            what
        );
        ++tradesBefore;
    }

    function rawAmmBuy(uint8 who, uint8 outcome, uint96 raw) external {
        uint256 shares = bound(uint256(raw), 1e15, 2e18);
        vm.prank(_actor(who));
        try amm.tradePositions(market, outcome % 2, int256(shares), type(uint256).max) {
            _allowed("AMM buy after a proposal");
        } catch {
            if (proposedAt != 0) ++refusedAfter;
        }
    }

    function rawAmmSell(uint8 who, uint8 outcome, uint96 raw) external {
        address actor = _actor(who);
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        uint256 held = outcome % 2 == 1 ? yes : no;
        if (held < 1e15) return;
        uint256 shares = bound(uint256(raw), 1e15, held);
        vm.prank(actor);
        try amm.tradePositions(market, outcome % 2, -int256(shares), 0) {
            _allowed("AMM sell after a proposal");
        } catch {
            if (proposedAt != 0) ++refusedAfter;
        }
    }

    function rawLiquidity(uint8 who, uint96 raw) external {
        uint256 db = bound(uint256(raw), 1e17, 2e18);
        (bool quoted, uint256 input, uint256 units, uint256 price, bytes32 stateHash) =
            _quoteLiquidity(db);
        if (!quoted) return;
        uint64 deadline = TruthMarket(market).deadline();
        vm.prank(_actor(who));
        try amm.increaseLiquidity(
            market,
            db,
            IAMMEngine.LiquidityLimits(input, units, price, price, deadline, stateHash)
        ) {
            _allowed("liquidity added after a proposal");
        } catch {
            if (proposedAt != 0) ++refusedAfter;
        }
    }

    function rawBookOrder(uint8 who, bool sell_, bool yes, uint16 tickSeed, uint96 raw)
        external
    {
        IOrderEngine.OrderParams memory p;
        p.outcome = yes ? 1 : 0;
        p.action = sell_ ? 1 : 0;
        p.priceTick = uint16(bound(tickSeed, 100, 900));
        p.amount = uint128(_shares(raw));
        p.matchLimit = 16;
        p.validUntil = uint64(block.timestamp);
        p.rest = true;
        p.maxTokenIn = 1e15;
        vm.prank(_actor(who));
        try orderEngine.placeOrder(market, p) {
            _allowed("book order after a proposal");
        } catch {
            if (proposedAt != 0) ++refusedAfter;
        }
    }

    function rawSplit(uint8 who, uint96 raw) external {
        vm.prank(_actor(who));
        try orderEngine.split(market, _shares(raw), type(uint256).max - 1, _until()) {
            _allowed("split after a proposal");
        } catch {
            if (proposedAt != 0) ++refusedAfter;
        }
    }

    function checkGate() external view {
        TruthMarket truth = TruthMarket(market);
        TruthMarket.MarketState s = truth.state();
        if (s == TruthMarket.MarketState.LIVE) {
            if (proposals == 0) {
                assertFalse(truth.resolutionAttempted(), "no proposal has set the marker");
                return;
            }
            assertTrue(truth.resolutionAttempted(), "a proposal keeps the marker set");
            assertFalse(truth.isTradingOpen(), "trading open after a proposal");
            assertFalse(truth.isLiquidityOpen(), "liquidity open after a proposal");
            assertEq(
                orderEngine.fillCount(), fillsAtProposal, "book filled after a proposal"
            );
            assertEq(ammState(), ammAtProposal, "AMM state moved after a proposal");
            assertEq(
                amm.getMarketCollateral(market),
                collateralAtProposal,
                "AMM collateral moved after a proposal"
            );
            return;
        }
        if (
            s == TruthMarket.MarketState.RESOLVING
                || s == TruthMarket.MarketState.ATTESTED
        ) {
            assertTrue(truth.resolutionAttempted(), "an open proposal sets the marker");
            assertFalse(truth.isTradingOpen(), "trading open during a proposal");
            assertFalse(truth.isLiquidityOpen(), "liquidity open during a proposal");
            assertEq(
                orderEngine.fillCount(), fillsAtProposal, "book filled during a proposal"
            );
            assertEq(ammState(), ammAtProposal, "AMM state moved during a proposal");
            assertEq(
                amm.getMarketCollateral(market),
                collateralAtProposal,
                "AMM collateral moved during a proposal"
            );
            return;
        }
        assertFalse(truth.isTradingOpen(), "settlement stays closed");
        assertFalse(truth.isLiquidityOpen(), "settlement stays closed");
    }
}

contract ResolutionGateInvariantTest is Test {
    GateHandler internal h;

    function setUp() public {
        h = new GateHandler();
        h.setUp();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = h.rawAmmBuy.selector;
        selectors[1] = h.rawAmmSell.selector;
        selectors[2] = h.rawLiquidity.selector;
        selectors[3] = h.rawBookOrder.selector;
        selectors[4] = h.rawSplit.selector;
        selectors[5] = h.proposeEarly.selector;
        selectors[6] = h.vetoNow.selector;
        selectors[7] = h.vetoNow.selector;
        selectors[8] = h.settleMarket.selector;
        selectors[9] = h.warpSmall.selector;
        selectors[10] = h.cancelOrder.selector;
        selectors[11] = h.mergeShares.selector;
        selectors[12] = h.rawAmmBuy.selector;
        selectors[13] = h.rawBookOrder.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_firstProposalClosesTradingThroughVeto() public view {
        h.checkGate();
    }

    function afterInvariant() public {
        emit log_named_uint("proposals", h.proposals());
        emit log_named_uint("vetoes", h.vetoes());
        emit log_named_uint("trades before the proposal", h.tradesBefore());
        emit log_named_uint("refused after the proposal", h.refusedAfter());
    }
}

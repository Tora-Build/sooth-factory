// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LMSRMath} from "../reference/LMSRMath.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/**
 * @title AMM trade-pipeline reorder — executable spec
 * @notice Proves the pipeline `quote → effects → collect → deposit` against the
 *         REAL LMSRMath, and that the old order (fee side-effects before
 *         collection) pays the vault out of collateral custody — opening a
 *         mid-transaction window where any reentrant observer sees the engine
 *         below `collateral`. The new order funds the deposit from the
 *         buyer's just-collected tokens and never dips.
 *
 *         The protocol has exactly one AMM fee regime for the whole trading window:
 *           fee        = baseCost * AMM_FEE_BPS / 10_000
 *           capitalWad = fee * CAPITAL_BPS / 10_000   (grows b by capitalWad)
 *           revenueWad = fee - capitalWad             (pushed to the vault)
 *         There is no volume threshold, no fee transition and no callback.
 *
 *         Counter rules proven (the counter-rule spec):
 *           buy:  _marketCollateral += baseCost + capitalWad   (only)
 *           sell: _marketCollateral -= netProceeds + revenueWad;
 *         Engine solvency: balance == collateral at every boundary
 *         (18-dec token — exact; 6-dec truncation is covered by the rounding rules).
 */
contract TradePipelineReorderTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;

    MockUSDC internal east; // 18-dec instance token
    MiniVault internal vault;
    TradePipelinePrototype internal amm;

    address internal trader = address(0x7124);

    function setUp() public {
        east = new MockUSDC("EAST", "EAST");
        vault = new MiniVault();
        amm = new TradePipelinePrototype(east, vault);
        vault.init(address(amm));

        // Seed: b = 25 EAST, p = 0.5 (qYes = qNo = 0), deposit = b*ln2
        uint256 depositWad = uint256(LMSRMath.logSumExp(25e18, 0, 0));
        east.mint(address(amm), depositWad);
        amm.initMarket(25e18, depositWad);

        east.mint(trader, 10_000e18);
        vm.prank(trader);
        east.approve(address(amm), type(uint256).max);
    }

    // ============================================
    // Quote fidelity: quoted == realized, INCLUDING the fee-induced b change
    // ============================================

    function test_Quote_MatchesExecution_FirstTrade() public {
        (,, uint256 net, uint256 newPriceQuoted) = amm.quoteTrade(1, 10e18);

        vm.prank(trader);
        uint256 paid = amm.trade(1, 10e18, type(uint256).max);

        assertEq(paid, net, "quoted net != executed net");
        assertEq(amm.currentPrice(), newPriceQuoted, "quoted price != realized");
    }

    function test_Quote_IncludesFeeInducedB() public {
        // The price at STALE b must differ from the correctly quoted one, and
        // the correct one must be realized.
        (,,, uint256 quotedFresh) = amm.quoteTrade(1, 100e18);
        uint256 quotedStale = amm.quoteAtStaleB(1, 100e18);

        assertTrue(quotedFresh != quotedStale, "fee-induced b must move the quote");

        vm.prank(trader);
        amm.trade(1, 100e18, type(uint256).max);
        assertEq(amm.currentPrice(), quotedFresh, "realized == fresh quote");
        assertTrue(amm.currentPrice() != quotedStale, "realized != stale quote");
    }

    function test_Quote_MatchesExecution_AfterVolume() public {
        _bigBuy();
        (,, uint256 net, uint256 newPriceQuoted) = amm.quoteTrade(0, 25e18);

        vm.prank(trader);
        uint256 paid = amm.trade(0, 25e18, type(uint256).max);

        assertEq(paid, net);
        assertEq(amm.currentPrice(), newPriceQuoted);
    }

    // ============================================
    // Counter rules + engine solvency at every boundary
    // ============================================

    function test_CounterRules_Buy() public {
        uint256 coll0 = amm.marketCollateral();
        uint256 vault0 = east.balanceOf(address(vault));
        uint256 b0 = amm.b();

        (uint256 baseCost, uint256 fee,,) = amm.quoteTrade(1, 50e18);
        uint256 capitalWad = (fee * amm.CAPITAL_BPS()) / BPS;
        uint256 revenueWad = fee - capitalWad;

        vm.prank(trader);
        amm.trade(1, 50e18, type(uint256).max);

        assertEq(
            amm.marketCollateral(),
            coll0 + baseCost + capitalWad,
            "buy: collateral += baseCost + capitalShare only"
        );
        assertEq(amm.b() - b0, capitalWad, "b grows by exactly capitalWad");
        assertEq(
            east.balanceOf(address(vault)) - vault0,
            revenueWad,
            "vault received exactly the revenue share"
        );
        _assertEngineSolvent();
    }

    function test_CounterRules_Sell() public {
        vm.prank(trader);
        amm.trade(1, 50e18, type(uint256).max); // acquire shares

        uint256 coll0 = amm.marketCollateral();
        uint256 sellerBefore = east.balanceOf(trader);

        (uint256 baseCost, uint256 fee, uint256 netProceeds,) = amm.quoteTrade(1, -50e18);
        uint256 capitalWad = (fee * amm.CAPITAL_BPS()) / BPS;
        uint256 revenueWad = fee - capitalWad;
        assertEq(netProceeds, baseCost - fee);

        vm.prank(trader);
        amm.trade(1, -50e18, 0);

        assertEq(
            amm.marketCollateral(),
            coll0 - (netProceeds + revenueWad),
            "sell: collateral -= netProceeds + revenueShare"
        );
        assertEq(
            east.balanceOf(trader) - sellerBefore,
            netProceeds,
            "sell: proceeds paid immediately"
        );
        _assertEngineSolvent();
    }

    /// @dev The fee rate is a pinned constant of the market: volume never
    ///      changes it and no external notification fires.
    function test_FeeRate_IndependentOfVolume() public {
        (uint256 base1, uint256 fee1,,) = amm.quoteTrade(1, 10e18);
        assertEq(fee1, (base1 * amm.AMM_FEE_BPS()) / BPS);

        _bigBuy();

        (uint256 base2, uint256 fee2,,) = amm.quoteTrade(1, 10e18);
        assertEq(fee2, (base2 * amm.AMM_FEE_BPS()) / BPS, "rate unchanged after volume");
        assertEq(vault.notifications(), 0, "no lifecycle callback ever fires");
    }

    // ============================================
    // Ordering: collect BEFORE deposit — the old order is impossible
    // ============================================

    function test_OldOrder_OpensMidTxInsolvencyWindow() public {
        // OLD order: the vault push happens BEFORE the buyer's tokens are
        // collected, so the engine pays the vault OUT OF COLLATERAL CUSTODY.
        // The vault (standing in for ANY reentrant callee) observes the engine
        // below its liabilities mid-transaction.
        vm.prank(trader);
        amm.tradeOldOrderForProof(1, 50e18);
        assertTrue(
            vault.sawEngineInsolvent(),
            "old order must expose a mid-tx dip below collateral"
        );
    }

    function test_NewOrder_NoMidTxInsolvencyWindow() public {
        // NEW order: collect first — the deposit is funded by the buyer's
        // just-collected tokens; no observer can ever see the engine unbacked.
        vm.prank(trader);
        amm.trade(1, 50e18, type(uint256).max);
        assertFalse(vault.sawEngineInsolvent(), "new order must never dip");
    }

    function test_NewOrder_SolventAtEveryStep() public {
        vm.prank(trader);
        amm.trade(1, 50e18, type(uint256).max);
        _assertEngineSolvent();
    }

    // ============================================
    // Fuzz: quote==execution + solvency across random mixed sequences
    // ============================================

    function testFuzz_QuoteAndSolvency_MixedSequence(uint256 a, uint256 b_, uint256 c)
        public
    {
        a = bound(a, 1e18, 200e18);
        b_ = bound(b_, 1e18, 200e18);
        c = bound(c, 1e18, a); // sell part of the first buy

        (,, uint256 net1, uint256 p1) = amm.quoteTrade(1, int256(a));
        vm.prank(trader);
        assertEq(amm.trade(1, int256(a), type(uint256).max), net1);
        assertEq(amm.currentPrice(), p1);
        _assertEngineSolvent();

        (,, uint256 net2, uint256 p2) = amm.quoteTrade(0, int256(b_));
        vm.prank(trader);
        assertEq(amm.trade(0, int256(b_), type(uint256).max), net2);
        assertEq(amm.currentPrice(), p2);
        _assertEngineSolvent();

        (,, uint256 net3, uint256 p3) = amm.quoteTrade(1, -int256(c));
        vm.prank(trader);
        assertEq(amm.trade(1, -int256(c), 0), net3);
        assertEq(amm.currentPrice(), p3);
        _assertEngineSolvent();
    }

    // ============================================
    // Helpers
    // ============================================

    function _bigBuy() internal {
        vm.prank(trader);
        amm.trade(1, 400e18, type(uint256).max);
    }

    function _assertEngineSolvent() internal view {
        assertEq(
            east.balanceOf(address(amm)),
            amm.marketCollateral(),
            "engine balance must equal collateral exactly (18-dec)"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Reference implementations
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Mini-AMM over the REAL LMSRMath implementing the reordered pipeline.
///      Single market, 18-dec token, one fee regime: AMM_FEE_BPS of base cost,
///      CAPITAL_BPS of which is added to b raw (faithful to AMMEngine) and the
///      rest pushed to the vault as revenue.
contract TradePipelinePrototype {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 10_000;
    // Test-only fixture rates; the relationships, not the numbers, are asserted.
    uint256 public constant AMM_FEE_BPS = 100;
    uint256 public constant CAPITAL_BPS = 5000;

    IERC20 public immutable token;
    MiniVault public immutable vault;

    uint256 public b;
    uint256 public qYes;
    uint256 public qNo;
    uint256 public marketCollateral; // WAD == native (18-dec)
    mapping(address => mapping(uint8 => uint256)) public shares;

    constructor(IERC20 _token, MiniVault _vault) {
        token = _token;
        vault = _vault;
    }

    function initMarket(uint256 _b, uint256 depositWad) external {
        b = _b;
        marketCollateral = depositWad;
    }

    function currentPrice() public view returns (uint256) {
        return LMSRMath.calculateProbability(b, qYes, qNo);
    }

    // ── 1. QUOTE (view; newPrice includes the fee-induced b change) ─────────

    function quoteTrade(uint8 outcome, int256 deltaShares)
        public
        view
        returns (uint256 baseCost, uint256 fee, uint256 netAmount, uint256 newPrice)
    {
        (baseCost, fee, netAmount, newPrice,) = _quote(outcome, deltaShares);
    }

    /// @dev A stale-b quote, kept for the comparison test only.
    function quoteAtStaleB(uint8 outcome, int256 deltaShares)
        external
        view
        returns (uint256 stalePrice)
    {
        (uint256 nY, uint256 nN) = _newQuantities(outcome, deltaShares);
        stalePrice = LMSRMath.calculateProbability(b, nY, nN); // stale b
    }

    function _quote(uint8 outcome, int256 deltaShares)
        internal
        view
        returns (
            uint256 baseCost,
            uint256 fee,
            uint256 netAmount,
            uint256 newPrice,
            uint256 capitalWad
        )
    {
        bool isBuy = deltaShares > 0;
        (uint256 nY, uint256 nN) = _newQuantities(outcome, deltaShares);

        baseCost = isBuy
            ? LMSRMath.calculateCost(b, qYes, qNo, nY, nN)
            : LMSRMath.calculateCost(b, nY, nN, qYes, qNo);

        fee = (baseCost * AMM_FEE_BPS) / BPS;
        netAmount = isBuy ? baseCost + fee : baseCost - fee;
        capitalWad = (fee * CAPITAL_BPS) / BPS;

        // The corrected quote: price at (b + capitalWad), new quantities
        newPrice = LMSRMath.calculateProbability(b + capitalWad, nY, nN);
    }

    // ── The reordered pipeline: quote → effects → collect → deposit ─────────

    function trade(uint8 outcome, int256 deltaShares, uint256 limit)
        external
        returns (uint256 actual)
    {
        // 1. QUOTE (pure view — no state has moved yet)
        (uint256 baseCost, uint256 fee, uint256 netAmount,, uint256 capitalWad) =
            _quote(outcome, deltaShares);
        bool isBuy = deltaShares > 0;
        uint256 absDelta = isBuy ? uint256(deltaShares) : uint256(-deltaShares);
        uint256 revenueWad = fee - capitalWad;

        // 2. EFFECTS (all state writes; still no external calls)
        (qYes, qNo) = _newQuantities(outcome, deltaShares);
        b += capitalWad;
        if (isBuy) {
            require(netAmount <= limit, "cost too high");
            marketCollateral += baseCost + capitalWad; // the corrected rule
            shares[msg.sender][outcome] += absDelta;
        } else {
            require(netAmount >= limit, "proceeds too low");
            require(shares[msg.sender][outcome] >= absDelta, "no shares");
            shares[msg.sender][outcome] -= absDelta;
            marketCollateral -= netAmount + revenueWad; // the corrected rule
        }

        // 3. COLLECT (buy: pull the buyer's tokens — BEFORE any outbound push)
        if (isBuy) {
            token.safeTransferFrom(msg.sender, address(this), netAmount);
        }

        // 4. DEPOSIT (push revenue share to the vault, snapshot pattern)
        if (revenueWad > 0) {
            uint256 pre = token.balanceOf(address(vault));
            token.safeTransfer(address(vault), revenueWad);
            vault.notifyDeposit(revenueWad, pre);
        }

        if (!isBuy && netAmount > 0) token.safeTransfer(msg.sender, netAmount);
        actual = netAmount;
    }

    /// @dev The OLD order (deposit before collect) — exists only to prove the
    ///      mid-tx insolvency window: effects + vault push happen before the
    ///      buyer has paid, so the push is funded out of collateral custody and
    ///      the vault's probe sees balance < collateral.
    function tradeOldOrderForProof(uint8 outcome, int256 deltaShares)
        external
        returns (uint256 actual)
    {
        (uint256 baseCost, uint256 fee, uint256 netAmount,, uint256 capitalWad) =
            _quote(outcome, deltaShares);
        uint256 revenueWad = fee - capitalWad;
        bool isBuy = deltaShares > 0;
        uint256 absDelta = isBuy ? uint256(deltaShares) : uint256(-deltaShares);

        // effects first, THEN the early push — before collection
        (qYes, qNo) = _newQuantities(outcome, deltaShares);
        b += capitalWad;
        marketCollateral += baseCost + capitalWad;
        shares[msg.sender][outcome] += absDelta;

        uint256 pre = token.balanceOf(address(vault));
        token.safeTransfer(address(vault), revenueWad);
        vault.notifyDeposit(revenueWad, pre); // probe fires HERE, pre-collect

        token.safeTransferFrom(msg.sender, address(this), netAmount);
        actual = netAmount;
    }

    function _newQuantities(uint8 outcome, int256 deltaShares)
        internal
        view
        returns (uint256 nY, uint256 nN)
    {
        bool isBuy = deltaShares > 0;
        uint256 absDelta = isBuy ? uint256(deltaShares) : uint256(-deltaShares);
        if (outcome == 1) {
            nY = isBuy ? qYes + absDelta : qYes - absDelta;
            nN = qNo;
        } else {
            nY = qYes;
            nN = isBuy ? qNo + absDelta : qNo - absDelta;
        }
    }
}

/// @dev Minimal vault: balance-delta deposits plus a reentrancy-observer probe.
///      It has no lifecycle state; `notifications` counts any callback other
///      than a deposit and must stay zero.
contract MiniVault {
    address public amm;
    uint256 public totalLiabilities;
    uint256 public notifications;
    bool public sawEngineInsolvent;

    function init(address _amm) external {
        require(amm == address(0));
        amm = _amm;
    }

    function notifyDeposit(uint256 expected, uint256 preBalance) external {
        require(msg.sender == amm, "not engine");
        TradePipelinePrototype engine = TradePipelinePrototype(amm);
        uint256 delta = engine.token().balanceOf(address(this)) - preBalance;
        totalLiabilities += delta < expected ? delta : expected;

        // Reentrancy-observer probe: is the engine backed at this moment?
        if (engine.token().balanceOf(amm) < engine.marketCollateral()) {
            sawEngineInsolvent = true;
        }
    }

    fallback() external {
        notifications++;
    }
}

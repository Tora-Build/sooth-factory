// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/**
 * @title Vault deposit attribution — executable spec
 * @notice Proves the push-then-notify deposit primitive with a PRE-TRANSFER
 *         snapshot: credited = min(balanceNow − preBalance, expected).
 *
 *         The v4 bug this design fixes: crediting "delta since the vault's last
 *         recorded balance" lets a donation that arrived after the previous vault
 *         operation mask a transfer-tax shortfall (10 donated + 90 delivered of
 *         100 expected → observed delta 100 → full credit, no flag — both
 *         guarantees fail at once). With the engine snapshotting the vault's
 *         balance immediately before ITS OWN push, prior donations are excluded:
 *         excess is attributable surplus, shortfall is recorded truth + a flag.
 *
 *         `DepositVaultPrototype` + `MockEngine.collectAndDeposit` are the
 *         reference implementations M2 (vault side) and M3/M4 (engine side) lift.
 */
contract VaultDepositAttributionTest is Test {
    DepositVaultPrototype internal vault;
    MockEngine internal engine;
    MockUSDC internal usdc;
    FeeOnTransferToken internal taxToken;

    address internal treasury = address(0x7EA5);
    address internal market = address(0xAAA1);
    address internal donor = address(0xD0);

    function setUp() public {
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        taxToken = new FeeOnTransferToken(1000); // 10% tax on transfer
        vault = new DepositVaultPrototype(treasury);
        engine = new MockEngine(vault);
        vault.setEngine(address(engine));

        usdc.mint(address(engine), 1_000_000e6);
        taxToken.mint(address(engine), 1_000_000e6);
        usdc.mint(donor, 1_000_000e6);
    }

    // ============================================
    // Base case
    // ============================================

    function test_CleanDeposit_CreditsExpected() public {
        engine.collectAndDeposit(market, address(usdc), 100e6);

        assertEq(vault.credited(market, address(usdc)), 100e6);
        assertEq(vault.totalLiabilities(address(usdc)), 100e6);
        assertEq(vault.surplus(address(usdc)), 0);
        assertFalse(vault.lastDepositFlagged());
    }

    // ============================================
    // The v4 regression: prior donation must NOT mask a tax shortfall
    // ============================================

    function test_PriorDonation_DoesNotMaskShortfall() public {
        // A donor sends 10 tax-tokens directly to the vault (earlier tx).
        taxToken.mint(donor, 100e6);
        vm.prank(donor);
        taxToken.transfer(address(vault), 10e6); // vault receives 9e6 after tax

        // Engine deposits expected=100e6 through the 10% fee-on-transfer token:
        // only 90e6 arrives. A "delta since last vault op" scheme would observe
        // 90e6 + the donation and could credit up to expected with no flag.
        engine.collectAndDeposit(market, address(taxToken), 100e6);

        // Pre-transfer snapshot excludes the prior donation:
        assertEq(
            vault.credited(market, address(taxToken)),
            90e6,
            "shortfall must be recorded truth, not masked by the donation"
        );
        assertTrue(vault.lastDepositFlagged(), "shortfall must be flagged");
        // The donation is attributable surplus (sweepable), not a liability.
        assertEq(vault.totalLiabilities(address(taxToken)), 90e6);
        assertEq(vault.surplus(address(taxToken)), 9e6);
    }

    // ============================================
    // Transfer-tax shortfall: recorded truth + flag
    // ============================================

    function test_TaxShortfall_RecordedAndFlagged() public {
        engine.collectAndDeposit(market, address(taxToken), 100e6);

        assertEq(vault.credited(market, address(taxToken)), 90e6);
        assertTrue(vault.lastDepositFlagged());
        assertEq(vault.totalLiabilities(address(taxToken)), 90e6);
    }

    // ============================================
    // Excess delta is capped at expected (never over-credit)
    // ============================================

    function test_MidTransferDonation_CappedAtExpected() public {
        // A malicious/exotic token donates extra to the vault inside transfer():
        // delta > expected. Credit must cap at expected; excess is surplus.
        BonusToken bonus = new BonusToken(5e6);
        bonus.mint(address(engine), 1000e6);

        engine.collectAndDeposit(market, address(bonus), 100e6);

        assertEq(
            vault.credited(market, address(bonus)), 100e6, "credit must cap at expected"
        );
        assertEq(vault.surplus(address(bonus)), 5e6, "excess is surplus");
        assertFalse(vault.lastDepositFlagged());
    }

    // ============================================
    // Surplus sweep can never touch liabilities
    // ============================================

    function test_Sweep_OnlySurplus_NeverLiabilities() public {
        engine.collectAndDeposit(market, address(usdc), 100e6);
        vm.prank(donor);
        usdc.transfer(address(vault), 33e6); // donation

        uint256 swept = vault.sweepSurplus(address(usdc));
        assertEq(swept, 33e6);
        assertEq(usdc.balanceOf(treasury), 33e6);
        // Liabilities untouched and still fully backed
        assertEq(vault.totalLiabilities(address(usdc)), 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        // Second sweep: nothing left
        assertEq(vault.sweepSurplus(address(usdc)), 0);
    }

    // ============================================
    // Solvency invariant under arbitrary interleavings (fuzz)
    // ============================================

    function testFuzz_BalanceAlwaysCoversLiabilities(
        uint256 d1,
        uint256 donation,
        uint256 d2,
        bool sweepBetween
    ) public {
        d1 = bound(d1, 0, 100_000e6);
        d2 = bound(d2, 0, 100_000e6);
        donation = bound(donation, 0, 100_000e6);

        if (d1 > 0) engine.collectAndDeposit(market, address(usdc), d1);
        vm.prank(donor);
        usdc.transfer(address(vault), donation);
        if (sweepBetween) vault.sweepSurplus(address(usdc));
        if (d2 > 0) engine.collectAndDeposit(market, address(usdc), d2);

        assertGe(
            usdc.balanceOf(address(vault)),
            vault.totalLiabilities(address(usdc)),
            "solvency: balance must always cover accounted liabilities"
        );
        assertEq(vault.credited(market, address(usdc)), d1 + d2, "exact credits");
    }

    function testFuzz_TaxToken_CreditIsAlwaysRecordedTruth(uint256 amount) public {
        amount = bound(amount, 1, 100_000e6);
        engine.collectAndDeposit(market, address(taxToken), amount);

        uint256 delivered = amount - (amount * 1000) / 10_000;
        assertEq(vault.credited(market, address(taxToken)), delivered);
        assertGe(
            taxToken.balanceOf(address(vault)), vault.totalLiabilities(address(taxToken))
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Reference implementations (lifted by M2 / M3 / M4)
// ═══════════════════════════════════════════════════════════════════════════

/// @dev Minimal vault: ONLY the deposit-attribution + surplus logic (bucket
///      splitting and lifecycle live in the real vault). Credits by
///      balance delta against the caller-supplied pre-transfer snapshot, capped
///      at expected. Solvency: balanceOf(token) >= totalLiabilities[token].
contract DepositVaultPrototype {
    using SafeERC20 for IERC20;

    address public engine;
    address public immutable treasury;
    bool public lastDepositFlagged;

    mapping(address market => mapping(address token => uint256)) public credited;
    mapping(address token => uint256) public totalLiabilities;

    event DepositCredited(address indexed market, address indexed token, uint256 amount);
    event DepositShortfall(
        address indexed market,
        address indexed token,
        uint256 expected,
        uint256 creditedAmount
    );
    event SurplusSwept(address indexed token, uint256 amount);

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function setEngine(address _engine) external {
        require(engine == address(0), "engine set");
        engine = _engine;
    }

    /// @notice Push-then-notify: the engine snapshots this vault's balance
    ///         immediately before its own transfer and passes it here in the
    ///         same transaction. No standing allowances — the vault never has
    ///         transferFrom authority over engine balances.
    function notifyDeposit(
        address market,
        address token,
        uint256 expected,
        uint256 preBalance
    ) external returns (uint256 creditedAmount) {
        require(msg.sender == engine, "not engine");

        uint256 delta = IERC20(token).balanceOf(address(this)) - preBalance;
        // Cap at expected: excess (donations, exotic hooks) is attributable
        // surplus — never a liability. Shortfall (transfer tax) is recorded
        // truth + a flag.
        creditedAmount = delta < expected ? delta : expected;

        credited[market][token] += creditedAmount;
        totalLiabilities[token] += creditedAmount;

        lastDepositFlagged = creditedAmount < expected;
        if (lastDepositFlagged) {
            emit DepositShortfall(market, token, expected, creditedAmount);
        }
        emit DepositCredited(market, token, creditedAmount);
    }

    function surplus(address token) public view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - totalLiabilities[token];
    }

    /// @notice The ONLY recovery path; mathematically cannot touch liabilities.
    function sweepSurplus(address token) external returns (uint256 amount) {
        amount = surplus(token);
        if (amount > 0) {
            IERC20(token).safeTransfer(treasury, amount);
            emit SurplusSwept(token, amount);
        }
    }
}

/// @dev Reference engine-side sequence (M3 AMM revenue / M4 book fee):
///      snapshot → push → notify, all in one transaction.
contract MockEngine {
    using SafeERC20 for IERC20;

    DepositVaultPrototype public immutable vault;

    constructor(DepositVaultPrototype _vault) {
        vault = _vault;
    }

    function collectAndDeposit(address market, address token, uint256 amount) external {
        // 1. snapshot the vault's balance immediately before our own transfer
        uint256 preBalance = IERC20(token).balanceOf(address(vault));
        // 2. push
        IERC20(token).safeTransfer(address(vault), amount);
        // 3. notify with the snapshot, same tx
        vault.notifyDeposit(market, token, amount, preBalance);
    }
}

/// @dev ERC20 charging a bps tax on every transfer (transfer-tax shortfall case).
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable taxBps;

    constructor(uint256 _taxBps) ERC20("Tax", "TAX") {
        taxBps = _taxBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 tax = (amount * taxBps) / 10_000;
        _burn(msg.sender, tax);
        return super.transfer(to, amount - tax);
    }
}

/// @dev ERC20 that "donates" a bonus to the recipient inside transfer() —
///      models a donation landing between snapshot and push (delta > expected).
contract BonusToken is ERC20 {
    uint256 public immutable bonus;

    constructor(uint256 _bonus) ERC20("Bonus", "BON") {
        bonus = _bonus;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _mint(to, bonus); // exotic hook: extra tokens appear at the recipient
        return super.transfer(to, amount);
    }
}

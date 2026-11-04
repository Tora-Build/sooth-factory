// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 6-decimal instance token: the supported AMM-side config where WAD and
///      native differ, so every WAD->native conversion truncates.
contract East6 is ERC20 {
    constructor() ERC20("EAST6", "EAST6") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Mocks
// ═══════════════════════════════════════════════════════════════════════════

contract MockTM {
    bool public isLive = true;
    bool public isSettled;
    uint64 public startTime = uint64(block.timestamp);
    uint64 public deadline = uint64(block.timestamp + 30 days);
    uint64 public invalidationBuffer = 1 days;
    uint8 public winningOutcome;
    address public adjudicator;
    address public marketFactory;
    ITruthMarket.SettlementKind public settlementKind;

    constructor(address _adj, address _marketFactory) {
        adjudicator = _adj;
        marketFactory = _marketFactory;
    }

    function setLive(bool v) external {
        isLive = v;
    }

    function isTradingOpen() external view returns (bool) {
        return isLive && block.timestamp >= startTime && block.timestamp < deadline;
    }

    function isLiquidityOpen() external view returns (bool) {
        return isLive && block.timestamp < deadline;
    }

    function settle(uint8 outcome) external {
        isSettled = true;
        isLive = false;
        winningOutcome = outcome;
        settlementKind = ITruthMarket.SettlementKind.ADJUDICATED;
    }
}

/// @dev MarketFactory stand-in for registration, initialization, and bootstrap mint.
contract MockMarketFactory {
    AmmFeeVault public vault;
    BookFeeVault public bookVault;
    AMMEngine public amm;
    mapping(address => address) public creatorOf;
    address public tokenA;
    uint8 public tokenADecimals;

    function wire(
        AmmFeeVault _vault,
        BookFeeVault _bookVault,
        AMMEngine _amm,
        address _tokenA,
        uint8 _decimals
    ) external {
        vault = _vault;
        bookVault = _bookVault;
        amm = _amm;
        tokenA = _tokenA;
        tokenADecimals = _decimals;
    }

    function isPaused() external pure returns (bool) {
        return false;
    }

    function markets(address market)
        external
        view
        returns (address, address, address, uint8, uint256, uint256)
    {
        return (creatorOf[market], address(0), tokenA, tokenADecimals, 0, 0);
    }

    function createMarket(address market, address creator, uint256 bBase)
        external
        returns (uint256 lpToken)
    {
        creatorOf[market] = creator;
        (, uint256 quotedDepositWad) = PositionPricing.costBounds(bBase, 0, 0);
        uint256 depositWad = DecimalMath.toWad(
            DecimalMath.fromWadCeil(quotedDepositWad, tokenADecimals), tokenADecimals
        );

        vault.registerMarket(
            market,
            tokenA,
            tokenADecimals,
            vault.activeConfigVersion(),
            MockTM(market).adjudicator()
        );
        bookVault.registerMarket(
            market,
            bookVault.baseToken(),
            bookVault.baseTokenDecimals(),
            bookVault.activeConfigVersion(),
            MockTM(market).adjudicator()
        );
        amm.initializeMarket(market, tokenA, tokenADecimals, bBase, 0, 0, depositWad);

        // The AMM mints the creator bootstrap position and returns its id.
        lpToken = amm.mintLPTokens(market, creator, depositWad);
    }
}

/// @dev Book-engine stand-in: authorizes exact USDC fee pulls into its own vault.
contract MockBookEngine {
    using SafeERC20 for IERC20;

    BookFeeVault public immutable vault;
    IERC20 public immutable baseToken;

    constructor(BookFeeVault _vault, IERC20 _baseToken) {
        vault = _vault;
        baseToken = _baseToken;
    }

    function deposit(address market, IERC20 token, uint256 amount) external {
        token.forceApprove(address(vault), amount);
        require(
            vault.depositRevenue(market, amount, msg.sender) == amount, "credit mismatch"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Tests — M3 DoD: trades round-trip with fees landing in the vault; the
// widened invariant holds; redeemLP remains Token-A-only; sellers are paid immediately.
// ═══════════════════════════════════════════════════════════════════════════

contract AmmSixDecLedgerTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant B_BASE = 25e18;

    East6 east; // 6-dec instance token
    MockUSDC usdc; // book token (vault-side only here)
    AmmFeeVault vault;
    BookFeeVault bookVault;
    AMMEngine amm;
    MockMarketFactory marketFactory;
    MockBookEngine book;
    MockTM tm;
    LPPositionView lp;

    address market;
    address creator = address(0xC4EA70);
    address trader = address(0x7124);
    address adjudicator = address(0xAD11);
    address treasury = address(0x7EA5);
    address owner = address(0x0114E2);

    function setUp() public {
        east = new East6();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        marketFactory = new MockMarketFactory();

        NodeRoles roles = new NodeRoles(owner, owner, address(0));
        // Independent vaults bind their engines before those engines deploy.
        uint64 n = vm.getNonce(address(this));
        address predictedAmm = vm.computeCreateAddress(address(this), n + 3);
        address predictedBook = vm.computeCreateAddress(address(this), n + 2);
        vault = new AmmFeeVault(
            IAmmFeeVault.Init(
                predictedAmm,
                address(marketFactory),
                address(roles),
                treasury,
                IAmmFeeVault.AmmConfig(100, 5000, 3000, 1000, 1000, treasury)
            )
        );
        bookVault = new BookFeeVault(
            IBookFeeVault.Init(
                predictedBook,
                address(marketFactory),
                address(roles),
                address(usdc),
                treasury,
                10_000,
                IBookFeeVault.BookConfig(100, 1000, 9000, treasury)
            )
        );
        book = new MockBookEngine(bookVault, IERC20(address(usdc)));
        amm = new AMMEngine(address(marketFactory), address(vault));
        require(address(amm) == predictedAmm, "nonce prediction failed");
        marketFactory.wire(vault, bookVault, amm, address(east), east.decimals());

        // Create the market (deposit = b·ln2 ≈ 17.33 EAST at p = 0.5)
        tm = new MockTM(adjudicator, address(marketFactory));
        market = address(tm);
        (, uint256 depositWad) = PositionPricing.costBounds(B_BASE, 0, 0);
        east.mint(address(amm), DecimalMath.fromWadCeil(depositWad, east.decimals()));
        lp = new LPPositionView(
            LPPositionManager(amm.positionManager()),
            marketFactory.createMarket(market, creator, B_BASE)
        );

        east.mint(trader, 100_000e6);
        vm.prank(trader);
        east.approve(address(amm), type(uint256).max);
        usdc.mint(address(book), 1000e18);
    }

    function _assertWidenedInvariant() internal view {
        uint256 marketLiability =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertGe(
            east.balanceOf(address(amm)) * 1e12,
            marketLiability,
            "widened invariant (WAD-normalised for a 6-dec token)"
        );
        assertEq(
            amm.totalLiabilitiesOf(address(east)),
            marketLiability,
            "6-dec aggregate equals market-scoped liabilities"
        );
    }

    uint256 constant UNIT = 1e12; // 1 native unit of a 6-dec token, in WAD

    function _seedPosition() internal {
        vm.prank(trader);
        amm.tradePositions(market, 1, 400e18, type(uint256).max);
    }

    /// @dev ROUNDING-SPEC P5 on the real sell path: the WAD ledger may only be
    ///      debited by the value the transfer actually carried.
    function test_P5_SellDebitsOnlyWhatLeaves() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 60e18, type(uint256).max);

        uint256 coll0 = amm.getMarketCollateral(market);
        uint256 bal0 = east.balanceOf(address(amm));

        vm.prank(trader);
        amm.tradePositions(market, 1, -30e18, 0);

        uint256 ledgerDropWad = coll0 - amm.getMarketCollateral(market);
        uint256 leftWad = (bal0 - east.balanceOf(address(amm))) * UNIT;

        assertEq(ledgerDropWad, leftWad, "P5: sell debit must equal value sent");
        _assertWidenedInvariant();
    }

    /// @dev P5 on settlePosition. The share amount is deliberately NOT a whole
    ///      multiple of one native unit (1e12), so the payout truncates — a
    ///      round amount would not exercise the bug at all.
    function test_P5_SettlePositionDebitsOnlyWhatLeaves() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 60e18 + 123_456_789, type(uint256).max);
        tm.settle(1);

        uint256 coll0 = amm.getMarketCollateral(market);
        uint256 bal0 = east.balanceOf(address(amm));

        vm.prank(trader);
        amm.settlePosition(market);

        uint256 debited = coll0 - amm.getMarketCollateral(market);
        uint256 leftWad = (bal0 - east.balanceOf(address(amm))) * UNIT;
        assertEq(debited, leftWad, "P5: settle debit must equal value sent");
        _assertWidenedInvariant();
    }

    function test_P5_SellRetainsSubUnitRemainderInMarketPrincipal() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 60e18 + 987_654_321, type(uint256).max);
        (uint256 base, uint256 fee, uint256 quoted,) =
            amm.getPositionQuote(market, 1, -int256(30e18 + 123_456_789));
        assertEq(quoted, base - fee);
        assertGt(quoted % UNIT, 0, "fixture exercises seller remainder");
        uint256 revenue = fee - fee * 5000 / BPS;
        uint256 collateralBefore = amm.getMarketCollateral(market);
        uint256 totalBefore = amm.totalLiabilitiesOf(address(east));
        uint256 sellerBefore = east.balanceOf(trader);
        vm.prank(trader);
        assertEq(
            amm.tradePositions(market, 1, -int256(30e18 + 123_456_789), quoted), quoted
        );
        uint256 sent = (quoted / UNIT + revenue / UNIT) * UNIT;
        assertEq(east.balanceOf(trader) - sellerBefore, quoted / UNIT);
        assertEq(amm.getMarketCollateral(market), collateralBefore - sent);
        assertEq(amm.totalLiabilitiesOf(address(east)), totalBefore - sent);
        _assertWidenedInvariant();
    }

    /// @dev The engine must never claim to hold less than it does: after many
    ///      sells the collateral counter must still be covered by real balance.
    function test_P5_NoPhantomShrinkageOverManySells() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 300e18, type(uint256).max);

        for (uint256 i = 0; i < 12; i++) {
            vm.prank(trader);
            amm.tradePositions(market, 1, -10e18, 0);
            _assertWidenedInvariant();
        }

        // Ledger must remain fully backed by the tokens actually held.
        assertGe(
            east.balanceOf(address(amm)) * UNIT,
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market),
            "ledger must stay covered after repeated sells"
        );
    }
}

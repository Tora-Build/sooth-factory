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
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev 18-decimal instance token (EAST) — native units == WAD, exact.
contract East18 is ERC20 {
    constructor() ERC20("EAST", "EAST") {}

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

/// @dev MarketFactory stand-in: owns the creation sequence (vault registration first,
///      then AMM init + LP token + bootstrap mint).
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
        (, uint256 depositWad) = PositionPricing.costBounds(bBase, 0, 0);

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
// widened invariant holds; redeemLP is Token-A-only; sellers are paid immediately.
// ═══════════════════════════════════════════════════════════════════════════

contract AMMEngineVaultTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant B_BASE = 25e18;

    East18 east; // 18-dec instance token (exact WAD)
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
        east = new East18();
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
        east.mint(address(amm), depositWad); // the creator deposit transfer
        lp = new LPPositionView(
            LPPositionManager(amm.positionManager()),
            marketFactory.createMarket(market, creator, B_BASE)
        );

        east.mint(trader, 100_000e18);
        vm.prank(trader);
        east.approve(address(amm), type(uint256).max);
        usdc.mint(address(book), 1000e18);
    }

    function _assertWidenedInvariant() internal view {
        assertGe(
            east.balanceOf(address(amm)),
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market),
            "widened invariant: balance >= collateral + floorLiability"
        );
    }

    function _seedPosition() internal {
        vm.prank(trader);
        amm.tradePositions(market, 1, 400e18, type(uint256).max);
    }

    // ============================================
    // AMM fee: CAPITAL grows b and revenue enters the vault
    // ============================================

    function test_AmmFee_GrowsBByCapital_AndDoesNotMintLP() public {
        uint256 b0 = amm.getLiquidity(market);
        uint256 lp0 = lp.balanceOf(trader);

        (uint256 cost, uint256 fee, uint256 net,) = amm.getPositionQuote(market, 1, 10e18);
        vm.prank(trader);
        uint256 paid = amm.tradePositions(market, 1, 10e18, type(uint256).max);

        assertEq(paid, net, "quote == execution");
        assertEq(paid, cost + fee);
        assertEq(lp.balanceOf(trader), lp0, "ordinary trade cannot mint LP");
        uint256 capital = (fee * 5000) / BPS;
        assertEq(amm.getLiquidity(market) - b0, capital, "b grows by capitalWad");
        assertEq(east.balanceOf(address(vault)), fee - capital, "revenue to vault");
        _assertWidenedInvariant();
    }

    // ============================================
    // Approved AMM split is stable on every trade
    // ============================================

    function test_TradeNeverMintsLPAndUsesSingleFeeSchedule() public {
        _seedPosition();
        uint256 supply = lp.totalSupply();
        vm.prank(trader);
        amm.tradePositions(market, 1, 5e18, type(uint256).max);
        assertEq(lp.totalSupply(), supply, "ordinary trades never mint LP");
    }

    // ============================================
    // Buy: 1% fee → 50% capital stays, 50% revenue → vault
    // ============================================

    function test_Buy_RevenueLandsInVault() public {
        _seedPosition();
        uint256 coll0 = amm.getMarketCollateral(market);
        uint256 vault0 = east.balanceOf(address(vault));
        uint256 lpPool0 = vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(east));

        (uint256 cost, uint256 fee,,) = amm.getPositionQuote(market, 1, 50e18);
        uint256 capital = (fee * 5000) / BPS;
        uint256 revenue = fee - capital;

        vm.prank(trader);
        amm.tradePositions(market, 1, 50e18, type(uint256).max);

        assertEq(
            amm.getMarketCollateral(market),
            coll0 + cost + capital,
            "buy: collateral += baseCost + capitalShare only"
        );
        assertEq(
            east.balanceOf(address(vault)) - vault0,
            revenue,
            "vault received exactly the revenue share"
        );
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(east)) - lpPool0,
            (revenue * 3000) / 5000, // renormalized over non-capital denom
            "vault split the revenue by the renormalized weights"
        );
        _assertWidenedInvariant();
    }

    function test_Sell_ProceedsPaidImmediately_RevenueLeaves() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 50e18, type(uint256).max);

        uint256 coll0 = amm.getMarketCollateral(market);
        (uint256 cost, uint256 fee, uint256 net,) =
            amm.getPositionQuote(market, 1, -50e18);
        uint256 revenue = fee - (fee * 5000) / BPS;
        assertEq(net, cost - fee);
        uint256 sellerBefore = east.balanceOf(trader);

        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -50e18, 0);

        assertEq(proceeds, net);
        assertEq(
            amm.getMarketCollateral(market),
            coll0 - proceeds - revenue,
            "sell: collateral -= netProceeds + revenueShare"
        );
        assertEq(east.balanceOf(trader) - sellerBefore, proceeds);
        _assertWidenedInvariant();
    }

    // ============================================
    // Quote fidelity: fresh-b newPrice realized
    // ============================================

    function test_Quote_FreshBRealized() public {
        (,,, uint256 quoted) = amm.getPositionQuote(market, 1, 100e18);
        vm.prank(trader);
        amm.tradePositions(market, 1, 100e18, type(uint256).max);
        (,, uint256 realized) = amm.getMarketState(market);
        assertEq(realized, quoted, "quoted newPrice == realized price");
    }

    // ============================================
    // redeemLP: state-only burn, 3 recorded claims, independent pulls
    // ============================================

    function test_RedeemLP_TokenAOnlyClaims() public {
        _seedPosition();
        vm.prank(trader);
        amm.tradePositions(market, 1, 50e18, type(uint256).max); // EAST revenue
        book.deposit(market, IERC20(address(usdc)), 100e18); // USDC book fees

        tm.settle(0); // NO wins — trader's YES worthless; creator's floor rich

        uint256 supply = lp.totalSupply();
        uint256 creatorLP = lp.balanceOf(creator);
        uint256 coll0 = amm.getMarketCollateral(market);
        uint256 eastPool = vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(east));
        assertGt(eastPool, 0, "AMM revenue reached the vault LP bucket");

        vm.prank(creator);
        uint256 floorShare = amm.redeemLP(market, creatorLP);

        // 1) engine-side floor entitlement, collateral debited at burn
        assertGt(floorShare, 0);
        assertEq(amm.getMarketCollateral(market), coll0 - floorShare);
        assertEq(amm.claimableFloorLiability(market), floorShare);
        assertEq(amm.floorEntitlementOf(market, creator), floorShare);
        assertEq(lp.totalSupply(), supply - creatorLP, "burned");

        // Vault dividends are Token-A-only (pro-rata by lp/supplyBeforeBurn).
        assertApproxEqAbs(
            vault.lpEntitlementOf(market, creator, address(east)),
            (eastPool * creatorLP) / supply,
            1
        );
        assertEq(vault.lpEntitlementOf(market, creator, address(usdc)), 0);

        // independent pulls
        uint256 eastBal0 = east.balanceOf(creator);
        vm.prank(creator);
        uint256 pulled = amm.claimFloor(market);
        assertEq(pulled, floorShare);
        assertEq(east.balanceOf(creator) - eastBal0, floorShare);
        assertEq(amm.claimableFloorLiability(market), 0);

        if (vault.lpEntitlementOf(market, creator, address(east)) > 0) {
            vm.prank(creator);
            vault.claimLPDividend(market);
        }
        assertEq(usdc.balanceOf(creator), 0, "LP receives zero book token");
        _assertWidenedInvariant();
    }

    // ============================================
    // Top-up gate: pinned OFF for the pilot
    // ============================================

    function test_TopUps_DisabledByPinnedConfig() public {
        vm.prank(creator);
        vm.expectRevert(AMMEngine.TopUpsDisabled.selector);
        amm.increaseLiquidityFromCreator(market, 1e18);
    }

    // ============================================
    // Final-outcome settlement and seller liabilities
    // ============================================

    function test_Settlement_LosingPositionClearedExactlyOnce() public {
        _seedPosition();
        tm.settle(0);
        uint256 before = east.balanceOf(trader);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 0);
        assertEq(east.balanceOf(trader), before);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.NoPosition.selector);
        amm.settlePosition(market);
        _assertWidenedInvariant();
    }

    function test_Settlement_PreservesAlreadyPaidSale() public {
        _seedPosition();
        uint256 before = east.balanceOf(trader);
        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -100e18, 0);
        assertEq(east.balanceOf(trader) - before, proceeds);
        tm.settle(1);
        assertEq(east.balanceOf(trader) - before, proceeds);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 300e18);
        assertEq(east.balanceOf(trader) - before, proceeds + 300e18);
        _assertWidenedInvariant();
    }

    function test_LPBurnBeforePosition_PreservesWinnerReserve() public {
        _seedPosition();
        tm.settle(1);
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP / 2);
        assertGe(amm.getMarketCollateral(market), 400e18);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 400e18);
        uint256 remainingLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, remainingLP);
        _assertWidenedInvariant();
    }

    // ============================================
    // Fuzz: widened invariant across mixed sequences
    // ============================================

    function testFuzz_WidenedInvariant_MixedOps(uint256 a, uint256 b_, uint256 c) public {
        a = bound(a, 1e18, 300e18);
        b_ = bound(b_, 1e18, 200e18);
        c = bound(c, 1e17, a / 2);

        vm.startPrank(trader);
        amm.tradePositions(market, 1, int256(a), type(uint256).max);
        _assertWidenedInvariant();
        amm.tradePositions(market, 0, int256(b_), type(uint256).max);
        _assertWidenedInvariant();
        amm.tradePositions(market, 1, -int256(c), 0);
        _assertWidenedInvariant();
        vm.stopPrank();

        tm.settle(1);
        vm.prank(trader);
        amm.settlePosition(market);
        _assertWidenedInvariant();

        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(market, creatorLP / 2);
        _assertWidenedInvariant();
    }
}

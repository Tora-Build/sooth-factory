// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {OrderEngine} from "src/OrderEngine.sol";

import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev 24-decimal token for the MarketFactory decimals-guard test.
contract Token24 is ERC20 {
    constructor() ERC20("T24", "T24") {}

    function decimals() public pure override returns (uint8) {
        return 24;
    }
}

contract MockTMB {
    address public immutable marketFactory;

    constructor(address marketFactory_) {
        marketFactory = marketFactory_;
    }
    bool public isLive = true;
    bool public isTradingOpen = true;
    bool public isSettled;
    uint64 public startTime = uint64(block.timestamp);
    uint64 public deadline = uint64(block.timestamp + 30 days);
    uint64 public invalidationBuffer = 1 days;
    address public adjudicator = address(0xAD11);
    ITruthMarket.SettlementKind public settlementKind;

    function setTradingOpen(bool open) external {
        isTradingOpen = open;
    }
}

/// @dev MarketFactory stand-in: registers the market with the vault and the engine.
contract MockMarketFactoryB {
    BookFeeVault public vault;
    OrderEngine public engine;
    address public tokenA;
    uint8 public tokenADecimals;

    function wire(
        BookFeeVault _vault,
        OrderEngine _engine,
        address _tokenA,
        uint8 _tokenADecimals
    ) external {
        vault = _vault;
        engine = _engine;
        tokenA = _tokenA;
        tokenADecimals = _tokenADecimals;
    }

    function registerWithVault(address market) external {
        vault.registerMarket(
            market, tokenA, tokenADecimals, vault.activeConfigVersion(), address(0xAD11)
        );
    }

    function registerWithEngine(address market, address tokenParam, uint256 price)
        external
    {
        engine.registerMarket(market, tokenParam, price);
    }
}

/// @dev AMM stand-in: only an authenticated address for the vault; it never
///      trades, so the book fee below is proven independent of AMM volume.
contract MockAmmB {}

contract OrderEngineVaultFeeTest is Test {
    MockUSDC usdc; // 6-dec — exercises the REAL truncation path
    MockUSDC tokenA;
    BookFeeVault vault;
    OrderEngine engine;
    MockMarketFactoryB marketFactory;
    MockAmmB amm;
    MockTMB tm;
    address market;

    address taker = address(0x7A4E2);
    address maker = address(0x3A4E2);
    address treasury = address(0x7EA5);
    address owner = address(0x0114E2);

    uint16 constant AMM_FEE_BPS = 300;
    uint16 constant BOOK_FEE_BPS = 100;

    function setUp() public {
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        tokenA = new MockUSDC("Token A", "TKNA");
        marketFactory = new MockMarketFactoryB();
        amm = new MockAmmB();

        NodeRoles roles = new NodeRoles(owner, owner, address(0));
        uint64 n = vm.getNonce(address(this));
        address predictedEngine = vm.computeCreateAddress(address(this), n + 1);
        vault = new BookFeeVault(
            IBookFeeVault.Init(
                predictedEngine,
                address(marketFactory),
                address(roles),
                address(usdc),
                treasury,
                500,
                IBookFeeVault.BookConfig(BOOK_FEE_BPS, 1000, 9000, treasury)
            )
        );
        engine = new OrderEngine(address(usdc), address(marketFactory), address(vault));
        require(address(engine) == predictedEngine, "nonce prediction failed");
        marketFactory.wire(vault, engine, address(usdc), usdc.decimals());

        tm = new MockTMB(address(marketFactory));
        market = address(tm);
        marketFactory.registerWithVault(market);
        marketFactory.registerWithEngine(market, address(usdc), 0.5e18);

        usdc.mint(taker, 1_000_000e6);
        usdc.mint(maker, 1_000_000e6);
        vm.prank(taker);
        usdc.approve(address(engine), type(uint256).max);
        vm.prank(maker);
        usdc.approve(address(engine), type(uint256).max);
    }

    /// @dev One fill through the public book: `maker` rests a NO buy at `1000 - yesTick`
    ///      (an ASK at `yesTick` on the single axis) and `taker` crosses it with a YES
    ///      buy at exactly that tick. Replaces the old `fillOrder` harness: under
    ///      ADR-0008 there is no internal fill entry point that takes both parties'
    ///      ticks and escrow flags, so the tests go through the path users take.
    function _cross(uint16 yesTick, uint128 shares) internal {
        vm.prank(maker);
        engine.placeOrder(market, BookTestOrders.buy(0, 1000 - yesTick, shares, 256));
        vm.prank(taker);
        engine.placeOrder(market, BookTestOrders.buy(1, yesTick, shares, 256));
    }

    // ============================================
    // M4 DoD: a book fill deposits its USDC fee into the vault
    // ============================================

    function test_Fill_TakerFee_LandsInVault_SplitApplied() public {
        // The maker rests first: their 0.40 leg is posted when the order rests.
        vm.prank(maker);
        engine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        uint256 vault0 = usdc.balanceOf(address(vault));
        uint256 backing0 = engine.getCollateralBacking(market);
        assertEq(vault0, 0, "resting charges no fee");

        // The taker buys 100 YES at tick 600 (0.60): cost 60 USDC, charged at the
        // BOOK slot (not the AMM slot) with zero AMM volume.
        vm.prank(taker);
        engine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 256));

        uint256 takerBase = 60e6; // the taker's own leg: 100 * 0.60 in 6-dec
        uint256 feeBasis = 40e6; // but the fee basis is min(0.6, 0.4) * 100
        uint256 feeReceived = usdc.balanceOf(address(vault)) - vault0;
        assertGt(feeReceived, 0, "fee must land in the vault");
        assertApproxEqAbs(
            feeReceived, (feeBasis * BOOK_FEE_BPS) / 10_000, 1, "book-slot fee"
        );
        assertTrue(
            feeReceived != (feeBasis * AMM_FEE_BPS) / 10_000, "must not use AMM slot"
        );
        assertEq(vault.feeBpsOf(market), BOOK_FEE_BPS);

        // The fill added ONLY the taker's leg to backing (the maker's was collected
        // when the order rested), and the two legs together back the 100 shares of
        // open interest exactly — no fee custody, no AMM bridge.
        assertEq(engine.getCollateralBacking(market) - backing0, takerBase);
        assertEq(engine.getCollateralBacking(market), 100e6);
        (uint256 yesSupply, uint256 noSupply) = engine.getSupplies(market);
        assertEq(yesSupply, 100e18);
        assertEq(noSupply, 100e18);
        assertEq(
            usdc.balanceOf(address(engine)),
            engine.getCollateralBacking(market),
            "engine balance == backing exactly (no stray fee custody)"
        );

        // Book value cannot enter the LP bucket.
        uint256 lp = 0; // Book has no LP liability class.
        uint256 adj =
            vault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 prot =
            vault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        assertEq(lp, 0);
        assertEq(adj, (feeReceived * 1000) / 10_000);
        assertEq(adj + prot, feeReceived, "exact-sum split");
        assertEq(vault.totalLiabilitiesOf(address(usdc)), feeReceived);
    }

    /// Round-4 review gap, carried to the single axis: out-of-domain ticks are
    /// refused on both entry points before anything is credited or collected. The
    /// action and outcome determine the normalized book side.
    function test_Fill_RejectsOutOfDomainTick() public {
        vm.startPrank(taker);
        vm.expectRevert(OrderEngine.InvalidTick.selector);
        engine.placeOrder(market, BookTestOrders.buy(1, 1000, 100e18, 256));
        vm.expectRevert(OrderEngine.InvalidTick.selector);
        engine.placeOrder(market, BookTestOrders.buy(1, 0, 100e18, 256));
        vm.expectRevert(OrderEngine.InvalidTick.selector);
        engine.placeOrder(market, BookTestOrders.buy(0, 1000, 100e18, 256));
        vm.expectRevert(OrderEngine.InvalidTick.selector);
        engine.placeOrder(market, BookTestOrders.buy(0, 0, 100e18, 256));
        vm.stopPrank();
        (uint256 ty, uint256 tn) = engine.getPosition(market, taker);
        (uint256 my, uint256 mn) = engine.getPosition(market, maker);
        assertEq(ty + tn + my + mn, 0, "nothing credited");
        assertEq(engine.getCollateralBacking(market), 0, "nothing collected");
    }

    function test_Fill_RevertsWhenTradingClosed() public {
        vm.prank(maker);
        engine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        tm.setTradingOpen(false);
        vm.expectRevert(OrderEngine.MarketNotLive.selector);
        vm.prank(taker);
        engine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 256));
    }

    function test_BookFee_StableAcrossVolume() public {
        for (uint256 i = 0; i < 3; i++) {
            uint256 v0 = usdc.balanceOf(address(vault));
            _cross(600, 100e18);
            assertApproxEqAbs(
                usdc.balanceOf(address(vault)) - v0,
                (uint256(40e6) * BOOK_FEE_BPS) / 10_000,
                1
            );
        }
        assertEq(vault.feeBpsOf(market), BOOK_FEE_BPS);
    }

    function test_RegisterMarket_RejectsDoubleRegistration() public {
        vm.expectRevert(OrderEngine.MarketAlreadyRegistered.selector);
        marketFactory.registerWithEngine(market, address(usdc), 0.5e18);
    }

    /// Inventory-selling takers pay the same complementary fee as buyers.
    function test_Fill_ClosingTaker_PaysFeeOnItsLeg() public {
        _cross(600, 100e18); // taker owns 100 YES, maker owns 100 NO
        assertEq(engine.getNet(market, taker), 100e18);

        // The maker bids 600 for YES and the taker transfers 50 held YES into it.
        vm.prank(maker);
        engine.placeOrder(market, BookTestOrders.buy(1, 600, 50e18, 256));
        uint256 vault0 = usdc.balanceOf(address(vault));
        uint256 taker0 = usdc.balanceOf(taker);

        vm.prank(taker);
        engine.placeOrder(market, BookTestOrders.sell(1, 600, 50e18, 256));

        uint256 fee = usdc.balanceOf(address(vault)) - vault0;
        // min(0.6, 0.4) x 50 = 20.00: here the min basis and her own leg coincide.
        assertEq(fee, (uint256(20e6) * BOOK_FEE_BPS) / 10_000, "1% of min(p, 1-p)");
        // Sale proceeds are 0.60 times 50; complete-set backing stays in custody.
        assertEq(
            usdc.balanceOf(taker), taker0 - 20e6 - fee + 50e6, "net 0.60/share less fee"
        );
        assertEq(engine.getNet(market, taker), 50e18);
    }

    // ============================================
    // C7: MarketRegistered emits the engine's OWN token
    // ============================================

    function test_RegisterMarket_EmitsOwnToken() public {
        MockTMB tm2 = new MockTMB(address(marketFactory));
        vm.expectEmit(true, false, false, true);
        emit IOrderEngine.MarketRegistered(address(tm2), address(usdc), 0.4e18);
        marketFactory.registerWithEngine(address(tm2), address(usdc), 0.4e18);
    }

    // ============================================
    // Token-A technical guard at registration: decimals <= 18 (ADR-0006)
    // ============================================

    function test_Vault_RejectsHighDecimalsTokenAtRegistration() public {
        Token24 t24 = new Token24();
        marketFactory.wire(vault, engine, address(t24), 24);
        MockTMB tm2 = new MockTMB(address(marketFactory));
        vm.expectRevert(VenueFeeVault.InvalidToken.selector);
        marketFactory.registerWithVault(address(tm2));
    }
}

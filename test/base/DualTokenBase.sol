// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {LMSRMath} from "../reference/LMSRMath.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev 18-decimal instance token (EAST).
contract East18E is ERC20 {
    constructor() ERC20("EAST", "EAST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title DualTokenBase
 * @notice Shared local fixture with explicit test-only policy numbers.
 *         Factory deployment and distinct authority consent have separate tests.
 */
abstract contract DualTokenBase is Test {
    uint256 constant B_BASE = 25e18;

    East18E east;
    MockUSDC usdc;
    TruthMarket truthImpl;
    OrderEngine orderEngine;
    AMMEngine amm;
    AmmFeeVault vault;
    BookFeeVault bookVault;
    NodeRoles roles;
    MarketFactory marketFactory;
    ManualAdjudicator adjudicator;

    address creator = address(0xC4EA70);
    address trader = address(0x7124);
    address alice = address(0xA11CE); // book taker
    address bob = address(0xB0B); // book maker
    address resolver = address(0x4E50);
    address treasury = address(0x7EA5);

    address market;
    LPPositionView lp;

    function setUp() public virtual {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        _deployStack(address(usdc));
        _fundAndApprove();
    }

    /// @dev Deploys the production stack for an arbitrary node-wide book token.
    ///      Token A is selected and pinned independently at market creation.
    function _deployStack(address bookToken) internal {
        uint64 n = vm.getNonce(address(this));
        address pVault = vm.computeCreateAddress(address(this), n + 4);
        address pBookVault = vm.computeCreateAddress(address(this), n + 5);
        address pMarketFactory = vm.computeCreateAddress(address(this), n + 6);

        truthImpl = new TruthMarket();
        roles = new NodeRoles(address(this), address(this), address(0));
        orderEngine = new OrderEngine(bookToken, pMarketFactory, pBookVault);
        amm = new AMMEngine(pMarketFactory, pVault);
        vault = new AmmFeeVault(
            IAmmFeeVault.Init(
                address(amm), pMarketFactory, address(roles), treasury, _ammConfig()
            )
        );
        bookVault = new BookFeeVault(
            IBookFeeVault.Init(
                address(orderEngine),
                pMarketFactory,
                address(roles),
                bookToken,
                treasury,
                10_000,
                _bookConfig()
            )
        );
        marketFactory = new MarketFactory(
            address(truthImpl),
            address(amm),
            address(vault),
            address(orderEngine),
            address(bookVault),
            address(roles)
        );
        require(address(marketFactory) == pMarketFactory, "prediction failed");
        adjudicator =
            new ManualAdjudicator(address(this), address(marketFactory), 1 hours);
        marketFactory.setInvalidationBuffer(7 days);
        marketFactory.setCreatorAllowed(creator, true);
        if (address(east) != address(0)) {
            marketFactory.setTokenAllowed(
                address(east), true, marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT()
            );
        }
        marketFactory.setTokenAllowed(
            bookToken, true, marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT()
        );
    }

    function _fundAndApprove() internal {
        // ── Funding + approvals ──
        east.mint(creator, 1000e18);
        east.mint(trader, 100_000e18);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        vm.prank(trader);
        east.approve(address(amm), type(uint256).max);
        vm.startPrank(alice);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.stopPrank();
    }

    function _ammConfig() internal view returns (IAmmFeeVault.AmmConfig memory) {
        return IAmmFeeVault.AmmConfig(100, 5000, 3000, 1000, 1000, treasury);
    }

    function _bookConfig() internal view returns (IBookFeeVault.BookConfig memory) {
        return IBookFeeVault.BookConfig(100, 1000, 9000, treasury);
    }

    function _marketParams(
        string memory question,
        uint64 start,
        uint64 deadline,
        address tokenA,
        uint256 depth,
        uint256 probability
    ) internal returns (IMarketFactory.MarketParams memory p) {
        if (!adjudicator.profileFrozen()) {
            adjudicator.approveResolver(resolver);
            adjudicator.setEarlyResolution(_earlyResolution());
            adjudicator.freezeProfile();
        }
        marketFactory.setAdjudicatorAllowed(address(adjudicator), true);
        // Custom tokens in tests are explicitly admitted by the node administrator.
        marketFactory.setTokenAllowed(
            tokenA, true, marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT()
        );
        (uint256 yes, uint256 no) = PositionPricing.initialQuantities(depth, probability);
        (, uint256 wad) = PositionPricing.costBounds(depth, yes, no);
        p.question = question;
        p.startTime = start;
        p.deadline = deadline;
        p.adjudicator = address(adjudicator);
        p.tokenA = tokenA;
        p.bBase = depth;
        p.initialProbabilityWad = probability;
        p.adjudicatorConfig = abi.encode(resolver, deadline, bytes(""));
        p.maxInputNative = DecimalMath.fromWadCeil(wad, IERC20Metadata(tokenA).decimals());
        p.quoteDeadline = uint64(block.timestamp + 1 hours);
        p.expectedAmmVersion = vault.activeConfigVersion();
        p.expectedBookVersion = bookVault.activeConfigVersion();
        p.expectedAmmHash = vault.configHash(p.expectedAmmVersion);
        p.expectedBookHash = bookVault.configHash(p.expectedBookVersion);
        p.resolutionTermsHash =
            keccak256(abi.encode(question, "local test resolution terms"));
        p.expectedProfileHash = adjudicator.profileHash();
        p.expectedInvalidationBuffer = marketFactory.invalidationBuffer();
    }

    function _liquidityLimits(address target, uint256 depth)
        internal
        view
        returns (IAMMEngine.LiquidityLimits memory limits)
    {
        (uint256 input, uint256 units, uint256 price, bytes32 stateHash) =
            amm.quoteLiquidityWithState(target, depth);
        limits = IAMMEngine.LiquidityLimits(
            input, units, price, price, ITruthMarket(target).deadline(), stateHash
        );
    }

    function _createMarket() internal {
        _createMarketWithStart(0, uint64(block.timestamp + 20 days));
    }

    function _createMarketWithStart(uint64 startTime, uint64 deadline) internal {
        IMarketFactory.MarketParams memory p = _marketParams(
            "Will it rain in Lisbon tomorrow?",
            startTime,
            deadline,
            address(east),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (market,) = marketFactory.createMarket(p);
        lp = new LPPositionView(
            LPPositionManager(amm.positionManager()), marketFactory.getLPToken(market)
        );
    }

    function _seedAmmPosition() internal {
        vm.prank(trader);
        amm.tradePositions(market, 1, 400e18, type(uint256).max);
    }

    /// @dev Suites resolve at any time unless a subclass selects the shipped default,
    ///      under which a proposal opens at the market deadline.
    function _earlyResolution() internal pure virtual returns (bool) {
        return true;
    }

    function _resolveAndSettle(uint8 outcome) internal {
        uint64 deadline = ITruthMarket(market).deadline();
        if (!adjudicator.earlyResolution() && block.timestamp < deadline) {
            vm.warp(deadline);
        }
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("data"));
        vm.warp(block.timestamp + 1 hours + 1);
        adjudicator.settle(market);
    }

    // ── Shared solvency assertions ──

    function _assertSystemSolvent() internal view {
        assertGe(
            east.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(east)),
            "vault EAST solvency"
        );
        assertGe(
            usdc.balanceOf(address(bookVault)),
            bookVault.totalLiabilitiesOf(address(usdc)),
            "vault USDC solvency"
        );
        assertGe(
            east.balanceOf(address(amm)),
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market),
            "AMM widened invariant"
        );
        assertGe(
            east.balanceOf(address(amm)),
            amm.totalLiabilitiesOf(address(east)),
            "AMM token-scoped liability"
        );
    }
}

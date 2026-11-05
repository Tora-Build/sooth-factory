// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";

contract AlternateToken18 is ERC20 {
    constructor() ERC20("Alternate Token A", "ALTA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AlternateToken6 is ERC20 {
    constructor() ERC20("Six Decimal Token A", "SIXA") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Admission can vet metadata, but creation still proves exact receipt.
contract TransferTaxTokenA is ERC20 {
    bool internal taxEnabled;

    constructor() ERC20("Taxed Token A", "TAXA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxEnabled(bool enabled) external {
        taxEnabled = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxEnabled && from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}

contract MutableDecimalsTokenA is ERC20 {
    uint8 internal mutableDecimals = 18;

    constructor() ERC20("Mutable Decimal Token A", "MUTA") {}

    function decimals() public view override returns (uint8) {
        return mutableDecimals;
    }

    function setDecimals(uint8 value) external {
        mutableDecimals = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SweepOnVaultTransferTokenA is ERC20 {
    AmmFeeVault internal immutable vault;
    bool internal armed;

    constructor(AmmFeeVault _vault) ERC20("Sweep Hook Token A", "HOOKA") {
        vault = _vault;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm() external {
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0) && to == address(vault)) {
            armed = false;
            vault.sweepUnattributedSurplus(address(this));
        }
    }
}

contract PerMarketTokenATest is DualTokenBase {
    struct ClaimResult {
        uint256 floor;
        uint256 dividend;
        uint256 traderPayout;
        uint256 creatorTokenAReceived;
        uint256 creatorBookTokenReceived;
        uint256 aliceBookTokenReceived;
        uint256 bobBookTokenReceived;
    }

    AlternateToken18 internal alternate18;
    AlternateToken6 internal alternate6;

    function setUp() public override {
        super.setUp();
        alternate18 = new AlternateToken18();
        alternate6 = new AlternateToken6();

        alternate18.mint(creator, 10_000e18);
        alternate18.mint(trader, 100_000e18);
        alternate6.mint(creator, 10_000e6);
        alternate6.mint(trader, 100_000e6);

        vm.startPrank(creator);
        alternate18.approve(address(marketFactory), type(uint256).max);
        alternate6.approve(address(marketFactory), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(trader);
        alternate18.approve(address(amm), type(uint256).max);
        alternate6.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    function _createWithToken(address token, string memory question)
        internal
        returns (address createdMarket, LPPositionView createdLp)
    {
        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation1 =
            _marketParams(question, 0, deadline, token, B_BASE, 0.5e18);
        vm.prank(creator);
        uint256 lpAddress;
        (createdMarket, lpAddress) = marketFactory.createMarket(creation1);
        createdLp =
            new LPPositionView(LPPositionManager(amm.positionManager()), lpAddress);
    }

    function _marketLiability(address targetMarket) internal view returns (uint256) {
        return
            amm.getMarketCollateral(targetMarket)
                + amm.claimableFloorLiability(targetMarket);
    }

    function testFuzz_DistinctMarketsAndTokensRemainIsolated(
        uint96 rawAmountA,
        uint96 rawAmountB
    ) public {
        uint256 amountA = bound(uint256(rawAmountA), 1e16, 20e18);
        uint256 amountB = bound(uint256(rawAmountB), 1e16, 20e18);
        (address marketA,) = _createWithToken(address(east), "Token A market");
        (address marketB,) =
            _createWithToken(address(alternate18), "Alternate Token A market");

        assertEq(vault.tokenAOf(marketA), address(east));
        assertEq(vault.tokenAOf(marketB), address(alternate18));
        assertEq(amm.tokenAOf(marketA), address(east));
        assertEq(amm.tokenAOf(marketB), address(alternate18));

        uint256 collateralBBefore = amm.getMarketCollateral(marketB);
        vm.prank(trader);
        amm.tradePositions(marketA, 1, int256(amountA), type(uint256).max);
        assertEq(
            amm.getMarketCollateral(marketB),
            collateralBBefore,
            "market A trade cannot change market B collateral"
        );

        uint256 collateralAAfter = amm.getMarketCollateral(marketA);
        vm.prank(trader);
        amm.tradePositions(marketB, 0, int256(amountB), type(uint256).max);
        assertEq(
            amm.getMarketCollateral(marketA),
            collateralAAfter,
            "market B trade cannot change market A collateral"
        );

        assertEq(amm.totalLiabilitiesOf(address(east)), _marketLiability(marketA));
        assertEq(amm.totalLiabilitiesOf(address(alternate18)), _marketLiability(marketB));
        assertGe(east.balanceOf(address(amm)), _marketLiability(marketA));
        assertGe(alternate18.balanceOf(address(amm)), _marketLiability(marketB));
    }

    function test_CreatePinsAndNormalizesSixAndEighteenDecimalTokens() public {
        (address market18, LPPositionView lp18) =
            _createWithToken(address(east), "18 decimal market");
        (address market6, LPPositionView lp6) =
            _createWithToken(address(alternate6), "6 decimal market");

        (, uint256 quotedDeposit) = PositionPricing.costBounds(B_BASE, 0, 0);
        uint256 normalizedSix =
            DecimalMath.toWad(DecimalMath.fromWadCeil(quotedDeposit, 6), 6);

        (,, address pinned18, uint8 decimals18,, uint256 deposit18) =
            marketFactory.markets(market18);
        (,, address pinned6, uint8 decimals6,, uint256 deposit6) =
            marketFactory.markets(market6);

        assertEq(pinned18, address(east));
        assertEq(decimals18, 18);
        assertEq(deposit18, quotedDeposit);
        assertEq(lp18.balanceOf(creator), quotedDeposit);
        assertEq(pinned6, address(alternate6));
        assertEq(decimals6, 6);
        assertEq(deposit6, normalizedSix);
        assertEq(lp6.balanceOf(creator), normalizedSix);
        assertEq(
            alternate6.balanceOf(address(amm)),
            DecimalMath.fromWadCeil(quotedDeposit, 6),
            "custody is the measured native receipt"
        );
        assertEq(amm.totalLiabilitiesOf(address(alternate6)), normalizedSix);
    }

    function test_VaultClaimCannotConsumeAnotherMarketsSameTokenLiability() public {
        (address marketA,) = _createWithToken(address(east), "fee market A");
        (address marketB,) = _createWithToken(address(east), "fee market B");

        vm.startPrank(trader);
        amm.tradePositions(marketA, 1, 400e18, type(uint256).max);
        amm.tradePositions(marketA, 1, 5e18, type(uint256).max);
        amm.tradePositions(marketB, 1, 400e18, type(uint256).max);
        amm.tradePositions(marketB, 1, 5e18, type(uint256).max);
        vm.stopPrank();

        uint256 liabilityA = vault.marketLiabilitiesOf(marketA, address(east));
        uint256 liabilityB = vault.marketLiabilitiesOf(marketB, address(east));
        uint256 protocolA =
            vault.accountOf(marketA, IAmmFeeVault.Bucket.OPERATOR, address(east));
        assertGt(liabilityA, 0);
        assertGt(liabilityB, 0);
        assertGt(protocolA, 0);

        uint256 totalBefore = vault.totalLiabilitiesOf(address(east));
        vm.prank(treasury);
        assertEq(vault.claimOperatorFees(marketA), protocolA);

        assertEq(
            vault.marketLiabilitiesOf(marketA, address(east)), liabilityA - protocolA
        );
        assertEq(vault.marketLiabilitiesOf(marketB, address(east)), liabilityB);
        assertEq(vault.totalLiabilitiesOf(address(east)), totalBefore - protocolA);
    }

    function test_CreateRejectsFeeOnTransferByObservedBalanceDelta() public {
        TransferTaxTokenA taxed = new TransferTaxTokenA();
        taxed.mint(creator, 10_000e18);
        taxed.setTaxEnabled(true);
        vm.prank(creator);
        taxed.approve(address(marketFactory), type(uint256).max);

        uint256 countBefore = marketFactory.getMarketCount();
        uint256 nonceBefore = marketFactory.creatorNonce(creator);
        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation2 = _marketParams(
            "taxed receipt must fail", 0, deadline, address(taxed), B_BASE, 0.5e18
        );
        vm.prank(creator);
        vm.expectRevert(MarketFactory.TransferAmountMismatch.selector);
        marketFactory.createMarket(creation2);

        assertEq(marketFactory.getMarketCount(), countBefore);
        assertEq(marketFactory.creatorNonce(creator), nonceBefore);
        assertEq(taxed.balanceOf(address(amm)), 0);
    }

    function test_TradeRejectsShortReceiptAfterTokenBehaviorChanges() public {
        TransferTaxTokenA taxed = new TransferTaxTokenA();
        taxed.mint(creator, 10_000e18);
        taxed.mint(trader, 10_000e18);
        vm.prank(creator);
        taxed.approve(address(marketFactory), type(uint256).max);
        vm.prank(trader);
        taxed.approve(address(amm), type(uint256).max);

        (address taxedMarket,) = _createWithToken(address(taxed), "later taxed market");
        taxed.setTaxEnabled(true);
        uint256 collateralBefore = amm.getMarketCollateral(taxedMarket);
        uint256 custodyBefore = taxed.balanceOf(address(amm));

        vm.prank(trader);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.tradePositions(taxedMarket, 1, 1e18, type(uint256).max);

        assertEq(amm.getMarketCollateral(taxedMarket), collateralBefore);
        assertEq(taxed.balanceOf(address(amm)), custodyBefore);
        (uint256 yesShares, uint256 noShares) = amm.getPosition(taxedMarket, trader);
        assertEq(yesShares, 0);
        assertEq(noShares, 0);
    }

    function test_AmmToVaultCallbackSweepRevertsEntireTrade() public {
        SweepOnVaultTransferTokenA hookToken = new SweepOnVaultTransferTokenA(vault);
        hookToken.mint(creator, 10_000e18);
        hookToken.mint(trader, 100_000e18);
        vm.prank(creator);
        hookToken.approve(address(marketFactory), type(uint256).max);
        vm.prank(trader);
        hookToken.approve(address(amm), type(uint256).max);

        (address hookMarket,) = _createWithToken(address(hookToken), "hook market");
        vm.prank(trader);
        amm.tradePositions(hookMarket, 1, 400e18, type(uint256).max);
        assertGt(vault.marketLiabilitiesOf(hookMarket, address(hookToken)), 0);

        (uint256 qYesBefore, uint256 qNoBefore,) = amm.getMarketState(hookMarket);
        uint256 liquidityBefore = amm.getLiquidity(hookMarket);
        uint256 collateralBefore = amm.getMarketCollateral(hookMarket);
        uint256 traderBefore = hookToken.balanceOf(trader);
        uint256 ammBefore = hookToken.balanceOf(address(amm));
        uint256 vaultBefore = hookToken.balanceOf(address(vault));
        uint256 treasuryBefore = hookToken.balanceOf(treasury);
        uint256 liabilitiesBefore = vault.totalLiabilitiesOf(address(hookToken));
        hookToken.arm();

        vm.prank(trader);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        amm.tradePositions(hookMarket, 1, 5e18, type(uint256).max);

        (uint256 qYesAfter, uint256 qNoAfter,) = amm.getMarketState(hookMarket);
        assertEq(qYesAfter, qYesBefore, "trade effects must unwind");
        assertEq(qNoAfter, qNoBefore, "trade effects must unwind");
        assertEq(amm.getLiquidity(hookMarket), liquidityBefore);
        assertEq(amm.getMarketCollateral(hookMarket), collateralBefore);
        assertEq(hookToken.balanceOf(trader), traderBefore);
        assertEq(hookToken.balanceOf(address(amm)), ammBefore);
        assertEq(hookToken.balanceOf(address(vault)), vaultBefore);
        assertEq(hookToken.balanceOf(treasury), treasuryBefore, "sweep theft must unwind");
        assertEq(vault.totalLiabilitiesOf(address(hookToken)), liabilitiesBefore);
    }

    /// Admission rejects unsupported metadata before any funding.
    function test_AdmissionRejectsZeroNonContractAndHighDecimalsToken() public {
        bytes32 ack = marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT();
        vm.expectRevert(MarketFactory.InvalidAddress.selector);
        marketFactory.setTokenAllowed(address(0), true, ack);
        vm.expectRevert(MarketFactory.InvalidAddress.selector);
        marketFactory.setTokenAllowed(address(0xE0A), true, ack);
        MutableDecimalsTokenA token = new MutableDecimalsTokenA();
        token.setDecimals(24);
        vm.expectRevert(MarketFactory.UnsupportedDecimals.selector);
        marketFactory.setTokenAllowed(address(token), true, ack);
    }

    /// The fixture administrator explicitly admits each six- and eighteen-decimal token.
    function test_CreateAcceptsExplicitlyAdmittedTokens() public {
        AlternateToken18 fresh18 = new AlternateToken18();
        AlternateToken6 fresh6 = new AlternateToken6();
        fresh18.mint(creator, 10_000e18);
        fresh6.mint(creator, 10_000e6);
        vm.startPrank(creator);
        fresh18.approve(address(marketFactory), type(uint256).max);
        fresh6.approve(address(marketFactory), type(uint256).max);
        vm.stopPrank();

        (address m18,) = _createWithToken(address(fresh18), "fresh 18-dec token");
        (address m6,) = _createWithToken(address(fresh6), "fresh 6-dec token");
        assertEq(amm.tokenAOf(m18), address(fresh18));
        assertEq(amm.tokenADecimalsOf(m18), 18);
        assertEq(vault.tokenADecimalsOf(m18), 18);
        assertEq(amm.tokenAOf(m6), address(fresh6));
        assertEq(amm.tokenADecimalsOf(m6), 6);
        assertEq(vault.tokenADecimalsOf(m6), 6);
        assertGt(fresh18.balanceOf(address(amm)), 0);
        assertGt(fresh6.balanceOf(address(amm)), 0);
    }

    function test_BookCollateralIsImmutableAndIndependentlyPinned() public view {
        assertEq(address(orderEngine.baseToken()), address(usdc));
        assertEq(bookVault.baseToken(), address(usdc));
        assertEq(bookVault.baseTokenDecimals(), 6);
    }

    function test_CreateAcceptsBookCollateralAsTokenA() public {
        usdc.mint(creator, 1000e6);
        vm.prank(creator);
        usdc.approve(address(marketFactory), type(uint256).max);
        (address created,) = _createWithToken(address(usdc), "equal collateral");
        assertEq(amm.tokenAOf(created), bookVault.baseToken());
        assertEq(vault.tokenADecimalsOf(created), 6);
    }

    function test_RevokedTokenAdmissionBlocksOnlyFutureMarkets() public {
        IMarketFactory.MarketParams memory p = _marketParams(
            "admission",
            0,
            uint64(block.timestamp + 20 days),
            address(alternate18),
            B_BASE,
            0.5e18
        );
        marketFactory.setTokenAllowed(address(alternate18), false);
        vm.prank(creator);
        vm.expectRevert(MarketFactory.TokenNotAllowed.selector);
        marketFactory.createMarket(p);
    }

    /// Existing markets keep trading and settling while further markets in the
    /// same admitted token are created.
    function test_FurtherMarketsInSameTokenWhileExistingOnesTrade() public {
        (address existingMarket, LPPositionView existingLp) =
            _createWithToken(address(alternate18), "existing market");

        vm.startPrank(trader);
        amm.tradePositions(existingMarket, 1, 400e18, type(uint256).max);
        amm.tradePositions(existingMarket, 1, 1e18, type(uint256).max);
        vm.stopPrank();

        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation3 = _marketParams(
            "further market, same token",
            0,
            deadline,
            address(alternate18),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        marketFactory.createMarket(creation3);

        vm.prank(resolver);
        adjudicator.resolve(existingMarket, 1, keccak256("existing"));
        vm.warp(block.timestamp + 1 hours + 1);
        adjudicator.settle(existingMarket);

        uint256 traderBefore = alternate18.balanceOf(trader);
        vm.prank(trader);
        uint256 payout = amm.settlePosition(existingMarket);
        assertEq(alternate18.balanceOf(trader) - traderBefore, payout);

        uint256 lpBalance = existingLp.balanceOf(creator);
        vm.prank(creator);
        uint256 floor = amm.redeemLP(existingMarket, lpBalance);
        if (floor > 0) {
            uint256 creatorBefore = alternate18.balanceOf(creator);
            vm.prank(creator);
            amm.claimFloor(existingMarket);
            assertEq(alternate18.balanceOf(creator) - creatorBefore, floor);
        }
        uint256 dividend =
            vault.lpEntitlementOf(existingMarket, creator, address(alternate18));
        if (dividend > 0) {
            uint256 creatorBefore = alternate18.balanceOf(creator);
            vm.prank(creator);
            assertEq(vault.claimLPDividend(existingMarket), dividend);
            assertEq(alternate18.balanceOf(creator) - creatorBefore, dividend);
        }
    }

    function test_SellPayoutsAreMarketScopedAndUsePinnedToken() public {
        (address marketA,) = _createWithToken(address(east), "payout market A");
        (address marketB,) = _createWithToken(address(alternate18), "payout market B");
        vm.startPrank(trader);
        amm.tradePositions(marketA, 1, 20e18, type(uint256).max);
        amm.tradePositions(marketB, 1, 20e18, type(uint256).max);
        uint256 eastBefore = east.balanceOf(trader);
        uint256 alternateBefore = alternate18.balanceOf(trader);
        uint256 collateralB = amm.getMarketCollateral(marketB);
        uint256 paidA = amm.tradePositions(marketA, 1, -10e18, 0);
        assertGt(paidA, 0);
        assertEq(east.balanceOf(trader) - eastBefore, paidA);
        assertEq(alternate18.balanceOf(trader), alternateBefore);
        assertEq(amm.getMarketCollateral(marketB), collateralB);
        uint256 paidB = amm.tradePositions(marketB, 1, -10e18, 0);
        assertGt(paidB, 0);
        assertEq(alternate18.balanceOf(trader) - alternateBefore, paidB);
        assertEq(east.balanceOf(trader) - eastBefore, paidA);
        vm.stopPrank();
    }

    function test_AdjudicatedInvalidPreservesDirectSellPayout_18Decimals() public {
        _assertInvalidDirectSellLifecycle(address(east), false);
    }

    function test_AdjudicatedInvalidPreservesDirectSellPayout_6Decimals() public {
        _assertInvalidDirectSellLifecycle(address(alternate6), false);
    }

    function test_PermissionlessInvalidPreservesDirectSellPayout_18Decimals() public {
        _assertInvalidDirectSellLifecycle(address(east), true);
    }

    function test_PermissionlessInvalidPreservesDirectSellPayout_6Decimals() public {
        _assertInvalidDirectSellLifecycle(address(alternate6), true);
    }

    function test_ClaimOrderIndependentForYesNoAndInvalid_LPNeverGetsBookToken() public {
        for (uint8 outcome = 0; outcome <= 2; outcome++) {
            _createMarket();
            _seedAmmPosition();

            vm.prank(trader);
            amm.tradePositions(market, 1, 5e18, type(uint256).max);

            vm.prank(bob);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
            vm.prank(alice);
            orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 10));
            assertGt(bookVault.totalLiabilitiesOf(address(usdc)), 0);

            _resolveAndSettle(outcome);
            uint256 snapshotId = vm.snapshotState();
            ClaimResult memory lpFirst = _runClaimOrder(true);
            assertTrue(vm.revertToState(snapshotId));
            ClaimResult memory positionsFirst = _runClaimOrder(false);

            assertEq(lpFirst.floor, positionsFirst.floor);
            assertEq(lpFirst.dividend, positionsFirst.dividend);
            assertEq(lpFirst.traderPayout, positionsFirst.traderPayout);
            assertEq(lpFirst.creatorTokenAReceived, positionsFirst.creatorTokenAReceived);
            assertEq(
                lpFirst.aliceBookTokenReceived, positionsFirst.aliceBookTokenReceived
            );
            assertEq(lpFirst.bobBookTokenReceived, positionsFirst.bobBookTokenReceived);
            assertEq(lpFirst.creatorBookTokenReceived, 0, "LP receives zero book token");
            assertEq(
                positionsFirst.creatorBookTokenReceived, 0, "LP receives zero book token"
            );
            assertEq(
                vault.lpEntitlementOf(market, creator, address(usdc)),
                0,
                "book token is structurally excluded from LP slicing"
            );
            _assertSystemSolvent();
        }
    }

    function _runClaimOrder(bool lpFirst) internal returns (ClaimResult memory result) {
        uint256 creatorTokenABefore = east.balanceOf(creator);
        uint256 creatorBookBefore = usdc.balanceOf(creator);
        uint256 traderBefore = east.balanceOf(trader);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        if (lpFirst) {
            (result.floor, result.dividend) = _claimCreatorLp();
            _settleAllPositions();
        } else {
            _settleAllPositions();
            (result.floor, result.dividend) = _claimCreatorLp();
        }

        result.traderPayout = east.balanceOf(trader) - traderBefore;
        result.creatorTokenAReceived = east.balanceOf(creator) - creatorTokenABefore;
        result.creatorBookTokenReceived = usdc.balanceOf(creator) - creatorBookBefore;
        result.aliceBookTokenReceived = usdc.balanceOf(alice) - aliceBefore;
        result.bobBookTokenReceived = usdc.balanceOf(bob) - bobBefore;
    }

    function _claimCreatorLp() internal returns (uint256 floor, uint256 dividend) {
        uint256 creatorLp = lp.balanceOf(creator);
        vm.prank(creator);
        floor = amm.redeemLP(market, creatorLp);
        if (floor > 0) {
            vm.prank(creator);
            amm.claimFloor(market);
        }

        dividend = vault.lpEntitlementOf(market, creator, address(east));
        if (dividend > 0) {
            vm.prank(creator);
            vault.claimLPDividend(market);
        }
    }

    function _settleAllPositions() internal {
        vm.prank(trader);
        amm.settlePosition(market);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        vm.prank(bob);
        orderEngine.settlePosition(market);
    }

    function _assertInvalidDirectSellLifecycle(address token, bool permissionless)
        internal
    {
        (market, lp) = _createWithToken(
            token,
            permissionless
                ? "permissionless INVALID payout"
                : "adjudicated INVALID payout"
        );
        vm.prank(trader);
        amm.tradePositions(market, 1, 20e18, type(uint256).max);
        uint256 beforeSell = IERC20(token).balanceOf(trader);
        vm.prank(trader);
        uint256 proceeds = amm.tradePositions(market, 1, -20e18, 0);
        assertGt(proceeds, 0);
        uint256 sellerPaidBalance = IERC20(token).balanceOf(trader);
        assertEq(
            sellerPaidBalance - beforeSell,
            DecimalMath.fromWad(proceeds, amm.tokenADecimalsOf(market))
        );
        uint256 terminalCollateral = amm.getMarketCollateral(market);
        uint256 liabilitiesBefore = amm.totalLiabilitiesOf(token);
        if (permissionless) {
            ITruthMarket truth = ITruthMarket(market);
            vm.warp(uint256(truth.deadline()) + truth.invalidationBuffer());
            vault.finalize(market);
            assertEq(
                uint8(truth.settlementKind()),
                uint8(ITruthMarket.SettlementKind.INVALIDATED)
            );
        } else {
            vm.prank(resolver);
            adjudicator.resolve(market, 2, keccak256("ordinary invalid"));
            vm.warp(block.timestamp + 1 hours);
            adjudicator.settle(market);
        }
        assertEq(ITruthMarket(market).winningOutcome(), 2);
        assertEq(amm.getMarketCollateral(market), terminalCollateral);
        assertEq(amm.totalLiabilitiesOf(token), liabilitiesBefore);
        assertEq(IERC20(token).balanceOf(trader), sellerPaidBalance);
        uint256 units = lp.balanceOf(creator);
        vm.prank(creator);
        assertEq(amm.redeemLP(market, units), terminalCollateral);
        vm.prank(creator);
        amm.claimFloor(market);
        assertEq(
            IERC20(token).balanceOf(trader),
            sellerPaidBalance,
            "LP cannot reclaim immediate sale proceeds"
        );
        vm.prank(trader);
        vm.expectRevert(AMMEngine.NoPosition.selector);
        amm.settlePosition(market);
        _assertMarketTokenSolvent(token);
    }

    function _assertMarketTokenSolvent(address token) internal view {
        uint256 liabilities =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertEq(amm.totalLiabilitiesOf(token), liabilities);
        assertGe(
            IERC20(token).balanceOf(address(amm)),
            DecimalMath.fromWadCeil(liabilities, amm.tokenADecimalsOf(market))
        );
    }

    /// The 6-decimal half. `claimAvailable` returns
    /// `floorPaid` in WAD and `feesPaid` in native units, so the naive sum is wrong
    /// by 10**(18 - decimals). At 18 decimals the two coincide and the bug is
    /// invisible; this is the configuration where it bites.
    function test_ClaimAvailableReturnUnitsOnSixDecimalTokenA() public {
        (address market6, LPPositionView lp6) =
            _createWithToken(address(alternate6), "6 decimal claim units");

        // Give the market some fee-generating flow, then settle it.
        vm.startPrank(trader);
        alternate6.approve(address(amm), type(uint256).max);
        amm.tradePositions(market6, 1, int256(5e18), type(uint256).max);
        vm.stopPrank();

        ITruthMarket tm6 = ITruthMarket(market6);
        vm.warp(uint256(tm6.deadline()) + uint256(tm6.invalidationBuffer()) + 1);
        tm6.invalidate(); // permissionless once the buffer has passed
        assertTrue(tm6.isSettled());

        uint256 id6 = lp6.id();
        uint256 units = lp6.balanceOf(creator);
        uint256 scale = 10 ** (18 - alternate6.decimals());
        assertEq(scale, 1e12, "6-decimal Token A");

        uint256 before = alternate6.balanceOf(creator);
        vm.prank(creator);
        (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market6, id6, units);
        uint256 moved = alternate6.balanceOf(creator) - before;

        // The documented relationship.
        assertEq(floorPaid / scale + feesPaid, moved, "documented unit relationship");
        // And the reason it is documented: summing the fields raw is not the total.
        assertTrue(floorPaid + feesPaid != moved, "raw sum is wrong at 6 decimals");
        assertTrue(redeemedWad != units, "redeemedWad is residual, not burned units");
        assertTrue(redeemedWad != moved, "redeemedWad is not the native cash transfer");
    }
}

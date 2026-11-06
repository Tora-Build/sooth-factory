// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";

contract DualTokenE2ETest is DualTokenBase {
    // ============================================
    // Future-start creation atomically registers both venues
    // ============================================

    function test_CreateMarket_FutureStartRegistersBothVenuesImmediately() public {
        IMarketFactory.MarketParams memory p = _marketParams(
            "future-start market",
            uint64(block.timestamp + 5 days),
            uint64(block.timestamp + 10 days),
            address(east),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (address futureMarket,) = marketFactory.createMarket(p);
        assertTrue(orderEngine.isMarketRegistered(futureMarket));
        assertTrue(amm.tokenAOf(futureMarket) == address(east));
        assertFalse(TruthMarket(futureMarket).isTradingOpen());
        assertTrue(TruthMarket(futureMarket).isLiquidityOpen());
    }

    // ============================================
    // The full dual-token lifecycle
    // ============================================

    function test_FullLifecycle_DualToken() public {
        _createMarket();

        // ── 1. Creation state ──
        (, uint256 depositWad) = PositionPricing.costBounds(B_BASE, 0, 0);
        assertEq(lp.balanceOf(creator), depositWad, "bootstrap LP = deposit");
        assertTrue(orderEngine.isMarketRegistered(market), "book registered atomically");
        assertTrue(orderEngine.registeredMarkets(market), "SoothBook registered");

        // ── 2. AMM trading: 1% fee, 50% grows b, 50% enters the vault ──
        uint256 liquidity0 = amm.getLiquidity(market);
        (, uint256 ammFee,,) = amm.getPositionQuote(market, 1, 400e18);
        vm.prank(trader);
        amm.tradePositions(market, 1, 400e18, type(uint256).max);
        assertEq(
            amm.getLiquidity(market) - liquidity0,
            (ammFee * 5000) / 10_000,
            "b grows by CAPITAL share"
        );
        assertEq(lp.balanceOf(trader), 0, "ordinary trades never mint LP");
        uint256 ammRevenue = ammFee - ((ammFee * 5000) / 10_000);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(east)),
            (ammRevenue * 3000) / 5000,
            "LP gets 30% of original AMM fee"
        );
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(east)),
            (ammRevenue * 1000) / 5000,
            "adjudicator gets 10% of original AMM fee"
        );

        // ── 3. Book trading in USDC: bob rests NO@400, alice takes YES@600 ──
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256)); // resting maker
        uint256 vaultUsdc0 = usdc.balanceOf(address(bookVault));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 10)); // crossing taker

        uint256 bookFee = usdc.balanceOf(address(bookVault)) - vaultUsdc0;
        assertGt(bookFee, 0, "book taker fee landed in the vault (USDC)");
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(usdc)),
            0,
            "book value cannot enter LP"
        );
        assertEq(
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc)),
            bookFee - ((bookFee * 1000) / 10_000),
            "protocol receives the remaining book share"
        );
        (uint256 aliceYes,) = orderEngine.getPosition(market, alice);
        assertEq(aliceYes, 100e18, "alice holds 100 YES on the book");

        // ── 4. Resolution: YES wins (resolver → veto window → settle) ──
        vm.prank(resolver);
        adjudicator.resolve(market, 1, keccak256("rain"));
        vm.warp(block.timestamp + 1 hours + 1); // veto window passes
        adjudicator.settle(market);
        assertTrue(TruthMarket(market).isSettled());

        // ── 5. Both venues settle in their OWN tokens ──
        uint256 aliceUsdc0 = usdc.balanceOf(alice);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        assertEq(
            usdc.balanceOf(alice) - aliceUsdc0,
            100e6,
            "book YES pays 1 USDC-unit per share"
        );

        uint256 traderEast0 = east.balanceOf(trader);
        vm.prank(trader);
        uint256 ammPayout = amm.settlePosition(market);
        assertEq(ammPayout, 400e18, "AMM YES pays 1 EAST per share (WAD)");
        assertEq(east.balanceOf(trader) - traderEast0, 400e18);

        // ── 6. redeemLP: state-only burn, 3 recorded claims, independent pulls ──
        uint256 creatorLP = lp.balanceOf(creator);
        vm.prank(creator);
        uint256 floorShare = amm.redeemLP(market, creatorLP);

        uint256 usdcDividend = vault.lpEntitlementOf(market, creator, address(usdc));
        assertEq(usdcDividend, 0, "LP has no book token entitlement");

        if (floorShare > 0) {
            vm.prank(creator);
            amm.claimFloor(market);
        }
        if (vault.lpEntitlementOf(market, creator, address(east)) > 0) {
            vm.prank(creator);
            vault.claimLPDividend(market);
        }
        assertEq(usdc.balanceOf(creator), 0, "LP receives zero book token");

        // ── 7. System-wide solvency at rest ──
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
        assertEq(
            usdc.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market),
            "OrderEngine holds exactly its backing (no stray fee custody)"
        );
    }
}

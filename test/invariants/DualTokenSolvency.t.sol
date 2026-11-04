// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import "forge-std/Test.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {ManualAdjudicator} from "src/adjudicators/ManualAdjudicator.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev Random-op driver over the REAL dual-token stack. Ops are bounded to
///      plausible ranges; illegal-state attempts are tolerated via try/catch
///      (they are the adversarial suite's job — here we only accumulate state).
contract DualTokenHandler is Test {
    East18E public east;
    MockUSDC public usdc;
    AMMEngine public amm;
    OrderEngine public orderEngine;
    AmmFeeVault public vault;
    ManualAdjudicator public adjudicator;
    LPPositionView public lp;
    address public market;
    address public resolver;
    address public constant guardian = address(0x640001);

    address[3] public actors;
    bool public settled;

    constructor(
        East18E _east,
        MockUSDC _usdc,
        AMMEngine _amm,
        OrderEngine _oe,
        AmmFeeVault _vault,
        ManualAdjudicator _adj,
        LPPositionView _lp,
        address _market,
        address _resolver
    ) {
        east = _east;
        usdc = _usdc;
        amm = _amm;
        orderEngine = _oe;
        vault = _vault;
        adjudicator = _adj;
        lp = _lp;
        market = _market;
        resolver = _resolver;

        actors = [address(0xAA01), address(0xAA02), address(0xAA03)];
        for (uint256 i = 0; i < 3; i++) {
            east.mint(actors[i], 1_000_000e18);
            usdc.mint(actors[i], 10_000_000e6);
            vm.startPrank(actors[i]);
            east.approve(address(amm), type(uint256).max);
            usdc.approve(address(orderEngine), type(uint256).max);
            usdc.approve(address(orderEngine), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function ammBuy(uint256 seed, uint256 amount, bool yes) external {
        amount = bound(amount, 1e16, 150e18);
        vm.prank(_actor(seed));
        try amm.tradePositions(market, yes ? 1 : 0, int256(amount), type(uint256).max) {}
            catch {}
    }

    function ammSell(uint256 seed, uint256 amount, bool yes) external {
        address actor = _actor(seed);
        (uint256 y, uint256 no) = amm.getPosition(market, actor);
        uint256 held = yes ? y : no;
        if (held < 1e15) return;
        amount = bound(amount, 1e15, held);
        vm.prank(actor);
        try amm.tradePositions(market, yes ? 1 : 0, -int256(amount), 0) {} catch {}
    }

    /// Audit round 2 (2026-10-08) narrowed what this action establishes: it used to
    /// hard-code `takerTick = 1000 - makerTick` (an exact cross), bound `makerTick`
    /// to [200, 800], bound `shares` at or above one whole share, and always put the
    /// maker on NO and the taker on YES. `invariant_NetSumsToZero` therefore held
    /// only over whole-share exact crosses in one direction, never at the ends of
    /// the ladder, never on a partial fill and never after a cancel — while
    /// `audit/EXTERNAL-AUDIT-PACKAGE.md` cited it as a general property. The bounds
    /// below are the property's real domain: the whole ladder, both taking
    /// directions, sub-share sizes, crossing and non-crossing limits, partial fills.
    function bookMakeTake(
        uint256 seed,
        uint256 shares,
        uint256 tickSeed,
        uint256 takerSeed,
        bool takerBuysYes
    ) external {
        uint16 makerTick = uint16(bound(tickSeed, 1, 999));
        // Independent of the maker's tick, so the limit may cross deeply, cross
        // barely, or not cross at all and rest on the opposite side instead.
        uint16 takerTick = uint16(bound(takerSeed, 1, 999));
        shares = bound(shares, 1, 200_000_000) * 1e12;
        // Partial fills: the taker's size is independent of the maker's.
        uint256 takerShares = bound(shares / 1e12 * 7 + 1, 1, 200_000_000) * 1e12;
        address makerA = _actor(seed);
        address takerA = _actor(seed % 3 + 1);

        vm.prank(makerA);
        if (takerBuysYes) {
            try orderEngine.placeOrder(
                market, BookTestOrders.buy(0, makerTick, uint128(shares), 256)
            ) {}
            catch {
                return;
            }
            vm.prank(takerA);
            try orderEngine.placeOrder(
                market, BookTestOrders.buy(1, takerTick, uint128(takerShares), 5)
            ) {}
                catch {}
        } else {
            try orderEngine.placeOrder(
                market, BookTestOrders.buy(1, makerTick, uint128(shares), 256)
            ) {}
            catch {
                return;
            }
            vm.prank(takerA);
            try orderEngine.placeOrder(
                market, BookTestOrders.buy(0, takerTick, uint128(takerShares), 5)
            ) {}
                catch {}
        }
    }

    function bookSplit(uint256 seed, uint256 raw) external {
        uint256 q = bound(raw, 1, 50_000_000) * 1e12;
        vm.prank(_actor(seed));
        try orderEngine.split(market, q, q / 1e12, uint64(block.timestamp + 1)) {}
            catch {}
    }

    function bookMerge(uint256 seed, uint256 raw) external {
        address actor = _actor(seed);
        (uint256 y, uint256 n, uint256 yr, uint256 nr,) =
            orderEngine.getInventory(market, actor);
        uint256 free = y - yr < n - nr ? y - yr : n - nr;
        if (free == 0) return;
        uint256 q = bound(raw, 1, free / 1e12) * 1e12;
        vm.prank(actor);
        try orderEngine.merge(market, q, q / 1e12, uint64(block.timestamp + 1)) {}
            catch {}
    }

    function bookSell(uint256 seed, uint256 raw, uint16 price, bool yes) external {
        address actor = _actor(seed);
        (uint256 y, uint256 n, uint256 yr, uint256 nr,) =
            orderEngine.getInventory(market, actor);
        uint256 free = yes ? y - yr : n - nr;
        if (free == 0) return;
        uint128 q = uint128(bound(raw, 1, free / 1e12) * 1e12);
        uint16 tick = uint16(bound(price, 1, 999));
        vm.prank(actor);
        try orderEngine.placeOrder(
            market, BookTestOrders.sell(yes ? 1 : 0, tick, q, 16)
        ) {}
            catch {}
    }

    /// Cancellation was absent from this handler's action set entirely, so no
    /// invariant here had ever been evaluated in a state reached through a cancel.
    function bookCancel(uint256 seed, uint256 tickSeed, bool askSide) external {
        uint16 tick = uint16(bound(tickSeed, 1, 999));
        vm.prank(_actor(seed));
        try orderEngine.cancel(market, askSide ? 1 : 0, tick) {} catch {}
    }

    function advanceTime(uint256, uint256 warpHours) external {
        vm.warp(block.timestamp + bound(warpHours, 0, 3) * 1 hours);
    }

    /// @dev Resolve/veto cycle: a frozen fixture guardian sends the veto. The
    ///      book stays registered. A veto leaves trading closed. The transition
    ///      itself moves no custody.
    function resolveVetoCycle(uint256 seed, bool yesWins) external {
        if (settled) return;
        vm.prank(resolver);
        try adjudicator.resolve(market, yesWins ? 1 : 0, keccak256("cycle")) {}
        catch {
            return;
        }
        vm.prank(guardian);
        try adjudicator.dispute(market) {} catch {}
        seed;
    }

    function settleAndDrain(uint256 seed, bool yesWins) external {
        if (settled) return;
        settled = true;
        vm.prank(resolver);
        try adjudicator.resolve(market, yesWins ? 1 : 0, keccak256("inv")) {}
        catch {
            settled = false;
            return;
        }
        vm.warp(block.timestamp + 1 hours + 1);
        try adjudicator.settle(market) {}
        catch {
            return;
        }
        // Everyone settles + a partial LP redemption + pulls
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(actors[i]);
            try amm.settlePosition(market) {} catch {}
            vm.prank(actors[i]);
            try orderEngine.settlePosition(market) {} catch {}
        }
        address lpHolder = address(0xC4EA70); // creator from the base fixture
        uint256 bal = lp.balanceOf(lpHolder);
        if (bal > 1) {
            vm.startPrank(lpHolder);
            try amm.redeemLP(market, bal / 2) {
                try amm.claimFloor(market) {} catch {}
                try vault.claimLPDividend(market) {} catch {}
            } catch {}
            vm.stopPrank();
        }
        seed; // silence
    }
}

/**
 * @title Dual-token system solvency — stateful invariant campaign
 * @notice Replaces the quarantined single-token SoothBookSolvency invariants:
 *         random interleaved AMM trades, book fills, immediate payouts, and (once)
 *         settlement + partial LP redemption over the REAL stack, asserting
 *         after every sequence that each custodian covers its liabilities in
 *         its own token.
 */
contract DualTokenSolvencyInvariant is DualTokenBase {
    DualTokenHandler handler;

    function setUp() public override {
        super.setUp();
        adjudicator.approveGuardian(address(0x640001));
        _createMarket();
        _seedAmmPosition();

        handler = new DualTokenHandler(
            east, usdc, amm, orderEngine, vault, adjudicator, lp, market, resolver
        );
        targetContract(address(handler));
    }

    function invariant_BookRegistrationAndMarkerMonotonic() public view {
        assertTrue(orderEngine.isMarketRegistered(market), "book stays registered");
        assertTrue(orderEngine.isMarketRegistered(market));
        TruthMarket tm = TruthMarket(market);
        if (tm.resolutionAttempted()) {
            assertFalse(tm.isLiquidityOpen(), "an open proposal keeps liquidity closed");
        }
        assertEq(
            tm.isTradingOpen(),
            uint8(tm.state()) == uint8(TruthMarket.MarketState.LIVE)
                && !tm.resolutionAttempted() && block.timestamp >= tm.startTime()
                && block.timestamp < tm.deadline(),
            "isTradingOpen equals its definition"
        );
    }

    function invariant_VaultCoversLiabilities_BothTokens() public view {
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
        assertEq(
            vault.marketLiabilitiesOf(market, address(east)),
            vault.totalLiabilitiesOf(address(east)),
            "EAST liability stays market scoped"
        );
        assertEq(
            bookVault.marketLiabilitiesOf(market, address(usdc)),
            bookVault.totalLiabilitiesOf(address(usdc)),
            "USDG liability stays market scoped"
        );
    }

    function invariant_AmmWidenedSolvency() public view {
        uint256 marketLiability =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertGe(
            east.balanceOf(address(amm)),
            marketLiability,
            "AMM balance must cover collateral + floor entitlements"
        );
        assertEq(
            amm.totalLiabilitiesOf(address(east)),
            marketLiability,
            "token aggregate must equal its market-scoped liabilities"
        );
    }

    function invariant_GrossOwnershipSuppliesAndReservations() public view {
        uint256 ys;
        uint256 ns;
        uint256 cash;
        for (uint256 i; i < 3; i++) {
            address actor = handler.actors(i);
            (uint256 y, uint256 n, uint256 yr, uint256 nr, uint256 cr) =
                orderEngine.getInventory(market, actor);
            assertLe(yr, y);
            assertLe(nr, n);
            ys += y;
            ns += n;
            cash += cr;
            assertEq(orderEngine.getNet(market, actor), int256(y) - int256(n));
        }
        (uint256 supplyY, uint256 supplyN) = orderEngine.getSupplies(market);
        assertEq(ys, supplyY);
        assertEq(ns, supplyN);
        assertEq(cash, orderEngine.getOrderCash(market));
        if (!TruthMarket(market).isSettled()) {
            assertEq(ys, ns);
            assertEq(orderEngine.getShareBacking(market), ys / 1e12);
        }
    }

    function invariant_OrderEngineCoversBacking() public view {
        assertGe(
            usdc.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market) + orderEngine.totalDeferred(),
            "OrderEngine balance must cover its backing"
        );
    }
}

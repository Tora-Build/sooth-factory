// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";

/// @notice Creation admission never freezes existing venue exposure or exits.
contract PauseScopeTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    // ── stopped ──────────────────────────────────────────────────────────────

    function test_creationPauseStopsOnlyNewMarkets() public {
        IMarketFactory.MarketParams memory p = _marketParams(
            "while paused",
            0,
            uint64(block.timestamp + 20 days),
            address(east),
            B_BASE,
            0.5e18
        );
        marketFactory.setCreationPaused(true);
        vm.prank(trader);
        amm.tradePositions(market, 1, int256(1e18), type(uint256).max);
        east.mint(creator, 10e18);
        vm.prank(creator);
        east.approve(address(amm), 10e18);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 1e18);
        vm.prank(creator);
        amm.increaseLiquidity(market, 1e18, limits);
        vm.prank(creator);
        vm.expectRevert(MarketFactory.CreationClosed.selector);
        marketFactory.createMarket(p);
    }

    // ── deliberately not stopped ─────────────────────────────────────────────

    /// The book keeps trading. There is no switch that halts it; an operator facing
    /// a book-side incident has to stop routing orders, not pause the protocol.
    /// @dev Opening fills, inventory-backed sales, complementary sells that merge
    ///      complete sets, and cancellations all continue during a creation pause.
    function test_pauseDoesNotStopTheBook() public {
        marketFactory.setCreationPaused(true);

        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        assertEq(orderEngine.getNet(market, alice), 10e18, "the book opened while paused");

        // Alice reserves 4 YES at 0.70; Bob sells 4 NO at 0.30 into that ask.
        // Their complementary sells burn complete sets and pay both parties.
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 700, 4e18, 256));
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(0, 300, 4e18, 256));
        assertGt(
            usdc.balanceOf(alice), aliceBefore, "a closing maker is paid while paused"
        );
        assertEq(orderEngine.getNet(market, alice), 6e18);
        assertEq(orderEngine.getNet(market, bob), -6e18);

        // A resting order can still be cancelled for its refund.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 100, 10e18, 256));
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        orderEngine.cancel(market, 1, 900);
        assertGt(usdc.balanceOf(bob), bobBefore, "cancel refunds while paused");
    }

    /// The book's settlement path, like the AMM's, ignores pause.
    function test_pauseDoesNotTrapBookSettlement() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        _resolveAndSettle(1);

        marketFactory.setCreationPaused(true);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        assertEq(usdc.balanceOf(alice) - before, 10e6, "the winner is paid in full");
    }

    /// Unwinds and claims stay open. A pause that froze these would trap funds —
    /// a worse failure than the one pausing reaches for.
    function test_pauseDoesNotTrapFunds() public {
        _seedAmmPosition();
        uint256 id = marketFactory.getLPToken(market);
        _resolveAndSettle(1);

        marketFactory.setCreationPaused(true);

        // LP proceeds, in full, while paused. Read the balance BEFORE pranking:
        // an external call consumes the prank.
        uint256 units = _manager().balanceOf(creator, id);
        uint256 before = east.balanceOf(creator);
        vm.prank(creator);
        amm.claimAvailable(market, id, units);
        assertGt(east.balanceOf(creator), before, "LP could still be paid");

        // And a trader's settled position.
        vm.prank(trader);
        amm.settlePosition(market);
    }

    function _manager() internal view returns (LPPositionManagerLike) {
        return LPPositionManagerLike(amm.positionManager());
    }
}

interface LPPositionManagerLike {
    function balanceOf(address owner, uint256 id) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";

/// @notice Blind audit 2026-09-10: the book taker fee was computed from the taker's
///         LIMIT tick rather than the price the fill executed at. The principal
///         surplus is refunded in `_settleEscrowAndSurplus`, but the fee on that
///         surplus had already been pushed to the vault, so nothing corrected it.
///
///         The suite never caught this because every book test — and the solvency
///         handler, which hard-codes `takerTick = 1000 - makerTick` — used an exact
///         cross, where the limit and the execution price coincide. These tests use
///         crossing fills where they differ.
contract BookFeeBasisTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    /// A taker sweeping three levels must pay the fee on what actually executed.
    /// bookFeeBps is 100 (1%), the book token has 6 decimals.
    function test_feeIsChargedOnTheExecutedPriceNotTheLimit() public {
        // Three resting NO bids => YES asks at 0.10, 0.30, 0.50.
        vm.startPrank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 900, 10e18, 256));
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 700, 10e18, 256));
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, 10e18, 256));
        vm.stopPrank();

        uint256 vaultBefore = usdc.balanceOf(address(bookVault));
        uint256 aliceBefore = usdc.balanceOf(alice);

        // Sweep all three. The limit must be wide to reach the deepest level.
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 999, 30e18, 256));

        uint256 fee = usdc.balanceOf(address(bookVault)) - vaultBefore;
        uint256 spent = aliceBefore - usdc.balanceOf(alice);

        // min(p, 1-p) at 0.1 / 0.3 / 0.5 is the executed price itself on every
        // level here, so the basis is still 10*0.1 + 10*0.3 + 10*0.5 = 9.000000 and
        // the fee is 0.090000. The old basis charged 1% of the LIMIT notional
        // 29.970000 = 0.299700 — 3.33x.
        assertEq(fee, 90_000, "fee is 1% of the executed notional");
        assertEq(spent, 9e6 + 90_000, "principal at execution price, plus that fee");
    }

    /// The degenerate case the audit flagged: the fee used to exceed the value of
    /// the whole trade by an order of magnitude.
    function test_feeCannotExceedTheValueOfTheTrade() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 999, 100e18, 256));

        uint256 vaultBefore = usdc.balanceOf(address(bookVault));
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 999, 100e18, 256));

        uint256 fee = usdc.balanceOf(address(bookVault)) - vaultBefore;
        uint256 spent = aliceBefore - usdc.balanceOf(alice);

        // Executed notional is 100 * 0.001 = 0.100000 USDC; 1% of that is 0.001000.
        // The old basis charged 0.999000 — roughly ten times the trade itself.
        assertEq(fee, 1000, "fee is 1% of 0.1 USDC");
        assertEq(spent, 0.1e6 + 1000);
        assertLt(fee, spent - fee, "a fee can never exceed the trade it taxes");
    }

    /// The widest separation on the ladder, and the test that discriminates the
    /// basis most sharply. At YES 0.80 the taker's own leg is 0.80 while
    /// `min(p, 1 - p)` is 0.20 — a 4x gap — so the two rules cannot both pass.
    ///
    /// Audit round 2 (2026-10-08) filed that this file could not discriminate the
    /// shipped basis at all, because the first two tests fill at ticks where the two
    /// rules coincide. Half right: `test_exactCrossIsUnaffected` fills at YES 0.60
    /// and does kill the old rule — reverting the basis in `_collectTakerLegAndFee` (now `_settleTaker`)
    /// to `costWad` makes it fail 60000 != 40000, which was run. It is the only one
    /// that does, and at a 1.5x margin, so this widens it.
    function test_theBasisIsNotTheTakersLegAtTheWideEndOfTheLadder() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 200, 10e18, 256)); // rests: ASK at YES 800

        uint256 vaultBefore = usdc.balanceOf(address(bookVault));
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 900, 10e18, 256)); // crossing limit, fills at 800

        uint256 fee = usdc.balanceOf(address(bookVault)) - vaultBefore;
        // min(0.8, 0.2) x 10 = 2.000000, so 1% is 0.020000. The taker's leg costs
        // 8.000000, on which the pre-amendment rule charged 0.080000 — 4x this.
        assertEq(fee, 20_000, "1% of min(p, 1-p) x amount, not of the taker's leg");
        assertEq(
            usdc.balanceOf(alice),
            aliceBefore - 8e6 - fee,
            "the taker still pays its own 0.80 leg as principal"
        );
    }

    /// Complement invariance at the same fill: the other side of a trade owes the
    /// same fee, so a taker cannot lower it by choosing which leg to buy. Only the
    /// `min` form has this property; the leg basis charges 4x more on one side.
    function test_bothSidesOfTheSameFillOweTheSameFee() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 800, 10e18, 256)); // rests: BID at YES 800

        uint256 vaultBefore = usdc.balanceOf(address(bookVault));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 200, 10e18, 256)); // takes it; bob's leg costs 0.20

        // Bob's leg is 2.000000 and alice's was 8.000000, but the fee is the same
        // 0.020000 either way, because the basis is min(p, 1-p) for both.
        assertEq(usdc.balanceOf(address(bookVault)) - vaultBefore, 20_000);
    }

    /// An exact cross is unchanged — this is why the old suite passed.
    function test_exactCrossIsUnaffected() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));

        uint256 vaultBefore = usdc.balanceOf(address(bookVault));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));

        // Executed and limit price coincide at 0.6. The fee basis is
        // min(0.6, 0.4) x 10 = 4.000000, so 1% is 0.040000 (ADR-0008 amendment).
        assertEq(usdc.balanceOf(address(bookVault)) - vaultBefore, 40_000);
    }
}

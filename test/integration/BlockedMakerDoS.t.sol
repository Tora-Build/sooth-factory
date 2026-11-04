// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase, East18E, IBookFeeVault} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BlocklistToken} from "../mocks/HostileTokens.sol";
import {OrderEngine} from "src/OrderEngine.sol";

/// @notice A maker who cannot receive the book token no longer blocks anyone.
/// @dev History. Audit 2026-09-21, Tier 2, test 7: on the single axis the engine pays
///      out to any party a fill closes, from inside the matching loop, and a transfer
///      that reverted took the taker's whole call with it. The 2026-10-08 round
///      established the radius: a bid taker walks the ask ladder UP from the lowest
///      occupied ask, so one closing ask at YES tick 1 whose maker had been frozen by
///      the token's issuer reverted every `buyYes` in the market, permanently, for a
///      2-base-unit outlay — and nobody could cancel it, because the refund was a
///      transfer to the frozen maker too. These tests pinned that.
///
///      The remedy (2026-10-08, owner decision): a payout the token refuses is
///      credited to the recipient and claimable by that address only
///      (`OrderEngine._pushOrDefer`, `claimDeferred`). The fill goes through, the queue
///      behind is reachable, the frozen maker can cancel, and the freeze still holds —
///      the claim pays the caller and nobody else, so it cannot be used to route funds
///      around an issuer's block. `BlocklistToken` blocks both sending and receiving,
///      as USDC's blacklist does; read before relying on it.
contract BlockedMakerDoSTest is DualTokenBase {
    BlocklistToken internal book;

    function setUp() public override {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        book = new BlocklistToken();
        _deployStack(address(book));
        _fundAndApprove();

        address[3] memory holders = [alice, bob, trader];
        for (uint256 i; i < holders.length; ++i) {
            book.mint(holders[i], 1_000_000e6);
            vm.prank(holders[i]);
            book.approve(address(orderEngine), type(uint256).max);
        }
        _createMarket();
    }

    /// Custody covers what the engine owes: backing, plus payouts held for anyone it
    /// could not pay. `_assertSystemSolvent` reads only the vault and the AMM.
    function _assertBookCustody() internal view {
        assertGe(
            book.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market) + orderEngine.totalDeferred(),
            "book custody covers backing plus deferred payouts"
        );
    }

    /// Alice long 20, resting a CLOSING ask for 10 at YES 700; trader the same,
    /// queued behind her.
    function _twoClosingAsksAt700() internal {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 30e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 20e18, 256));
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 700, 10e18, 256)); // ASK at YES 700
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 700, 10e18, 256)); // ASK at YES 700, behind her
    }

    function test_aBlockedClosingMakerIsFilledAndPaidLater() public {
        _twoClosingAsksAt700();
        book.setBlocked(alice, true);
        uint256 traderBefore = book.balanceOf(trader);

        // Bob takes both: alice's order first, then trader's, behind her.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 20e18, 256));

        assertEq(orderEngine.getNet(market, alice), 10e18, "alice closed 10");
        assertEq(orderEngine.getNet(market, trader), 0, "the maker behind was reached");
        assertGt(book.balanceOf(trader), traderBefore, "and paid directly");
        // Alice is owed her 0.70 sale price times 10 shares.
        assertEq(orderEngine.deferredOf(alice), 7e6, "her payout is held for her");
        assertEq(orderEngine.totalDeferred(), 7e6);
        _assertBookCustody();
        _assertSystemSolvent();
    }

    /// The wedge that used to deny every bid in the market. Placed exactly as before;
    /// now every bid trades and the frozen maker's payout waits for her.
    function test_aWedgeAtTheLowestTickNoLongerDeniesAnything() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 20e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 20e18, 256)); // alice long 20
        uint128 dust = uint128(orderEngine.getMinRestingOrder(1));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 1, dust, 256)); // closing ASK at YES 1
        book.setBlocked(alice, true);

        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256)); // honest ASK at YES 600

        // Every limit that used to revert now fills, the wedge first.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        assertEq(orderEngine.getNet(market, alice), 20e18 - int256(uint256(dust)));
        assertGt(orderEngine.deferredOf(alice), 0, "the wedge's payout is held");

        // A bid can rest again.
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 300, 10e18, 256));
        (, uint256 bids) = orderEngine.getOrdersAtTick(market, 0, 300);
        assertEq(bids, 1, "a bid rests");
        _assertBookCustody();
        _assertSystemSolvent();
    }

    /// The frozen maker can clear her own order: the refund is held, not pushed.
    function test_aFrozenMakerCanCancel() public {
        _twoClosingAsksAt700();
        book.setBlocked(alice, true);
        vm.prank(alice);
        orderEngine.cancel(market, 1, 700);
        // A SELL cancellation releases reserved shares without transferring cash.
        assertEq(
            orderEngine.deferredOf(alice), 0, "inventory cancel needs no cash payout"
        );
        (, uint256 count) = orderEngine.getOrdersAtTick(market, 1, 700);
        assertEq(count, 1, "only trader's order is left");
        _assertBookCustody();
    }

    /// The claim pays the caller only, and only when the token lets it. A freeze is
    /// the issuer's decision; the engine must not become a way around it.
    function test_theClaimRespectsTheFreeze() public {
        _twoClosingAsksAt700();
        book.setBlocked(alice, true);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 10e18, 256));
        uint256 owed = orderEngine.deferredOf(alice);
        assertGt(owed, 0);

        // Still frozen: the claim reverts and the credit is untouched.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, alice));
        orderEngine.claimDeferred();
        assertEq(orderEngine.deferredOf(alice), owed);

        // Nobody else can draw it: there is no recipient argument, and a stranger
        // has nothing of their own to claim.
        vm.prank(trader);
        vm.expectRevert(OrderEngine.NothingDeferred.selector);
        orderEngine.claimDeferred();

        // Unfrozen, she claims exactly what she was owed, once.
        book.setBlocked(alice, false);
        uint256 before = book.balanceOf(alice);
        vm.prank(alice);
        assertEq(orderEngine.claimDeferred(), owed);
        assertEq(book.balanceOf(alice) - before, owed);
        assertEq(orderEngine.totalDeferred(), 0);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.NothingDeferred.selector);
        orderEngine.claimDeferred();
        _assertBookCustody();
        _assertSystemSolvent();
    }

    /// Deferral is for a recipient who cannot receive, never for an engine that
    /// cannot pay. With custody drained below what is owed, the payout reverts
    /// instead of turning an accounting failure into a credit nobody can redeem.
    function test_aShortfallIsNotDeferred() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 300, 10e18, 256));
        book.setBlocked(alice, true);
        deal(address(book), address(orderEngine), 1);
        vm.prank(alice);
        vm.expectRevert(OrderEngine.PayoutFailed.selector);
        orderEngine.cancel(market, 1, 700);
    }

    /// Random fills, cancels and freezes. Whatever happens, custody covers backing
    /// plus every deferred payout, the per-account credits sum to the total, and every
    /// credit can be claimed in full once its holder is unfrozen. Coverage measured
    /// when written: 19 of 40 seeds produce at least one deferral; before the seeded
    /// prelude and the tight price set it was 2 of 40, which tested almost nothing.
    function testFuzz_deferralNeverBreaksCustody(uint256 seed) public {
        address[3] memory who = [alice, bob, trader];
        // Every run starts with closing orders resting from two holders, so a freeze
        // followed by a crossing bid — the case under test — is a few steps away
        // rather than a rare alignment of random actions.
        _twoClosingAsksAt700();
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 500, 20e18, 256)); // more ASKs at YES 500 for the bids
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address actor = who[r % 3];
            // Three prices close together, so bids and asks actually cross and
            // closing makers actually get filled. A wide random range almost never
            // crossed: measured, 2 of 40 seeds produced a single deferral.
            uint16 tick = uint16(500 + 100 * ((r >> 8) % 3)); // YES 500, 600, 700
            uint128 size = uint128((1e18 + (r >> 24) % 20e18) / 1e12 * 1e12);
            uint256 action = (r >> 96) % 5;
            if (action == 0) {
                book.setBlocked(who[(r >> 128) % 3], ((r >> 136) % 4) != 0);
                continue;
            }
            vm.prank(actor);
            if (action == 1) {
                try orderEngine.placeOrder(
                    market, BookTestOrders.buy(1, tick, size, 256)
                ) {}
                    catch {}
            } else if (action == 2) {
                try orderEngine.placeOrder(
                    market, BookTestOrders.buy(0, tick, size, 256)
                ) {}
                    catch {}
            } else if (action == 3) {
                try orderEngine.cancel(market, uint8((r >> 144) & 1), tick) {} catch {}
            } else {
                try orderEngine.claimDeferred() {} catch {}
            }
            _assertBookCustody();
        }
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += orderEngine.deferredOf(who[i]);
        }
        assertEq(sum, orderEngine.totalDeferred(), "credits sum to the total");
        for (uint256 i; i < 3; ++i) {
            book.setBlocked(who[i], false);
            uint256 owed = orderEngine.deferredOf(who[i]);
            if (owed == 0) continue;
            uint256 before = book.balanceOf(who[i]);
            vm.prank(who[i]);
            orderEngine.claimDeferred();
            assertEq(book.balanceOf(who[i]) - before, owed, "claimed in full");
        }
        assertEq(orderEngine.totalDeferred(), 0);
        _assertBookCustody();
    }

    /// The TAKER is not deferred: a frozen taker's own trade reverts on their own
    /// account, which harms nobody else. Only third-party payouts are held.
    function test_aFrozenTakerStillReverts() public {
        _twoClosingAsksAt700();
        book.setBlocked(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, bob));
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 700, 10e18, 256));
    }

    /// An opening maker was never exposed: nothing is pushed to them on a fill.
    function test_anOpeningMakerBeingBlockedNeverMattered() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 20e18, 256));
        book.setBlocked(alice, true);
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 20e18, 256));
        assertEq(orderEngine.getNet(market, alice), -20e18);
        assertEq(orderEngine.deferredOf(alice), 0, "nothing was owed to her");
        _assertBookCustody();
    }
}

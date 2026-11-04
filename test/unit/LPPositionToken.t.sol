// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {LPPositionToken} from "src/LPPositionToken.sol";

/// @notice The opt-in ERC-20 wrapper around one ERC-6909 LP position.
/// @dev Covers the round trip before settlement, the fact that settlement turns the
///      instrument into a Token-A claim (because the manager locks 6909 holder
///      transfers), and the pro-rata split across several ERC-20 holders.
contract LPPositionTokenTest is DualTokenBase {
    LPPositionToken internal wrapper;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        _createMarket();
        id = marketFactory.getLPToken(market);
        wrapper = new LPPositionToken(_manager(), id);
    }

    function _manager() internal view returns (LPPositionManager) {
        return LPPositionManager(amm.positionManager());
    }

    function _wrapAll(address holder) internal returns (uint256 amount) {
        amount = _manager().balanceOf(holder, id);
        vm.startPrank(holder);
        _manager().setOperator(address(wrapper), true);
        wrapper.wrap(amount);
        vm.stopPrank();
    }

    function test_bindsToItsPositionAndMarket() public view {
        assertEq(wrapper.positionId(), id);
        assertEq(wrapper.market(), market);
        assertEq(address(wrapper.tokenA()), address(east));
    }

    /// Before settlement the wrapper is pure plumbing: 1:1, both ways.
    function test_wrapAndUnwrapRoundTrip() public {
        uint256 units = _manager().balanceOf(creator, id);
        uint256 wrapped = _wrapAll(creator);

        assertEq(wrapped, units);
        assertEq(wrapper.balanceOf(creator), units, "ERC-20 minted 1:1");
        assertEq(_manager().balanceOf(creator, id), 0, "6909 units moved to the wrapper");
        assertEq(_manager().balanceOf(address(wrapper), id), units);

        vm.prank(creator);
        wrapper.unwrap(units);

        assertEq(wrapper.balanceOf(creator), 0);
        assertEq(_manager().balanceOf(creator, id), units, "6909 units returned");
    }

    function test_wrapNeedsApproval() public {
        uint256 units = _manager().balanceOf(creator, id);
        vm.prank(creator);
        vm.expectRevert();
        wrapper.wrap(units);
    }

    /// The reason settle()/redeem() exist: the manager locks holder-to-holder 6909
    /// transfers once the market settles, so unwrap can no longer work.
    function test_unwrapIsImpossibleAfterSettlementSoRedeemExists() public {
        uint256 units = _wrapAll(creator);
        _seedAmmPosition();
        _resolveAndSettle(1);

        vm.prank(creator);
        vm.expectRevert();
        wrapper.unwrap(units);

        uint256 before = east.balanceOf(creator);
        wrapper.settle();
        assertGt(wrapper.proceeds(), 0, "wrapper collected the position's principal");
        assertGt(wrapper.feePot(), 0, "and its fees, measured separately");
        assertEq(wrapper.supplyAtSettle(), units, "supply frozen for the split");

        vm.prank(creator);
        uint256 paid = wrapper.redeem(units);

        // `proceeds` narrowed to principal in the M-1 fix; the sole holder takes both
        // pots, so compare against the total.
        assertEq(paid, wrapper.totalCollected(), "sole holder takes everything");
        assertEq(east.balanceOf(creator) - before, paid);
        assertEq(wrapper.balanceOf(creator), 0);
    }

    /// Proceeds split by ERC-20 balance, not by who deposited the 6909 units.
    function test_proceedsSplitProRataAcrossHolders() public {
        uint256 units = _wrapAll(creator);
        uint256 half = units / 2;

        vm.prank(creator);
        wrapper.transfer(bob, half);

        _seedAmmPosition();
        _resolveAndSettle(1);
        wrapper.settle();

        uint256 total = wrapper.totalCollected();
        uint256 creatorBefore = east.balanceOf(creator);
        uint256 bobBefore = east.balanceOf(bob);

        vm.prank(bob);
        uint256 bobPaid = wrapper.redeem(half);
        vm.prank(creator);
        uint256 creatorPaid = wrapper.redeem(units - half);

        assertEq(east.balanceOf(bob) - bobBefore, bobPaid);
        assertEq(east.balanceOf(creator) - creatorBefore, creatorPaid);
        assertLe(bobPaid + creatorPaid, total, "never pays out more than collected");
        // Rounding is downward, so at most one wei per holder stays behind.
        assertGe(bobPaid + creatorPaid + 2, total, "dust only");
        // Principal is pro rata by units; fees are per-address. Here bob received his
        // half of the ERC-20 before any accrual, so both pots split evenly and the two
        // payouts match — see WrapperFeeAccrualTest for the cases where they do not.
        assertApproxEqAbs(bobPaid, creatorPaid, 2, "equal units, equal share");
    }

    function test_settleOnlyAfterMarketSettlesAndOnlyOnce() public {
        _wrapAll(creator);

        vm.expectRevert(LPPositionToken.MarketNotSettled.selector);
        wrapper.settle();

        _seedAmmPosition();
        _resolveAndSettle(1);
        wrapper.settle();

        vm.expectRevert(LPPositionToken.AlreadySettled.selector);
        wrapper.settle();
    }

    /// Audit 2026-09-10 (I-4), superseded by the M-1 fix. The guard that refused a
    /// zero-supply `settle()` had to be REMOVED: with per-holder accrual a wrapper
    /// everybody unwrapped from still owes them the fees they earned while wrapped, and
    /// refusing to settle would strand that cash for ever. See
    /// WrapperFeeAccrualTest.test_unwrappingKeepsAlreadyEarnedFees.
    function test_settleAtZeroSupplyIsAllowedBecauseFeesMayStillBeOwed() public {
        _seedAmmPosition();
        _resolveAndSettle(1);

        wrapper.settle();
        assertTrue(wrapper.settled());
        assertEq(wrapper.supplyAtSettle(), 0);
    }

    /// The reachability argument above, asserted rather than assumed.
    function test_wrappingIsImpossibleOnceTheMarketSettles() public {
        _seedAmmPosition();
        _resolveAndSettle(1);

        uint256 units = _manager().balanceOf(creator, id);
        vm.startPrank(creator);
        _manager().setOperator(address(wrapper), true);
        vm.expectRevert(LPPositionManager.InvalidPhase.selector);
        wrapper.wrap(units);
        vm.stopPrank();
    }

    function test_redeemBeforeSettleReverts() public {
        uint256 units = _wrapAll(creator);
        vm.prank(creator);
        vm.expectRevert(LPPositionToken.NotSettled.selector);
        wrapper.redeem(units);
    }

    function test_wrapAfterSettleReverts() public {
        _wrapAll(creator);
        _seedAmmPosition();
        _resolveAndSettle(1);
        wrapper.settle();

        vm.prank(creator);
        vm.expectRevert(LPPositionToken.AlreadySettled.selector);
        wrapper.wrap(1);
    }
}

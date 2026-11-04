// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {LPPositionToken} from "src/LPPositionToken.sol";

/// @notice Audit M-1, inverted. The original PoC showed the creator losing 0.287003e18
///         — exactly half of the 0.574e18 that accrued while only the creator's units
///         were wrapped — when bob wrapped one transaction before settlement. With the
///         per-holder accumulator a late wrap must move NOTHING.
contract WrapperFeeAccrualTest is DualTokenBase {
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

    function test_lateWrapDoesNotDiluteTheEarlyWrapper() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);
        uint256 half = units / 2;
        uint256 creatorUnits = units - half;

        vm.prank(creator);
        manager.transfer(bob, id, half);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(creatorUnits);
        vm.stopPrank();

        _seedAmmPosition(); // every fee in this test accrues here

        uint256 snap = vm.snapshotState();

        // ── Control: bob never wraps. ────────────────────────────────────────
        _resolveAndSettle(1);
        wrapper.settle();
        vm.prank(creator);
        uint256 creatorAlone = wrapper.redeem(creatorUnits);

        vm.revertToState(snap);

        // ── Treatment: bob wraps at the last moment, after all fee accrual. ──
        vm.startPrank(bob);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(half);
        vm.stopPrank();

        _resolveAndSettle(1);
        wrapper.settle();

        // The late wrapper accrued nothing: it held no ERC-20 while the index moved.
        assertEq(wrapper.feesClaimable(bob), 0, "late wrapper accrued no fee entitlement");

        vm.prank(bob);
        uint256 bobPaid = wrapper.redeem(half);
        vm.prank(creator);
        uint256 creatorDiluted = wrapper.redeem(creatorUnits);

        emit log_named_uint("creator alone   ", creatorAlone);
        emit log_named_uint("creator diluted ", creatorDiluted);
        emit log_named_uint("bob paid        ", bobPaid);

        // THE FIX: the late wrap moves nothing. Tolerance is floor dust only.
        assertApproxEqAbs(
            creatorDiluted, creatorAlone, 2, "late wrap must not dilute the early wrapper"
        );
        assertLt(bobPaid, creatorDiluted, "bob receives principal only");
        assertLe(bobPaid + creatorDiluted, wrapper.proceeds() + wrapper.feePot());
    }

    /// Entitlement must track the ERC-20 balance over time, not the balance at the end.
    function test_feesFollowTheErc20HolderOverTime() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.stopPrank();

        // Phase 1: the creator holds everything while fees accrue.
        _seedAmmPosition();
        uint256 afterPhase1 = wrapper.feesAccrued(creator);
        assertGt(afterPhase1, 0, "phase 1 accrued to the creator");
        assertEq(wrapper.feesAccrued(bob), 0, "bob held nothing in phase 1");

        // Hand half to bob, then accrue again.
        vm.prank(creator);
        wrapper.transfer(bob, units / 2);
        assertEq(wrapper.feesAccrued(bob), 0, "the transfer itself credits bob nothing");

        _resolveAndSettle(1);
        wrapper.settle();

        uint256 creatorFees = wrapper.feesClaimable(creator);
        uint256 bobFees = wrapper.feesClaimable(bob);

        // The creator keeps every unit of phase 1; bob's share is only what accrued
        // after he held units, which in this schedule is nothing.
        assertGe(creatorFees, afterPhase1 - 2, "creator keeps phase-1 entitlement");
        assertEq(bobFees, 0, "bob accrued only after the index stopped moving");
        assertLe(creatorFees + bobFees, wrapper.feePot(), "never more than arrived");
    }

    /// A holder that unwrapped keeps the fees it earned while wrapped.
    function test_unwrappingKeepsAlreadyEarnedFees() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.stopPrank();

        _seedAmmPosition();
        uint256 earned = wrapper.feesAccrued(creator);
        assertGt(earned, 0);

        vm.prank(creator);
        wrapper.unwrap(units);
        assertEq(wrapper.totalSupply(), 0, "everyone unwrapped");

        _resolveAndSettle(1);
        // settle() must still work at zero supply, or the fees earned while wrapped
        // would be stranded. This is why the I-4 guard was removed.
        wrapper.settle();
        assertEq(wrapper.supplyAtSettle(), 0);
        assertGt(wrapper.feePot(), 0, "fee cash arrived for a zero-supply wrapper");

        uint256 before = east.balanceOf(creator);
        vm.prank(creator);
        uint256 paid = wrapper.claimFees();
        assertGt(paid, 0, "the creator's earned fees are still payable");
        assertEq(east.balanceOf(creator) - before, paid);
    }

    /// The wrapper must never hand out more than it collected.
    function test_payoutsNeverExceedWhatArrived() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        wrapper.transfer(bob, units / 3);
        vm.stopPrank();

        _seedAmmPosition();
        _resolveAndSettle(1);
        wrapper.settle();

        uint256 collected = wrapper.proceeds() + wrapper.feePot();
        uint256 held = east.balanceOf(address(wrapper));
        assertGe(held, collected, "the wrapper holds what it promised");

        // Read the balance BEFORE pranking: an external call consumes the prank.
        uint256 creatorUnits = wrapper.balanceOf(creator);
        vm.prank(bob);
        uint256 bobPaid = wrapper.redeem(units / 3);
        vm.prank(creator);
        uint256 creatorPaid = wrapper.redeem(creatorUnits);

        assertLe(bobPaid + creatorPaid, collected, "never pays out more than collected");
    }

    /// `claimFeesFor` is the entire reason pooled units work: the holder of record may
    /// be a contract that cannot call `claimFees()` itself. Push-only — the cash goes
    /// to the holder, never to the caller — so it grants the caller no authority.
    function test_claimFeesForDeliversToTheHolderNotTheCaller() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.stopPrank();

        // Fees accrue while the creator holds.
        _seedAmmPosition();

        // Then the units move into a contract with no way to call claimFees() itself.
        address pool = address(0xF00D);
        vm.prank(creator);
        wrapper.transfer(pool, units);

        _resolveAndSettle(1);
        wrapper.settle();

        // The creator earned everything before the transfer; the pool earned nothing.
        assertGt(wrapper.feesClaimable(creator), 0, "creator earned pre-transfer");

        uint256 poolBefore = east.balanceOf(pool);
        uint256 callerBefore = east.balanceOf(bob);
        uint256 owed = wrapper.feesClaimable(creator);

        // Anyone may push, and it lands on the holder.
        vm.prank(bob);
        uint256 paid = wrapper.claimFeesFor(creator);

        assertEq(paid, owed, "pays exactly what was claimable");
        assertEq(east.balanceOf(bob), callerBefore, "the caller receives nothing");
        assertEq(east.balanceOf(pool), poolBefore, "and so does an unrelated holder");
        assertEq(wrapper.feesClaimable(creator), 0, "entitlement discharged once");

        // Not twice.
        vm.prank(bob);
        vm.expectRevert(LPPositionToken.NothingToClaim.selector);
        wrapper.claimFeesFor(creator);
    }

    /// previewRedeem must agree with what redeem actually pays.
    function test_previewRedeemMatchesRedeem() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.stopPrank();

        _seedAmmPosition();
        _resolveAndSettle(1);
        wrapper.settle();

        (uint256 principal, uint256 fees) = wrapper.previewRedeem(creator, units);
        vm.prank(creator);
        uint256 paid = wrapper.redeem(units);

        assertEq(paid, principal + fees, "preview matches the payout");
        assertGt(principal, 0);
        assertGt(fees, 0);
    }

    /// `claimAvailable` returns WAD and native amounts in
    /// one tuple. Pin the documented relationship so it cannot drift silently:
    ///   native transferred == floorPaid / 10**(18 - decimals) + feesPaid
    function test_claimAvailableReturnUnitsMatchTheNativeTransfer() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);

        _seedAmmPosition();
        _resolveAndSettle(1);

        uint256 scale = 10 ** (18 - east.decimals());
        uint256 before = east.balanceOf(creator);

        vm.prank(creator);
        (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market, id, units);

        uint256 moved = east.balanceOf(creator) - before;
        assertGt(redeemedWad, 0, "redeem credited residual");
        assertTrue(redeemedWad != units, "redeemedWad is residual, not burned units");
        assertEq(floorPaid / scale + feesPaid, moved, "documented unit relationship");
        // And the naive sum is wrong unless Token A has 18 decimals.
        if (scale != 1) {
            assertTrue(floorPaid + feesPaid != moved, "raw sum must not be the total");
        }
    }

    /// ERC-20 units sent to the wrapper itself would accrue to an unclaimable account.
    function test_selfTransferIsRefused() public {
        LPPositionManager manager = _manager();
        uint256 units = manager.balanceOf(creator, id);
        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.expectRevert(LPPositionToken.SelfTransfer.selector);
        wrapper.transfer(address(wrapper), 1);
        vm.stopPrank();
    }
}

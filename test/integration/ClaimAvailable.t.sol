// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";

/// @notice One-transaction LP proceeds collection (issue #2).
/// @dev Redeem, floor and fee claims are otherwise three caller-scoped calls.
///      These assert that one call pays the same total to the same owner, that
///      empty components do not revert the whole thing, and that a repeat call is
///      a no-op rather than a second payout.
contract ClaimAvailableTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    function _manager() internal view returns (LPPositionManager) {
        return LPPositionManager(amm.positionManager());
    }

    function _bootstrapId() internal view returns (uint256) {
        return marketFactory.getLPToken(market);
    }

    /// The headline: one transaction instead of three, same owner, same money.
    function test_singleTransactionPaysRedeemFloorAndFees() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);

        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);
        assertGt(units, 0, "creator holds the bootstrap position");

        uint256 before = east.balanceOf(creator);

        vm.prank(creator);
        (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market, id, units);

        uint256 paid = east.balanceOf(creator) - before;
        assertGt(paid, 0, "creator was actually paid");
        assertGt(redeemedWad, 0, "redeem leg ran");
        // The floor is credited by the redeem inside the same call and swept after it,
        // so the transfer must equal floor + fees. redeemedWad is the residual
        // entitlement recorded, not the LP units burned and not a second transfer.
        assertEq(paid, floorPaid + feesPaid, "transfer equals floor + fees");
        assertEq(_manager().balanceOf(creator, id), 0, "units burned");
        assertTrue(redeemedWad != units, "redeemedWad is residual, not burned units");
        assertEq(
            redeemedWad, floorPaid, "at 18 decimals the residual is fully discharged"
        );
    }

    /// An LP with no floor entitlement must not have the whole call revert on them.
    /// This is the asymmetry that blocked batching: claimFloor reverts on zero.
    function test_zeroComponentsDoNotRevert() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();

        // bob never provided liquidity: every component is empty.
        vm.prank(bob);
        (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market, id, 0);

        assertEq(redeemedWad, 0);
        assertEq(floorPaid, 0);
        assertEq(feesPaid, 0);
    }

    /// Calling again must pay nothing rather than double-paying or reverting.
    function test_repeatCallIsANoOp() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        vm.prank(creator);
        amm.claimAvailable(market, id, units);

        uint256 afterFirst = east.balanceOf(creator);
        vm.prank(creator);
        (uint256 r2, uint256 f2, uint256 d2) = amm.claimAvailable(market, id, 0);

        assertEq(r2, 0);
        assertEq(f2, 0);
        assertEq(d2, 0);
        assertEq(east.balanceOf(creator), afterFirst, "no second payout");
    }

    /// The combined path must pay exactly what the three separate calls would.
    function test_matchesTheThreeCallPath() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        uint256 snap = vm.snapshotState();

        vm.startPrank(creator);
        amm.redeemLPPosition(market, id, units);
        amm.claimFloor(market);
        vault.claimLPDividendForPosition(market, id);
        vm.stopPrank();
        uint256 viaThree = east.balanceOf(creator);

        vm.revertToState(snap);

        vm.prank(creator);
        amm.claimAvailable(market, id, units);
        assertEq(east.balanceOf(creator), viaThree, "one call pays the same");
    }

    /// Only the caller may be paid: the engine must never become the beneficiary.
    function test_engineAndVaultAreNotTheBeneficiary() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        uint256 engineBefore = east.balanceOf(address(amm));
        uint256 vaultBefore = east.balanceOf(address(vault));

        vm.prank(creator);
        (, uint256 floorPaid, uint256 feesPaid) = amm.claimAvailable(market, id, units);

        assertEq(
            east.balanceOf(address(amm)),
            engineBefore - floorPaid,
            "engine only paid out the floor"
        );
        assertEq(
            east.balanceOf(address(vault)),
            vaultBefore - feesPaid,
            "vault only paid out the fees"
        );
    }

    /// `claimLPDividendFor` moves the beneficiary, so it must be engine-only.
    function test_claimLPDividendForIsEngineOnly() public {
        _resolveAndSettle(1);
        // Resolve the id BEFORE arming expectRevert: it makes an external call of its
        // own, and expectRevert applies to the very next one.
        uint256 id = _bootstrapId();
        vm.prank(bob);
        vm.expectRevert();
        vault.claimLPDividendFor(market, id, bob);
    }

    /// Partial redemption: the remainder stays claimable and totals match a full one.
    function test_partialRedemptionThenTheRest() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        uint256 snap = vm.snapshotState();
        vm.prank(creator);
        amm.claimAvailable(market, id, units);
        uint256 viaOneCall = east.balanceOf(creator);
        vm.revertToState(snap);

        uint256 firstHalf = units / 2;
        vm.prank(creator);
        amm.claimAvailable(market, id, firstHalf);
        vm.prank(creator);
        amm.claimAvailable(market, id, units - firstHalf);

        assertEq(_manager().balanceOf(creator, id), 0, "all units burned");
        assertApproxEqAbs(
            east.balanceOf(creator), viaOneCall, 2, "two halves pay what one call paid"
        );
    }

    /// A floor already pulled separately must not be paid twice by the combined call.
    function test_priorSeparateClaimIsNotPaidAgain() public {
        _tradeToAccrueFees();
        _resolveAndSettle(1);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        vm.startPrank(creator);
        amm.redeemLPPosition(market, id, units);
        amm.claimFloor(market);
        uint256 afterFloor = east.balanceOf(creator);
        // Everything except the fee leg has already been taken.
        (uint256 r, uint256 f, uint256 d) = amm.claimAvailable(market, id, 0);
        vm.stopPrank();

        assertEq(r, 0, "nothing left to redeem");
        assertEq(f, 0, "floor already taken");
        assertEq(east.balanceOf(creator), afterFloor + d, "only the fee leg paid");
    }

    /// NO settlement pays the same way; the residual differs, the plumbing does not.
    function test_worksOnNoOutcome() public {
        _tradeToAccrueFees();
        _resolveAndSettle(0);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        uint256 before = east.balanceOf(creator);
        vm.prank(creator);
        (, uint256 floorPaid, uint256 feesPaid) = amm.claimAvailable(market, id, units);

        assertEq(east.balanceOf(creator) - before, floorPaid + feesPaid);
        assertEq(_manager().balanceOf(creator, id), 0);
    }

    /// INVALID pays the 50/50 average of both sides. LP still collects in one call.
    function test_worksOnInvalidOutcome() public {
        _tradeToAccrueFees();
        _resolveAndSettle(2);
        uint256 id = _bootstrapId();
        uint256 units = _manager().balanceOf(creator, id);

        uint256 before = east.balanceOf(creator);
        vm.prank(creator);
        (, uint256 floorPaid, uint256 feesPaid) = amm.claimAvailable(market, id, units);

        assertEq(east.balanceOf(creator) - before, floorPaid + feesPaid);
        assertEq(_manager().balanceOf(creator, id), 0);
    }

    /// The external claimFloor must keep reverting on nothing for existing callers.
    function test_externalClaimFloorStillRevertsOnNothing() public {
        _resolveAndSettle(1);
        vm.prank(bob);
        vm.expectRevert();
        amm.claimFloor(market);
    }

    // ---- helpers ----

    /// Token A here is East18E, so WAD and native units coincide.
    function _tradeToAccrueFees() internal {
        _seedAmmPosition();
    }

    /// Wrong-position atomic rollback: a position id belonging to another
    /// market must be refused outright, with no partial payout and no state moved.
    function test_positionFromAnotherMarketIsRefusedAtomically() public {
        uint256 ownId = _bootstrapId();
        _tradeToAccrueFees();

        // A second market, with its own bootstrap position.
        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation1 = _marketParams(
            "A different question entirely", 0, deadline, address(east), B_BASE, 0.5e18
        );
        vm.prank(creator);
        (address otherMarket,) = marketFactory.createMarket(creation1);

        _resolveAndSettle(1);

        uint256 unitsBefore = _manager().balanceOf(creator, ownId);
        uint256 cashBefore = east.balanceOf(creator);

        // units = 0 skips the redeem leg, so this reaches the cross-market guard
        // itself: FeeVault.claimLPDividendFor requires
        // positionMarket(positionId) == market.
        vm.prank(creator);
        vm.expectRevert(VenueFeeVault.NotFinalizable.selector);
        amm.claimAvailable(otherMarket, ownId, 0);

        // With units > 0 an earlier guard fires first — the other market is not
        // settled, so the lazy finalize refuses. Either way it is a clean refusal,
        // which is the property that matters.
        vm.prank(creator);
        vm.expectRevert();
        amm.claimAvailable(otherMarket, ownId, unitsBefore);

        // Nothing moved: not the units, not the cash.
        assertEq(_manager().balanceOf(creator, ownId), unitsBefore, "units untouched");
        assertEq(east.balanceOf(creator), cashBefore, "no partial payout");

        // And the legitimate claim still works afterwards.
        vm.prank(creator);
        (,, uint256 fees) = amm.claimAvailable(market, ownId, unitsBefore);
        assertGt(east.balanceOf(creator) + fees, cashBefore, "the real claim pays");
    }
}

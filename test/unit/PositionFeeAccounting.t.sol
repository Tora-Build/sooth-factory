// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    ERC6909TokenSupply
} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import {PositionFeeAccounting} from "../../src/libraries/PositionFeeAccounting.sol";

// Test controller only. Does not stand in for the AMM/FeeVault custody integration.
// Mirrors the real LPPositionManager: it IS the receipt, so the pre-transfer
// checkpoint is an internal _update hook rather than an external callback.
contract PositionFeeControllerHarness is ERC6909TokenSupply {
    error TransfersLocked();

    using PositionFeeAccounting for PositionFeeAccounting.State;

    PositionFeeAccounting.State internal state;
    // Ids start at 1 so zero stays a null sentinel, as in LPPositionManager.
    uint256 internal nextId = 1;
    bool public isSettled;

    function add(address owner, uint256 weight, uint256 supply)
        external
        returns (uint256 id)
    {
        id = nextId++;
        state.register(id, weight, supply);
        _mint(owner, id, supply);
    }

    function accrue(uint256 ordinary, uint256 contingent) external {
        state.accrue(ordinary, contingent);
    }

    function _update(address from, address to, uint256 id, uint256 amount)
        internal
        override
    {
        if (from != address(0) && to != address(0)) {
            require(!isSettled, TransfersLocked());
        }
        _checkpoint(id, from);
        if (to != from) _checkpoint(id, to);
        super._update(from, to, id, amount);
    }

    function _checkpoint(uint256 id, address holder) private {
        if (holder == address(0)) return;
        state.checkpoint(id, holder, balanceOf(holder, id));
    }

    function checkpoint(uint256 id, address holder) public {
        _checkpoint(id, holder);
    }

    function settle(bool timeout) external {
        state.freeze(timeout);
        isSettled = true;
    }

    function burn(uint256 id, address holder, uint256 amount) external {
        require(isSettled, "settlement");
        _burn(holder, id, amount);
    }

    function take(address holder) external returns (uint256) {
        return state.take(holder);
    }

    function claimable(address holder) external view returns (uint256) {
        return state.claimable(holder);
    }

    function credits(address holder)
        external
        view
        returns (uint256 ordinary, uint256 contingent)
    {
        return (
            state.accounts[holder].earned.ordinary,
            state.accounts[holder].earned.contingent
        );
    }

    function paid() external view returns (uint256) {
        return state.paid;
    }
}

contract PositionFeeAccountingTest is Test {
    PositionFeeControllerHarness internal controller;
    uint256 internal aliceToken;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    function setUp() public {
        controller = new PositionFeeControllerHarness();
        aliceToken = controller.add(ALICE, 100e18, 100e18);
    }

    function test_timeoutKeepsEarlierTenWithAlice() public {
        controller.accrue(30e18, 10e18);
        uint256 bobToken = controller.add(BOB, 100e18, 100e18);
        controller.settle(true);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(bobToken, BOB);
        assertEq(controller.take(BOB), 0);
        assertEq(controller.take(ALICE), 40e18);
        assertEq(controller.take(ALICE), 0);
    }

    function test_transferKeepsPastContingentFeesWithEarner() public {
        controller.accrue(30e18, 10e18);
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, 100e18);
        controller.accrue(6e18, 2e18);
        controller.settle(true);
        controller.checkpoint(aliceToken, BOB);
        assertEq(controller.take(ALICE), 40e18);
        assertEq(controller.take(BOB), 8e18);
    }

    function test_formalInvalidDoesNotReleaseContingentFees() public {
        controller.accrue(30e18, 10e18);
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, 100e18);
        controller.settle(false);
        assertEq(controller.take(ALICE), 30e18);
        assertEq(controller.take(BOB), 0);
        (, uint256 contingent) = controller.credits(ALICE);
        assertEq(contingent, 10e18);
    }

    function test_unequalWeightsAndIndependentReceiptDenominations() public {
        uint256 bobToken = controller.add(BOB, 300e18, 7e18);
        controller.accrue(28e6, 28e6);
        controller.settle(true);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(bobToken, BOB);
        assertEq(controller.take(ALICE), 14e6);
        assertEq(controller.take(BOB), 42e6);
    }

    function test_partialTransferThenBurnPreservesEarnedFees() public {
        controller.accrue(100, 100);
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, 25e18);
        controller.accrue(100, 100);
        controller.settle(true);
        controller.burn(aliceToken, ALICE, 75e18);
        controller.burn(aliceToken, BOB, 25e18);
        assertEq(controller.totalSupply(aliceToken), 0);
        assertEq(controller.take(ALICE), 350);
        assertEq(controller.take(BOB), 50);
    }

    function test_fractionalFeesCarryAcrossCheckpoints() public {
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, 50e18);
        controller.accrue(1, 1);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(aliceToken, BOB);
        controller.accrue(1, 1);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(aliceToken, BOB);
        controller.settle(true);
        assertEq(controller.take(ALICE), 2);
        assertEq(controller.take(BOB), 2);
    }

    function test_fractionCarriesAcrossPositionsAndSeparateClaims() public {
        uint256 second = controller.add(ALICE, 100e18, 100e18);
        controller.accrue(1, 0);
        controller.settle(false);
        controller.checkpoint(aliceToken, ALICE);
        assertEq(controller.take(ALICE), 0);
        controller.checkpoint(second, ALICE);
        assertEq(controller.take(ALICE), 1);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(second, ALICE);
        assertEq(controller.take(ALICE), 0);
    }

    function test_selfAndZeroTransfersCannotManufactureFees() public {
        controller.accrue(3e6, 1e6);
        vm.startPrank(ALICE);
        controller.transfer(ALICE, aliceToken, 100e18);
        controller.transfer(BOB, aliceToken, 0);
        controller.transfer(ALICE, aliceToken, 0);
        vm.stopPrank();
        controller.settle(true);
        controller.checkpoint(aliceToken, ALICE);
        assertEq(controller.take(ALICE), 4e6);
        assertEq(controller.take(BOB), 0);
    }

    function test_fractionRemainsWithSellerAndCombinesOnTimeout() public {
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, 50e18);
        controller.accrue(1, 1);
        vm.prank(ALICE);
        controller.transfer(CAROL, aliceToken, 50e18);
        controller.settle(true);
        controller.checkpoint(aliceToken, BOB);
        controller.checkpoint(aliceToken, CAROL);
        assertEq(controller.take(ALICE), 1);
        assertEq(controller.take(BOB), 1);
        assertEq(controller.take(CAROL), 0);
    }

    /// The external controller callback is gone with ERC-6909: checkpoints happen in
    /// the _update hook. The equivalent guard is that an unknown id cannot checkpoint.
    function test_phaseAndUnknownPositionGuards() public {
        vm.expectRevert(PositionFeeAccounting.InvalidPhase.selector);
        controller.take(ALICE);
        vm.expectRevert(PositionFeeAccounting.InvalidPosition.selector);
        controller.checkpoint(9999, ALICE);
        controller.settle(true);
        vm.expectRevert(PositionFeeAccounting.InvalidPhase.selector);
        controller.accrue(1, 1);
        vm.expectRevert(PositionFeeAccounting.InvalidPhase.selector);
        controller.add(BOB, 1, 1);
        vm.expectRevert(PositionFeeAccounting.InvalidPhase.selector);
        controller.settle(false);
        vm.prank(ALICE);
        vm.expectRevert(PositionFeeControllerHarness.TransfersLocked.selector);
        controller.transfer(BOB, aliceToken, 1);
    }

    function test_independentMarketsDoNotShareAccruals() public {
        PositionFeeControllerHarness other = new PositionFeeControllerHarness();
        uint256 otherToken = other.add(ALICE, 100e18, 100e18);
        controller.accrue(30e18, 10e18);
        other.accrue(3e6, 1e6);
        controller.settle(true);
        other.settle(false);
        controller.checkpoint(aliceToken, ALICE);
        other.checkpoint(otherToken, ALICE);
        assertEq(controller.take(ALICE), 40e18);
        assertEq(other.take(ALICE), 3e6);
    }

    function testFuzz_transfersCannotExceedFunding(
        uint96 ordinarySeed,
        uint96 contingentSeed,
        uint96 transferSeed,
        bool timeout
    ) public {
        uint256 ordinary = bound(uint256(ordinarySeed), 0, 1e24);
        uint256 contingent = bound(uint256(contingentSeed), 0, 1e24);
        uint256 transferAmount = bound(uint256(transferSeed), 0, 100e18);
        controller.accrue(ordinary, contingent);
        vm.prank(ALICE);
        controller.transfer(BOB, aliceToken, transferAmount);
        controller.accrue(ordinary, contingent);
        vm.prank(BOB);
        controller.transfer(CAROL, aliceToken, transferAmount / 2);
        controller.settle(timeout);
        controller.checkpoint(aliceToken, ALICE);
        controller.checkpoint(aliceToken, BOB);
        controller.checkpoint(aliceToken, CAROL);
        uint256 sum =
            controller.take(CAROL) + controller.take(ALICE) + controller.take(BOB);
        uint256 funding = 2 * (ordinary + (timeout ? contingent : 0));
        assertLe(sum, funding);
        // At these fixed weights all index divisions are exact; only each holder's
        // terminal fraction remains, strictly less than one native unit per holder.
        assertLt(funding - sum, 3);
        assertEq(
            controller.take(ALICE) + controller.take(BOB) + controller.take(CAROL), 0
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {PositionLedgerHarness as Ledger} from "./PositionLedgerHarness.sol";

contract PositionLedgerTest is Test {
    Ledger internal ledger;
    address internal constant OTHER = address(0xB0B);

    function setUp() public {
        ledger = new Ledger();
        ledger.add(100e18, 100e18, address(this));
    }

    function test_signedDirectedDivision() public view {
        Ledger.Interval memory positive = ledger.divide(10, 1, 3);
        Ledger.Interval memory negative = ledger.divide(-10, 1, 3);
        assertEq(positive.low, 3);
        assertEq(positive.high, 4);
        assertEq(negative.low, -4);
        assertEq(negative.high, -3);
    }

    function testFuzz_divisionEnclosesExactRational(
        int64 value,
        uint64 multiplier,
        uint64 divisor
    ) public view {
        uint256 d = uint256(divisor) + 1;
        Ledger.Interval memory r = ledger.divide(value, multiplier, d);
        int256 exactNumerator = int256(value) * int256(uint256(multiplier));
        assertLe(r.low * int256(d), exactNumerator);
        assertGe(r.high * int256(d), exactNumerator);
        assertLe(r.high - r.low, 1);
    }

    function test_invalidArithmeticDomainsRevert() public {
        vm.expectRevert();
        ledger.divide(type(int256).min, 1, 1);
        vm.expectRevert();
        ledger.divide(1, 1, 0);
        vm.expectRevert();
        ledger.divide(type(int256).max, 2, 1);
    }

    function fixture() internal {
        // Synthetic costs isolate ledger arithmetic from pricing approximation.
        ledger.trade(0, 100e18, 62e18, 1e18, 6e18);
        Ledger.Interval memory old = ledger.residual(0, 0);
        ledger.add(100e18, 101e18, OTHER); // G=1.01, so both weights are exactly 100.
        Ledger.Interval memory afterAdd = ledger.residual(0, 0);
        assertEq(old.low, afterAdd.low);
        assertEq(old.high, afterAdd.high);
        ledger.trade(0, -100e18, -55e18, 1e18, 4e18);
    }

    function test_exactRationalSignedExposureAndGrowth() public {
        fixture();
        assertEq(ledger.residual(0, 0).low, 86e18);
        assertEq(ledger.residual(0, 1).low, 136e18);
        assertEq(ledger.residual(1, 0).low, 123e18);
        assertEq(ledger.residual(1, 1).low, 73e18);
        assertEq(ledger.residual(0, 2).low, 111e18);
        assertEq(ledger.residual(1, 2).low, 98e18);
    }

    function test_claimOrderBothDecimalsAllOutcomes() public {
        for (uint8 selected; selected < 3; selected++) {
            for (uint8 order; order < 2; order++) {
                for (uint8 d; d < 2; d++) {
                    setUp();
                    fixture();
                    ledger.finalize(selected);
                    uint8 decimals = d == 0 ? 6 : 18;
                    for (uint256 i; i < 2; i++) {
                        uint256 id = order == 0 ? i : 1 - i;
                        address owner = id == 0 ? address(this) : OTHER;
                        vm.prank(owner);
                        ledger.claim(id, 37e18, decimals);
                        vm.prank(owner);
                        ledger.claim(id, 63e18, decimals);
                    }
                    assertEq(ledger.residualBacking(), 0);
                }
            }
        }
    }

    function test_feesStayWithEarnerAfterTransfer() public {
        fixture();
        ledger.transfer(0, OTHER);
        assertEq(ledger.earnedFees(address(this)), 8e18);
        ledger.trade(1, 20e18, 10e18, 0, 2e18);
        ledger.checkpoint(0);
        ledger.checkpoint(1);
        assertEq(ledger.earnedFees(OTHER), 4e18);
        ledger.finalize(2);
        assertEq(ledger.claimFees(), 8e18);
        vm.prank(OTHER);
        assertEq(ledger.claimFees(), 4e18);
        assertEq(ledger.feeBacking(), 0);
        assertEq(ledger.claimFees(), 0);
    }

    function test_lifecycleAndOwnershipRejections() public {
        vm.expectRevert();
        ledger.claim(0, 1, 18);
        vm.prank(OTHER);
        vm.expectRevert();
        ledger.transfer(0, OTHER);
        vm.expectRevert();
        ledger.trade(0, -1, -1, 0, 0);
        ledger.finalize(0);
        vm.expectRevert();
        ledger.add(1, 1, OTHER);
        vm.expectRevert();
        ledger.trade(0, 1, 1, 0, 0);
        vm.expectRevert();
        ledger.finalize(0);
        vm.expectRevert();
        ledger.claim(0, 1, 19);
        vm.prank(OTHER);
        vm.expectRevert();
        ledger.claim(0, 1, 18);
        ledger.claim(0, 100e18, 18);
        vm.expectRevert();
        ledger.claim(0, 1, 18);
    }

    function testFuzz_partialNativeClaimsNeverExceedDeposit(
        uint96 raw,
        uint96 part,
        bool sixDecimals
    ) public {
        uint256 deposit = bound(uint256(raw), 1, 1e24);
        Ledger h = new Ledger();
        h.add(deposit, 100e18, address(this));
        h.finalize(2);
        uint256 first = bound(uint256(part), 1, deposit);
        uint8 decimals = sixDecimals ? 6 : 18;
        uint256 scale = sixDecimals ? 1e12 : 1;
        uint256 paid = h.claim(0, first, decimals);
        if (first < deposit) paid += h.claim(0, deposit - first, decimals);
        assertLe(paid * scale, deposit);
        assertEq(h.residualBacking(), deposit - paid * scale);
        assertLt(h.residualBacking(), 2 * scale);
    }

    function testFuzz_nonDivisibleUpdatesEncloseIndependentRational(uint64 raw) public {
        uint256 amount = bound(uint256(raw), 1, 1e18);
        Ledger h = new Ledger();
        h.add(100e18, 3, address(this));
        h.add(100e18, 4, OTHER);
        h.trade(0, int256(amount), int256(amount / 2), 0, 0);
        // Independent numerator for creator YES: 100e18 + 3*(cost-shares)/7.
        int256 numerator = int256(700e18) + 3 * (int256(amount / 2) - int256(amount));
        Ledger.Interval memory r = h.residual(0, 0);
        assertLe(r.low * 7, numerator);
        assertGe(r.high * 7, numerator);
        assertLe(r.high - r.low, 2);
    }

    function test_repeatedFeeCheckpointsCannotCreateMoney() public {
        Ledger h = new Ledger();
        h.add(100e18, 3, address(this));
        h.add(100e18, 4, OTHER);
        for (uint256 i; i < 50; i++) {
            h.trade(0, 2, 1, 0, 1);
            h.checkpoint(0);
            h.checkpoint(1);
        }
        h.finalize(1);
        uint256 paid = h.claimFees();
        vm.prank(OTHER);
        paid += h.claimFees();
        assertLe(paid, 50);
        assertEq(paid, 49);
        assertEq(h.feeBacking(), 50 - paid);
    }

    function test_partialClaimsCarrySubNativeFractions() public {
        Ledger h = new Ledger();
        h.add(1e12, 100e18, address(this));
        h.finalize(0);
        assertEq(h.claim(0, 5e11, 6), 0);
        assertEq(h.claim(0, 5e11, 6), 1);
        assertEq(h.residualBacking(), 0);
    }

    function test_claimCannotSwitchPrecision() public {
        ledger.finalize(0);
        ledger.claim(0, 1, 6);
        vm.expectRevert("precision changed");
        ledger.claim(0, 1, 18);
    }

    function test_checkpointFrequencyPreservesOwnerFraction() public {
        Ledger h = new Ledger();
        h.add(100e18, 2, address(this));
        h.add(100e18, 2, OTHER);
        h.trade(0, 2, 1, 0, 1);
        h.checkpoint(0);
        assertEq(h.feeRemainder(address(this)), h.SCALE() / 2);
        h.transfer(0, OTHER);
        assertEq(h.feeRemainder(address(this)), h.SCALE() / 2);
        h.trade(0, 2, 1, 0, 1);
        h.checkpoint(0);
        h.checkpoint(1);
        assertEq(h.earnedFees(address(this)), 0);
        assertEq(h.earnedFees(OTHER), 1);
        assertEq(h.feeRemainder(OTHER), h.SCALE() / 2);
    }
}

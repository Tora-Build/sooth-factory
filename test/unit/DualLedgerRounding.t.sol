// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";

/**
 * @title Decimal conversion bounds and pro-rata rounding
 * @notice Tests DecimalMath and a mathematical bound on independently floored
 *         shares. These pure tests do not prove engine or vault accounting.
 * @dev Fee policy lives in docs/fee-accounting-and-same-token.md. Tests of actual
 *      vault splits are in VenueFeeVaults.t.sol: the one-native-unit dust test,
 *      full-allocation validation, and book split/payer-refund conservation fuzz.
 *      VenueFeeInvariant.t.sol checks bucket and liability reconciliation across
 *      both vaults. No local imitation of either venue's splitter is maintained.
 */
contract DualLedgerRoundingTest is Test {
    function testFuzz_SixDecimalFloorBiasAndBound(uint256 wad) public pure {
        wad = bound(wad, 0, 1e36);
        uint256 native = DecimalMath.fromWad(wad, 6);
        uint256 back = DecimalMath.toWad(native, 6);
        assertLe(back, wad, "floor round-trip must not gain");
        assertLt(wad - back, 1e12, "floor loss bounded by one native unit");
    }

    function testFuzz_SixDecimalCeilBiasAndBound(uint256 wad) public pure {
        wad = bound(wad, 0, 1e36);
        uint256 native = DecimalMath.fromWadCeil(wad, 6);
        uint256 back = DecimalMath.toWad(native, 6);
        assertGe(back, wad, "ceil round-trip must not lose");
        assertLt(back - wad, 1e12, "ceil overshoot bounded by one native unit");
    }

    function testFuzz_EighteenDecimalConversionsAreExact(uint256 wad) public pure {
        wad = bound(wad, 0, 1e36);
        // At 18 decimals, native amounts already use WAD units.
        assertEq(DecimalMath.toWad(DecimalMath.fromWad(wad, 18), 18), wad);
        assertEq(DecimalMath.toWad(DecimalMath.fromWadCeil(wad, 18), 18), wad);
    }

    function testFuzz_FlooredProRataSharesNeverOverAllocate(
        uint256 pool,
        uint256 supply,
        uint256 lp1,
        uint256 lp2,
        uint256 lp3
    ) public pure {
        pool = bound(pool, 0, 1e30);
        supply = bound(supply, 1, 1e30);
        // Partition the denominator into four weights, allowing zero weights.
        lp1 = bound(lp1, 0, supply);
        lp2 = bound(lp2, 0, supply - lp1);
        lp3 = bound(lp3, 0, supply - lp1 - lp2);
        uint256 lp4 = supply - lp1 - lp2 - lp3;

        // Arithmetic lemma only: this does not model earning-time LP accounting.
        uint256 paid = (lp1 * pool) / supply + (lp2 * pool) / supply + (lp3 * pool)
            / supply + (lp4 * pool) / supply;

        assertLe(paid, pool, "floored shares exceeded the pool");
        // Residual is bounded by one unit per claimant (4 claimants here)
        assertLt(pool - paid, 4, "residual exceeds one unit per share");
    }
}

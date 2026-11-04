// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";
import {LMSRMath} from "../reference/LMSRMath.sol";
import {LmsrReference} from "./LmsrReference.sol";

/// @notice Differential checks of `PositionPricing` against an independent bracket.
/// @dev `test/reference/LMSRMath.sol` is intentionally not the oracle. Its WAD
///      Taylor series misses the library's error interval; see
///      `test_coarseWadOracleSitsOutsideTheLibraryInterval`.
contract PositionPricingBoundsTest is Test {
    uint256 internal constant MAX_Q = 1e36;

    function _domain(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        b = bound(b, 1, MAX_Q);
        yes = bound(yes, 0, MAX_Q);
        no = bound(no, 0, MAX_Q);
        return (b, yes, no);
    }

    function _containsReference(uint256 b, uint256 yes, uint256 no) internal pure {
        (uint256 refLo, uint256 refHi) = LmsrReference.cost(b, yes, no);
        (uint256 lo, uint256 hi) = PositionPricing.costBounds(b, yes, no);
        assertLe(refLo, refHi, "reference bracket inverted");
        // The library interval has to cover the whole reference bracket, and
        // that bracket contains the true cost.
        assertLe(lo, refLo, "library low above reference");
        assertGe(hi, refHi, "library high below reference");
    }

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_costBoundsContainReference(uint256 b, uint256 yes, uint256 no)
        public
        pure
    {
        (b, yes, no) = _domain(b, yes, no);
        _containsReference(b, yes, no);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_buyQuoteCoversReferenceDelta(
        uint256 b,
        uint256 yes,
        uint256 no,
        uint256 delta,
        bool yesSide
    ) public pure {
        (b, yes, no) = _domain(b, yes, no);
        delta = bound(delta, 1, MAX_Q);
        uint256 newYes = yes;
        uint256 newNo = no;
        if (yesSide) {
            if (yes > MAX_Q - delta) return;
            newYes = yes + delta;
        } else {
            if (no > MAX_Q - delta) return;
            newNo = no + delta;
        }
        (uint256 oldLo, uint256 oldHi) = LmsrReference.cost(b, yes, no);
        (uint256 newLo, uint256 newHi) = LmsrReference.cost(b, newYes, newNo);
        uint256 quoted = PositionPricing.tradeCost(b, yes, no, newYes, newNo, true);
        // Quoted buy is at least every value the true delta can take.
        if (newHi >= oldLo) assertGe(quoted, newHi - oldLo, "buy undercharges");
        // And it is at least the smallest possible true delta.
        if (newLo > oldHi) assertGe(quoted, newLo - oldHi, "buy below reference");
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_sellQuoteStaysInsideReferenceDelta(
        uint256 b,
        uint256 yes,
        uint256 no,
        uint256 delta,
        bool yesSide
    ) public pure {
        (b, yes, no) = _domain(b, yes, no);
        delta = bound(delta, 1, MAX_Q);
        if (yesSide) {
            if (delta > yes) return;
        } else if (delta > no) {
            return;
        }
        uint256 newYes = yesSide ? yes - delta : yes;
        uint256 newNo = yesSide ? no : no - delta;
        (uint256 oldLo, uint256 oldHi) = LmsrReference.cost(b, yes, no);
        (uint256 newLo, uint256 newHi) = LmsrReference.cost(b, newYes, newNo);
        uint256 quoted = PositionPricing.tradeCost(b, yes, no, newYes, newNo, false);
        // Overlapping brackets: quoted cannot exceed the largest possible delta.
        // Disjoint brackets with old above new: quoted cannot exceed the smallest.
        if (oldHi <= newLo) {
            assertEq(quoted, 0, "sell pays when cost cannot fall");
        } else {
            assertLe(quoted, oldHi - newLo, "sell above reference");
        }
        if (oldLo >= newHi) assertLe(quoted, oldLo - newHi, "sell overpays");
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_probabilityInsideReference(uint256 b, uint256 yes, uint256 no)
        public
        pure
    {
        (b, yes, no) = _domain(b, yes, no);
        (uint256 lo, uint256 hi) = LmsrReference.probability(b, yes, no);
        uint256 p = PositionPricing.probability(b, yes, no);
        assertLe(lo, hi, "probability bracket inverted");
        assertLe(p, hi, "probability above reference");
        assertGe(p, lo, "probability below reference");
        assertLe(p, 1e18, "probability above 1");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_fundingCoversReferenceCostIncrease(
        uint256 b,
        uint256 yes,
        uint256 no,
        uint256 db
    ) public view {
        b = bound(b, 1e15, 1e30);
        yes = bound(yes, 0, 1e30);
        no = bound(no, 0, 1e30);
        db = bound(db, 1, 1e24);
        if (b + db > 1e36 / 2) return;
        uint256 deposit;
        try this.callFunding(b, yes, no, db) returns (uint256 funded) {
            deposit = funded;
        } catch {
            return;
        }
        (uint256 beforeLo, uint256 beforeHi) = LmsrReference.cost(b, yes, no);
        (uint256 afterLo, uint256 afterHi) = LmsrReference.cost(b + db, yes, no);
        // `afterHi - beforeLo` sums the slack of both brackets. On
        // b = 1e30 - 1e15 + 849, yes = 4, no = 10001, db = 1728000 that span
        // is 1197760 while `funding` returns 1197759. Decimal precision 100
        // puts the true increase at 1197758.328..., so the quote still covers
        // it. The check that stays inside the reference is the lower span.
        uint256 least = afterLo > beforeHi ? afterLo - beforeHi : 0;
        assertGe(deposit, least, "funding below minimum increase");
        assertLe(beforeLo, beforeHi, "reference bracket inverted");
        assertLe(afterLo, afterHi, "reference bracket inverted");
    }

    /// Pins the input where the loose upper span sits one unit above `funding`.
    function test_fundingCoversTrueCostWhenReferenceSpanIsOneHigh() public pure {
        uint256 b = 1e30 - 1e15 + 849;
        uint256 yes = 4;
        uint256 no = 10_001;
        uint256 db = 1_728_000;
        (uint256 beforeLo, uint256 beforeHi) = LmsrReference.cost(b, yes, no);
        (uint256 afterLo, uint256 afterHi) = LmsrReference.cost(b + db, yes, no);
        uint256 deposit = PositionPricing.funding(b, yes, no, db);
        assertEq(deposit, 1_197_759, "quoted funding");
        assertEq(afterHi - beforeLo, deposit + 1, "loose span is one above the quote");
        assertGe(deposit, afterLo > beforeHi ? afterLo - beforeHi : 0);
        assertLe(beforeLo, beforeHi, "reference bracket inverted");
        // True increase 1197758.328... from Decimal precision 100, so 1197759
        // is the ceiling. The loose span one unit higher is not a shortfall.
        assertGe(deposit, 1_197_759, "quote is the ceiling of the true increase");
    }

    function callFunding(uint256 b, uint256 yes, uint256 no, uint256 db)
        external
        pure
        returns (uint256)
    {
        return PositionPricing.funding(b, yes, no, db);
    }

    function test_referenceAndLibraryBracketPublishedFloors() public pure {
        _published(1e18, 0, 693_147_180_559_945_309);
        _published(1e18, 1e18, 1_313_261_687_518_222_834);
        _published(1e18, 5e18, 5_006_715_348_489_118_068);
        _published(1e18, 50e18, 50_000_000_000_000_000_000);
        _published(100e18, 0, 69_314_718_055_994_530_941);
        _published(1e30, 0, 693_147_180_559_945_309_417_232_121_458);
        _published(1e36, 0, 693_147_180_559_945_309_417_232_121_458_176_568);
    }

    function _published(uint256 b, uint256 yes, uint256 floor_) internal pure {
        (uint256 refLo, uint256 refHi) = LmsrReference.cost(b, yes, 0);
        assertLe(refLo, floor_, "reference above published floor");
        assertGe(refHi, floor_, "reference below published floor");
        _containsReference(b, yes, 0);
        (uint256 mirrorLo, uint256 mirrorHi) = LmsrReference.cost(b, 0, yes);
        assertEq(refLo, mirrorLo, "reference not symmetric");
        assertEq(refHi, mirrorHi, "reference not symmetric");
    }

    /// The WAD Taylor oracle suggested by the audit misses the library interval
    /// on an ordinary 50/50 cost. It is not used as the ground truth above.
    function test_coarseWadOracleSitsOutsideTheLibraryInterval() public pure {
        uint256 b = 1e18;
        uint256 coarse = LMSRMath.calculateCost(b, 0, 0, 1e18, 0);
        (uint256 lo, uint256 hi) = PositionPricing.costBounds(b, 1e18, 0);
        assertTrue(coarse < lo || coarse > hi, "coarse oracle unexpectedly fits");
        uint256 allowance = 2 * (Math.mulDiv(b, 4096, 1e36, Math.Rounding.Ceil) + 1);
        assertGt(_gap(coarse, lo, hi), allowance, "deviation inside series allowance");
    }

    function _gap(uint256 value, uint256 lo, uint256 hi) private pure returns (uint256) {
        if (value < lo) return lo - value;
        if (value > hi) return value - hi;
        return 0;
    }
}

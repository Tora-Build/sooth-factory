// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {PositionPricing as Pricing} from "../../src/libraries/PositionPricing.sol";

contract PositionPricingTest is Test {
    function check(uint256 b, uint256 yes, uint256 expectedFloor) internal pure {
        (uint256 lo, uint256 hi) = Pricing.costBounds(b, yes, 0);
        assertLe(lo, expectedFloor);
        assertGe(hi, expectedFloor + 1);
        (uint256 mirrorLo, uint256 mirrorHi) = Pricing.costBounds(b, 0, yes);
        assertEq(lo, mirrorLo);
        assertEq(hi, mirrorHi);
    }

    // Python Decimal precision=110, stable ln(1+exp(-q/b)); no binary float oracle.
    function test_highPrecisionCostVectors() public pure {
        check(1_000_000_000_000_000_000, 0, 693_147_180_559_945_309);
        check(1_000_000_000_000_000_000, 99_999_000_000_000_000, 744_396_135_094_508_103);
        check(1_000_000_000_000_000_000, 100_000_000_000_000_000, 744_396_660_073_570_894);
        check(1_000_000_000_000_000_000, 100_001_000_000_000_000, 744_397_185_052_883_061);
        check(
            1_000_000_000_000_000_000,
            1_000_000_000_000_000_000,
            1_313_261_687_518_222_834
        );
        check(
            1_000_000_000_000_000_000,
            5_000_000_000_000_000_000,
            5_006_715_348_489_118_068
        );
        check(
            1_000_000_000_000_000_000,
            20_000_000_000_000_000_000,
            20_000_000_002_061_153_620
        );
        check(
            1_000_000_000_000_000_000,
            50_000_000_000_000_000_000,
            50_000_000_000_000_000_000
        );
        check(
            1_000_000_000_000_000_000,
            100_000_000_000_000_000_000,
            100_000_000_000_000_000_000
        );
        check(100_000_000_000_000_000_000, 0, 69_314_718_055_994_530_941);
        check(
            100_000_000_000_000_000_000,
            9_999_900_000_000_000_000,
            74_439_613_509_450_810_391
        );
        check(
            100_000_000_000_000_000_000,
            10_000_000_000_000_000_000,
            74_439_666_007_357_089_483
        );
        check(
            100_000_000_000_000_000_000,
            10_000_100_000_000_000_000,
            74_439_718_505_288_306_178
        );
        check(
            100_000_000_000_000_000_000,
            100_000_000_000_000_000_000,
            131_326_168_751_822_283_404
        );
        check(
            100_000_000_000_000_000_000,
            500_000_000_000_000_000_000,
            500_671_534_848_911_806_861
        );
        check(
            100_000_000_000_000_000_000,
            2_000_000_000_000_000_000_000,
            2_000_000_000_206_115_362_031
        );
        check(
            100_000_000_000_000_000_000,
            5_000_000_000_000_000_000_000,
            5_000_000_000_000_000_000_000
        );
        check(
            100_000_000_000_000_000_000,
            10_000_000_000_000_000_000_000,
            10_000_000_000_000_000_000_000
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            0,
            693_147_180_559_945_309_417_232_121_458
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            99_999_000_000_000_000_000_000_000_000,
            744_396_135_094_508_103_912_285_853_570
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000_000_000,
            744_396_660_073_570_894_830_099_108_315
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            100_001_000_000_000_000_000_000_000_000,
            744_397_185_052_883_061_788_105_244_716
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            1_000_000_000_000_000_000_000_000_000_000,
            1_313_261_687_518_222_834_048_995_494_967
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            5_000_000_000_000_000_000_000_000_000_000,
            5_006_715_348_489_118_068_616_416_687_732
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            20_000_000_000_000_000_000_000_000_000_000,
            20_000_000_002_061_153_620_314_380_703_238
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            50_000_000_000_000_000_000_000_000_000_000,
            50_000_000_000_000_000_000_000_192_874_984
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000_000_000_000
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            0,
            693_147_180_559_945_309_417_232_121_458_176_568
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            99_999_000_000_000_000_000_000_000_000_000_000,
            744_396_135_094_508_103_912_285_853_570_196_616
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            100_000_000_000_000_000_000_000_000_000_000_000,
            744_396_660_073_570_894_830_099_108_315_658_041
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            100_001_000_000_000_000_000_000_000_000_000_000,
            744_397_185_052_883_061_788_105_244_716_072_957
        );
        check(
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            1_000_000_000_000_000_000_000_000_000_000_000_000,
            1_313_261_687_518_222_834_048_995_494_967_855_641
        );
    }

    function testFuzz_scalePreservesOdds(uint64 rawB, uint64 rawYes, uint8 rawScale)
        public
        pure
    {
        uint256 b = uint256(rawB) + 1e18;
        uint256 yes = uint256(rawYes);
        uint256 scale = uint256(rawScale) + 1;
        assertEq(
            Pricing.probability(b, yes, 0), Pricing.probability(b * scale, yes * scale, 0)
        );
    }

    function testFuzz_mirroredFundingAndUpwardBound(
        uint64 rawB,
        uint64 rawYes,
        uint64 rawDb
    ) public pure {
        uint256 b = uint256(rawB) + 1e18;
        uint256 yes = uint256(rawYes);
        uint256 db = uint256(rawDb) + 1;
        uint256 deposit = Pricing.funding(b, yes, 0, db);
        assertEq(deposit, Pricing.funding(b, 0, yes, db));
        // At 50/50 this is the smallest funding factor; skew cannot require less.
        assertGe(deposit, Pricing.funding(b, 0, 0, db));
    }

    function test_extremeOddsRemainComputable() public pure {
        (uint256 lo, uint256 hi) = Pricing.costBounds(1, 1e36, 0);
        assertLe(lo, 1e36);
        assertGe(hi, 1e36);
        assertEq(Pricing.probability(1, 1e36, 0), 1e18);
        assertEq(Pricing.probability(1, 0, 1e36), 0);
    }

    function cost(uint256 b, uint256 y, uint256 n)
        external
        pure
        returns (uint256, uint256)
    {
        return Pricing.costBounds(b, y, n);
    }

    function test_domainRejectsZeroAndOverflow() public {
        vm.expectRevert(Pricing.Domain.selector);
        this.cost(0, 0, 0);
        vm.expectRevert(Pricing.Domain.selector);
        this.cost(1e36 + 1, 0, 0);
        vm.expectRevert(Pricing.Domain.selector);
        this.cost(1, 1e36 + 1, 0);
    }

    function testFuzz_initialOddsRoundTrip(uint128 bSeed, uint64 priceSeed) public pure {
        uint256 b = 1e17 + uint256(bSeed) % 1e30;
        uint256 p = 1 + uint256(priceSeed) % (1e18 - 1);
        (uint256 yes, uint256 no) = Pricing.initialQuantities(b, p);
        assertApproxEqAbs(Pricing.probability(b, yes, no), p, 4);
        (uint256 mirrorYes, uint256 mirrorNo) = Pricing.initialQuantities(b, 1e18 - p);
        assertEq(yes, mirrorNo);
        assertEq(no, mirrorYes);
    }
}

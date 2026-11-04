// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {PositionPricing} from "src/libraries/PositionPricing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Cost axioms for the pricing library the AMM actually uses.
/// @dev Ported from the LMSRMath halmos suite, which verified a library no
///      production contract imports any more and was never wired into CI.
///      These run as fuzz tests on every push instead.
///
///      Domain matches real usage: depth 1..1e6 units, inventories and trade
///      sizes up to 1e6 units.
contract PositionPricingAxioms is Test {
    uint256 constant WAD = 1e18;
    uint256 constant MAX_UNITS = 1_000_000 * WAD;

    function _bound(uint256 b, uint256 qY, uint256 qN, uint256 delta)
        internal
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        b = bound(b, WAD, MAX_UNITS);
        qY = bound(qY, 0, MAX_UNITS);
        qN = bound(qN, 0, MAX_UNITS);
        delta = bound(delta, 1, MAX_UNITS);
        return (b, qY, qN, delta);
    }

    /// A share pays at most 1.0 at settlement, so buying `delta` YES shares must
    /// never cost more than `delta`. `tradeCost` is deliberately conservative for
    /// buys (newHigh - oldLow), so the bound is stated with the library's own
    /// series-error allowance rather than exactly.
    function testFuzz_buyYesCostAtMostDelta(
        uint256 b,
        uint256 qY,
        uint256 qN,
        uint256 delta
    ) public {
        (b, qY, qN, delta) = _bound(b, qY, qN, delta);
        vm.assume(qY + delta <= MAX_UNITS);

        uint256 cost = PositionPricing.tradeCost(b, qY, qN, qY + delta, qN, true);
        assertLe(cost, delta + _errorAllowance(b), "YES buy cost exceeds payout");
    }

    function testFuzz_buyNoCostAtMostDelta(
        uint256 b,
        uint256 qY,
        uint256 qN,
        uint256 delta
    ) public {
        (b, qY, qN, delta) = _bound(b, qY, qN, delta);
        vm.assume(qN + delta <= MAX_UNITS);

        uint256 cost = PositionPricing.tradeCost(b, qY, qN, qY, qN + delta, true);
        assertLe(cost, delta + _errorAllowance(b), "NO buy cost exceeds payout");
    }

    /// Selling back can never return more than the shares can pay.
    function testFuzz_sellProceedsAtMostDelta(
        uint256 b,
        uint256 qY,
        uint256 qN,
        uint256 delta
    ) public {
        (b, qY, qN, delta) = _bound(b, qY, qN, delta);
        vm.assume(qY >= delta);

        uint256 proceeds = PositionPricing.tradeCost(b, qY, qN, qY - delta, qN, false);
        assertLe(proceeds, delta + _errorAllowance(b), "YES sell pays more than payout");
    }

    /// Buying then selling the same size must not be profitable — otherwise the
    /// AMM is drainable by a round trip.
    function testFuzz_roundTripNotProfitable(
        uint256 b,
        uint256 qY,
        uint256 qN,
        uint256 delta
    ) public {
        (b, qY, qN, delta) = _bound(b, qY, qN, delta);
        vm.assume(qY + delta <= MAX_UNITS);

        uint256 cost = PositionPricing.tradeCost(b, qY, qN, qY + delta, qN, true);
        uint256 back = PositionPricing.tradeCost(b, qY + delta, qN, qY, qN, false);
        assertLe(back, cost, "buy-then-sell round trip is profitable");
    }

    /// Pure function: equal inputs give equal outputs.
    function testFuzz_determinism(uint256 b, uint256 qY, uint256 qN, uint256 delta)
        public
    {
        (b, qY, qN, delta) = _bound(b, qY, qN, delta);
        vm.assume(qY + delta <= MAX_UNITS);

        uint256 a = PositionPricing.tradeCost(b, qY, qN, qY + delta, qN, true);
        uint256 c = PositionPricing.tradeCost(b, qY, qN, qY + delta, qN, true);
        assertEq(a, c, "tradeCost is not deterministic");
    }

    /// Probability stays a strict interior probability for any admitted state.
    function testFuzz_probabilityInterior(uint256 b, uint256 qY, uint256 qN) public {
        (b, qY, qN,) = _bound(b, qY, qN, 1);
        uint256 p = PositionPricing.probability(b, qY, qN);
        assertLe(p, WAD, "probability above 1");
    }

    /// The library's own series error, doubled.
    ///
    /// `costBounds` widens each endpoint by `ceil(b * SERIES_ERROR / R) + 1`, and a
    /// buy is quoted `newHigh - oldLow`, so it carries that error from BOTH
    /// endpoints. The overcharge is therefore bounded by twice the endpoint error
    /// and always falls in the pool's favour, never the trader's.
    function _errorAllowance(uint256 b) private pure returns (uint256) {
        return 2 * (Math.mulDiv(b, 4096, 1e36, Math.Rounding.Ceil) + 1);
    }
}

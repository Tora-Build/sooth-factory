// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Bounded binary LMSR primitives for the separate-position integration.
/// @dev WAD amounts, 36-decimal internal series. AMM buys use upper cost deltas;
/// sells use lower deltas. MarketFactory bootstrap uses the upper cost endpoint.
library PositionPricing {
    uint256 internal constant R = 1e36;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_AMOUNT = 1e36;
    /// @dev Depth admitted by bootstrap or liquidity additions is capped at half the
    ///      arithmetic domain so fee-driven CAPITAL growth cannot immediately exhaust it.
    ///      This is a checked arithmetic constraint, not an economic cap.
    uint256 internal constant MAX_ADMITTED_DEPTH = MAX_AMOUNT / 2;
    uint256 internal constant LN2 = 693_147_180_559_945_309_417_232_121_458_176_568;
    uint256 internal constant SERIES_ERROR = 4096;

    error Domain();

    /// @notice Minimal nonnegative virtual inventory for an interior YES probability.
    function initialQuantities(uint256 b, uint256 p)
        internal
        pure
        returns (uint256 yes, uint256 no)
    {
        require(p > 0 && p < WAD && b > 0 && b <= MAX_ADMITTED_DEPTH, Domain());
        uint256 larger = p >= WAD - p ? p : WAD - p;
        uint256 smaller = WAD - larger;
        uint256 ratio = Math.mulDiv(larger, R, smaller);
        uint256 logRatio;
        while (ratio > 2 * R) {
            ratio /= 2;
            logRatio += LN2;
        }
        logRatio += logOneToTwo(ratio);
        uint256 quantity = Math.mulDiv(b, logRatio, R);
        if (p >= WAD / 2) yes = quantity;
        else no = quantity;
        validate(b, yes, no);
    }

    function tradeCost(
        uint256 b,
        uint256 oldYes,
        uint256 oldNo,
        uint256 newYes,
        uint256 newNo,
        bool buy
    ) internal pure returns (uint256) {
        (uint256 oldLow,) = costBounds(b, oldYes, oldNo);
        (, uint256 newHigh) = costBounds(b, newYes, newNo);
        if (buy) return newHigh - oldLow;
        return oldLow > newHigh ? oldLow - newHigh : 0;
    }

    function validate(uint256 b, uint256 yes, uint256 no) internal pure {
        require(
            b > 0 && b <= MAX_AMOUNT && yes <= MAX_AMOUNT && no <= MAX_AMOUNT, Domain()
        );
    }

    // Input in [1,2]. atanh expansion with t <= 1/3; 64 terms.
    function logOneToTwo(uint256 value) internal pure returns (uint256 result) {
        require(value >= R && value <= 2 * R, Domain());
        uint256 t = Math.mulDiv(value - R, R, value + R);
        uint256 t2 = Math.mulDiv(t, t, R);
        uint256 term = t;
        for (uint256 i; i < 64; i++) {
            result += term / (2 * i + 1);
            term = Math.mulDiv(term, t2, R);
        }
        return 2 * result;
    }

    // Reduction by ln(2) keeps the positive Taylor argument below ln(2).
    function expNegative(uint256 x) internal pure returns (uint256) {
        if (x >= 100 * R) return 0;
        uint256 powers = x / LN2;
        uint256 remainder = x % LN2;
        uint256 total = R;
        uint256 term = R;
        for (uint256 i = 1; i <= 64; i++) {
            term = Math.mulDiv(term, remainder, R) / i;
            total += term;
        }
        return Math.mulDiv(R, R, total) >> powers;
    }

    function softplus(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256)
    {
        uint256 difference = yes >= no ? yes - no : no - yes;
        uint256 odds = Math.mulDiv(difference, R, b);
        return logOneToTwo(R + expNegative(odds));
    }

    function costBounds(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256 low, uint256 high)
    {
        validate(b, yes, no);
        uint256 maximum = yes >= no ? yes : no;
        uint256 estimate = maximum + Math.mulDiv(b, softplus(b, yes, no), R);
        uint256 error = Math.mulDiv(b, SERIES_ERROR, R, Math.Rounding.Ceil) + 1;
        low = estimate > error ? estimate - error : 0;
        high = estimate + error;
    }

    function probability(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256)
    {
        validate(b, yes, no);
        uint256 difference = yes >= no ? yes - no : no - yes;
        uint256 e = expNegative(Math.mulDiv(difference, R, b));
        return yes >= no ? Math.mulDiv(WAD, R, R + e) : Math.mulDiv(WAD, e, R + e);
    }

    /// @dev Upper endpoint for funding db at current odds, rounded up to WAD.
    function funding(uint256 b, uint256 yes, uint256 no, uint256 db)
        internal
        pure
        returns (uint256)
    {
        validate(b, yes, no);
        require(db > 0 && b + db <= MAX_ADMITTED_DEPTH, Domain());
        uint256 difference = yes >= no ? yes - no : no - yes;
        // AMM retains fractional pricing inventory; whole-WAD views may differ
        // from its true quantity difference by less than one WAD quantum.
        uint256 oddsUpper = Math.mulDiv(difference + 1, R, b, Math.Rounding.Ceil);
        uint256 factorUpper = oddsUpper + softplus(b, yes, no) + SERIES_ERROR;
        uint256 deposit = Math.mulDiv(db, factorUpper, R, Math.Rounding.Ceil);
        require(deposit <= MAX_AMOUNT, Domain());
        return deposit;
    }

    function weightBuffer(uint256 b, uint256 yes, uint256 no, uint256 weight)
        internal
        pure
        returns (uint256)
    {
        uint256 difference = yes >= no ? yes - no : no - yes;
        uint256 maxLossUpper = difference + 1
            + Math.mulDiv(b, softplus(b, yes, no) + SERIES_ERROR, R, Math.Rounding.Ceil);
        return Math.ceilDiv(maxLossUpper, weight);
    }
}

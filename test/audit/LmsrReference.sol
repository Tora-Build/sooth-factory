// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Independent 36-decimal bracket for binary LMSR cost.
/// @dev This is not `test/reference/LMSRMath.sol`. That oracle is a short WAD
///      Taylor series and is coarser than `PositionPricing`'s published error,
///      so it cannot certify `costBounds`. The bracket below uses a different
///      reduction (base-2 exp, then artanh) with every multiplication rounded
///      both down and up. Checked against Python `Decimal` (precision 80) on
///      random inputs across the full `1 .. 1e36` domain before these tests
///      were committed: the integer bracket contained the true cost, and the
///      widest gap on that sample was under 200 units.
library LmsrReference {
    uint256 internal constant ONE = 1e36;
    uint256 internal constant WAD = 1e18;
    /// @dev Floor of ln(2) * 1e36. The next digit is nonzero, so the true value
    ///      sits strictly between LN2 and LN2 + 1.
    uint256 internal constant LN2 = 693_147_180_559_945_309_417_232_121_458_176_568;

    /// @notice Integer bracket around `max(yes, no) + b * ln(1 + exp(-|yes-no|/b))`.
    function cost(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256 lo, uint256 hi)
    {
        require(b > 0, "b");
        uint256 maximum = yes >= no ? yes : no;
        uint256 diff = yes >= no ? yes - no : no - yes;
        uint256 xFloor = Math.mulDiv(diff, ONE, b);
        uint256 xCeil = diff == 0 ? 0 : Math.mulDiv(diff, ONE, b, Math.Rounding.Ceil);
        (uint256 zLo,) = _softplus(xCeil);
        (, uint256 zHi) = _softplus(xFloor);
        lo = maximum + Math.mulDiv(b, zLo, ONE);
        hi = maximum + Math.mulDiv(b, zHi, ONE, Math.Rounding.Ceil);
    }

    /// @notice Integer bracket around the YES probability, in WAD.
    function probability(uint256 b, uint256 yes, uint256 no)
        internal
        pure
        returns (uint256 lo, uint256 hi)
    {
        require(b > 0, "b");
        uint256 diff = yes >= no ? yes - no : no - yes;
        uint256 xFloor = Math.mulDiv(diff, ONE, b);
        uint256 xCeil = diff == 0 ? 0 : Math.mulDiv(diff, ONE, b, Math.Rounding.Ceil);
        (uint256 ySmallLo,) = _expNeg(xCeil);
        (, uint256 yLargeHi) = _expNeg(xFloor);
        if (yes >= no) {
            lo = Math.mulDiv(WAD, ONE, ONE + yLargeHi);
            hi = Math.mulDiv(WAD, ONE, ONE + ySmallLo, Math.Rounding.Ceil);
        } else {
            lo = Math.mulDiv(WAD, ySmallLo, ONE + ySmallLo);
            hi = Math.mulDiv(WAD, yLargeHi, ONE + yLargeHi, Math.Rounding.Ceil);
        }
        if (hi > WAD) hi = WAD;
    }

    function _softplus(uint256 x) private pure returns (uint256 lo, uint256 hi) {
        if (x == 0) return (LN2, LN2 + 1);
        (uint256 yLo, uint256 yHi) = _expNeg(x);
        (lo,) = _ln1pOne(yLo > ONE ? ONE : yLo);
        (, hi) = _ln1pOne(yHi > ONE ? ONE : yHi);
        if (yHi > ONE) {
            uint256 bumped = LN2 + 1 + (yHi - ONE);
            if (bumped > hi) hi = bumped;
        }
    }

    /// @dev `y` brackets `exp(-x) * 1e36` for `x` scaled by 1e36.
    function _expNeg(uint256 x) private pure returns (uint256 yLo, uint256 yHi) {
        if (x == 0) return (ONE, ONE);
        if (x >= 80 * ONE) return (0, 1);
        uint256 n = x / LN2;
        uint256 r = x % LN2;
        (uint256 eLo, uint256 eHi) = _expTaylor(r);
        yLo = (ONE * ONE) / eHi;
        yHi = _ceilDiv(ONE * ONE, eLo);
        if (n > 0) {
            yLo >>= n;
            yHi = _ceilDiv(yHi, uint256(1) << n);
        }
    }

    /// @dev Bracket of `exp(r / 1e36) * 1e36` for `r < ln(2) * 1e36`.
    function _expTaylor(uint256 x) private pure returns (uint256 lo, uint256 hi) {
        uint256 termLo = ONE;
        uint256 termHi = ONE;
        lo = ONE;
        hi = ONE;
        for (uint256 i = 1; i < 49; ++i) {
            termLo = Math.mulDiv(termLo, x, ONE) / i;
            termHi = _ceilDiv(Math.mulDiv(termHi, x, ONE, Math.Rounding.Ceil), i);
            lo += termLo;
            hi += termHi;
        }
        hi += 1;
    }

    /// @dev Bracket of `ln(1 + y/1e36) * 1e36` for `y <= 1e36`, via artanh.
    function _ln1pOne(uint256 y) private pure returns (uint256 lo, uint256 hi) {
        if (y == 0) return (0, 0);
        if (y > ONE) y = ONE;
        uint256 denom = y + 2 * ONE;
        uint256 tLo = Math.mulDiv(y, ONE, denom);
        uint256 tHi = Math.mulDiv(y, ONE, denom, Math.Rounding.Ceil);
        uint256 t2Lo = Math.mulDiv(tLo, tLo, ONE);
        uint256 t2Hi = Math.mulDiv(tHi, tHi, ONE, Math.Rounding.Ceil);
        uint256 termLo = tLo;
        uint256 termHi = tHi;
        uint256 sumLo;
        uint256 sumHi;
        for (uint256 i; i < 60; ++i) {
            uint256 d = 2 * i + 1;
            sumLo += termLo / d;
            sumHi += _ceilDiv(termHi, d);
            termLo = Math.mulDiv(termLo, t2Lo, ONE);
            uint256 nextHi = Math.mulDiv(termHi, t2Hi, ONE, Math.Rounding.Ceil);
            if (nextHi == 0) break;
            termHi = nextHi;
        }
        lo = sumLo * 2;
        hi = sumHi * 2 + 1;
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0) return 0;
        return (a + b - 1) / b;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title LMSRMath
 * @notice Logarithmic Market Scoring Rule math library with WAD precision
 * @dev Implements continuous LMSR pricing for binary prediction markets
 *      All values use WAD precision (1e18 = 1 unit)
 */
/// @dev TEST-ONLY REFERENCE ORACLE. No production contract imports this; the AMM
///      prices through `src/libraries/PositionPricing.sol`. It is retained purely so
///      `TradePipelineReorder.t.sol` can check the trade pipeline against an
///      independent implementation of the same maths. Do not import it from `src/`.
library LMSRMath {
    // ============================================
    // Constants
    // ============================================

    uint256 private constant WAD = 1e18;
    int256 private constant WAD_INT = int256(WAD);
    int256 private constant LN2_WAD = 693_147_180_559_945_309; // ln(2) in WAD

    // ============================================
    // Errors
    // ============================================

    error NegativeCost();
    error NegativeInput();
    error NonPositiveInput();
    error InvalidProbability();

    // ============================================
    // Core LMSR Functions
    // ============================================

    /**
     * @notice Calculate cost to buy shares using LMSR
     * @dev Cost = b * ln(e^(qYes'/b) + e^(qNo'/b)) - b * ln(e^(qYes/b) + e^(qNo/b))
     * @param b Liquidity parameter (WAD)
     * @param qYesBefore YES quantity before trade (WAD)
     * @param qNoBefore NO quantity before trade (WAD)
     * @param qYesAfter YES quantity after trade (WAD)
     * @param qNoAfter NO quantity after trade (WAD)
     * @return cost Cost in Base Token (WAD, always positive)
     */
    function calculateCost(
        uint256 b,
        uint256 qYesBefore,
        uint256 qNoBefore,
        uint256 qYesAfter,
        uint256 qNoAfter
    ) internal pure returns (uint256 cost) {
        // C(q') - C(q) where C(q) = b * ln(e^(qYes/b) + e^(qNo/b))
        int256 costBefore = logSumExp(b, qYesBefore, qNoBefore);
        int256 costAfter = logSumExp(b, qYesAfter, qNoAfter);

        int256 delta = costAfter - costBefore;
        require(delta >= 0, NegativeCost());

        return uint256(delta);
    }

    /**
     * @notice Calculate log-sum-exp: b * ln(e^(qYes/b) + e^(qNo/b))
     * @dev Uses log-sum-exp trick for numerical stability
     * @param b Liquidity parameter (WAD)
     * @param qYes YES quantity (WAD)
     * @param qNo NO quantity (WAD)
     * @return result b * ln(e^(qYes/b) + e^(qNo/b)) in WAD
     */
    function logSumExp(uint256 b, uint256 qYes, uint256 qNo)
        internal
        pure
        returns (int256 result)
    {
        // Use the log-sum-exp trick: ln(e^a + e^b) = max(a,b) + ln(1 + e^(-|a-b|))
        int256 a = int256((qYes * WAD) / b);
        int256 bVal = int256((qNo * WAD) / b);

        int256 maxVal = a > bVal ? a : bVal;
        int256 diff = a > bVal ? a - bVal : bVal - a;

        // ln(1 + e^(-diff))
        int256 lnOnePlusExp = ln1PlusExp(diff);

        // b * (max + ln(1 + e^(-diff)))
        result = int256((b * uint256(maxVal + lnOnePlusExp)) / WAD);
    }

    /**
     * @notice Calculate ln(1 + e^(-x)) for x >= 0
     * @dev Approximation for numerical stability
     * @param x Input value (WAD)
     * @return ln(1 + e^(-x)) in WAD
     */
    function ln1PlusExp(int256 x) internal pure returns (int256) {
        require(x >= 0, NegativeInput());

        // For large x, ln(1 + e^(-x)) ≈ e^(-x)
        if (x > 20 * WAD_INT) {
            return exp(-x);
        }

        // For small x, use Taylor series: ln(1 + e^(-x)) ≈ ln(2) - x/2 + x^2/8
        if (x < WAD_INT / 10) {
            int256 term1 = LN2_WAD;
            int256 term2 = -x / 2;
            int256 term3 = (x * x) / (8 * WAD_INT);
            return term1 + term2 + term3;
        }

        // Medium range: use exp approximation
        int256 expNegX = exp(-x);
        return ln(WAD_INT + expNegX);
    }

    /**
     * @notice Natural logarithm (ln) approximation
     * @dev Uses Taylor series for ln(1+x)
     * @param x Input value (WAD, must be > 0)
     * @return ln(x) in WAD
     */
    function ln(int256 x) internal pure returns (int256) {
        require(x > 0, NonPositiveInput());

        // Normalize to range [0.5, 1.5] for better convergence
        int256 expVal = 0;
        int256 normalized = x;

        while (normalized > (3 * WAD_INT) / 2) {
            normalized = normalized / 2;
            expVal += LN2_WAD; // ln(2)
        }

        while (normalized < WAD_INT / 2) {
            normalized = normalized * 2;
            expVal -= LN2_WAD; // ln(2)
        }

        // Taylor series for ln(1 + y) where y = normalized - 1
        int256 y = normalized - WAD_INT;
        int256 result = y;
        int256 term = y;

        for (uint256 i = 2; i < 11; i++) {
            term = (term * y) / WAD_INT;
            if (i % 2 == 0) {
                result -= term / int256(i);
            } else {
                result += term / int256(i);
            }
        }

        return result + expVal;
    }

    /**
     * @notice Exponential function approximation
     * @dev Uses Taylor series
     * @param x Input value (WAD)
     * @return e^x in WAD
     */
    function exp(int256 x) internal pure returns (int256) {
        // Handle negative exponents
        if (x < 0) {
            return (WAD_INT * WAD_INT) / exp(-x);
        }

        // For large x, return max to prevent overflow
        if (x > 50 * WAD_INT) {
            return type(int256).max / 2;
        }

        // Taylor series: e^x = 1 + x + x^2/2! + x^3/3! + ...
        int256 result = WAD_INT;
        int256 term = WAD_INT;

        for (uint256 i = 1; i < 21; i++) {
            term = (term * x) / (WAD_INT * int256(i));
            result += term;

            if (term < 100) break; // Convergence threshold
        }

        return result;
    }

    // ============================================
    // Price Calculations
    // ============================================

    /**
     * @notice Calculate YES probability from quantities
     * @dev P(YES) = e^(qYes/b) / (e^(qYes/b) + e^(qNo/b))
     * @param b Liquidity parameter (WAD)
     * @param qYes YES quantity (WAD)
     * @param qNo NO quantity (WAD)
     * @return probability YES probability (WAD, 0-1e18)
     */
    function calculateProbability(uint256 b, uint256 qYes, uint256 qNo)
        internal
        pure
        returns (uint256 probability)
    {
        // Use log-space for numerical stability
        // IMPORTANT: qYes*WAD - qNo*WAD must be done in signed space to avoid uint underflow when qNo > qYes.
        int256 diff = int256(qYes) - int256(qNo); // signed WAD shares
        int256 logOdds = (diff * int256(WAD)) / int256(b); // signed WAD

        // P = 1 / (1 + e^(-logOdds)) = e^logOdds / (1 + e^logOdds)
        if (logOdds >= 0) {
            int256 expLogOdds = exp(logOdds);
            probability = uint256((expLogOdds * WAD_INT) / (WAD_INT + expLogOdds));
        } else {
            int256 expNegLogOdds = exp(-logOdds);
            probability = uint256((WAD_INT * WAD_INT) / (WAD_INT + expNegLogOdds));
        }
    }

    /**
     * @notice Calculate new quantities after buying deltaShares
     * @param qYes Current YES quantity (WAD)
     * @param qNo Current NO quantity (WAD)
     * @param deltaShares Shares to buy (positive = YES, negative = NO, WAD)
     * @return newQYes New YES quantity
     * @return newQNo New NO quantity
     */
    function calculateNewQuantities(uint256 qYes, uint256 qNo, int256 deltaShares)
        internal
        pure
        returns (uint256 newQYes, uint256 newQNo)
    {
        if (deltaShares > 0) {
            // Buying YES
            newQYes = qYes + uint256(deltaShares);
            newQNo = qNo;
        } else {
            // Buying NO (selling YES)
            newQYes = qYes;
            newQNo = qNo + uint256(-deltaShares);
        }
    }

    /**
     * @notice Calculate initial quantities from a probability
     * @dev Uses logit: qYes - qNo = b * ln(p / (1-p))
     *      If p > 0.5: qYes = b * ln(p/(1-p)), qNo = 0
     *      If p < 0.5: qYes = 0, qNo = b * ln((1-p)/p)
     *      If p = 0.5: qYes = qNo = 0
     * @param b Liquidity parameter (WAD)
     * @param probabilityWad Initial YES probability (WAD, must be in (0, 1e18))
     * @return qYes Initial YES quantity (WAD)
     * @return qNo Initial NO quantity (WAD)
     */
    function calculateInitialQuantities(uint256 b, uint256 probabilityWad)
        internal
        pure
        returns (uint256 qYes, uint256 qNo)
    {
        require(
            probabilityWad > 0 && probabilityWad < uint256(WAD_INT), InvalidProbability()
        );

        // p = 0.5 → equal quantities at zero
        if (probabilityWad == uint256(WAD_INT) / 2) {
            return (0, 0);
        }

        if (probabilityWad > uint256(WAD_INT) / 2) {
            // logit = ln(p / (1-p))
            int256 p = int256(probabilityWad);
            int256 oneMinusP = WAD_INT - p;
            // ratio = p / (1-p) in WAD
            int256 ratio = (p * WAD_INT) / oneMinusP;
            int256 logit = ln(ratio);
            // qYes = b * logit / WAD
            qYes = uint256((int256(b) * logit) / WAD_INT);
            qNo = 0;
        } else {
            // Symmetric: logit = ln((1-p) / p)
            int256 p = int256(probabilityWad);
            int256 oneMinusP = WAD_INT - p;
            int256 ratio = (oneMinusP * WAD_INT) / p;
            int256 logit = ln(ratio);
            qYes = 0;
            qNo = uint256((int256(b) * logit) / WAD_INT);
        }
    }
}

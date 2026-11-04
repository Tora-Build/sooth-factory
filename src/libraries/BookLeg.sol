// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Pure arithmetic for the single-axis, gross-inventory book.
/// @dev Ownership is not inferred from a signed net position.
library BookLeg {
    uint8 internal constant BUY = 0;
    uint8 internal constant SELL = 1;
    uint8 internal constant SIDE_BID = 0;
    uint8 internal constant SIDE_ASK = 1;
    uint16 internal constant NUM_TICKS = 1000;

    function normalize(uint8 action, uint8 outcome, uint16 priceTick)
        internal
        pure
        returns (uint8 side, uint16 yesTick)
    {
        side = (action == BUY) == (outcome == 1) ? SIDE_BID : SIDE_ASK;
        yesTick = outcome == 1 ? priceTick : NUM_TICKS - priceTick;
    }

    function outcomeTick(uint8 outcome, uint16 yesTick) internal pure returns (uint16) {
        return outcome == 1 ? yesTick : NUM_TICKS - yesTick;
    }

    function reserveCash(uint16 priceTick, uint256 amount, uint256 unit)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = (amount / unit) * priceTick;
        return (numerator + NUM_TICKS - 1) / NUM_TICKS;
    }

    /// @dev BUY consumes the difference of remaining reserves. SELL pays the
    /// difference of cumulative floors. Splitting fills never resets the carry.
    function makerCash(
        uint8 action,
        uint16 priceTick,
        uint128 originalAmount,
        uint128 remaining,
        uint128 fill,
        uint256 cashReserved,
        uint256 unit
    ) internal pure returns (uint256) {
        if (action == BUY) {
            return cashReserved - reserveCash(priceTick, remaining - fill, unit);
        }
        uint256 beforeFilled = (uint256(originalAmount) - remaining) / unit;
        uint256 afterFilled = beforeFilled + uint256(fill) / unit;
        return afterFilled * priceTick / NUM_TICKS - beforeFilled * priceTick / NUM_TICKS;
    }

    function feeNative(uint256 basis, uint256 bps, uint256 unit)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = basis * bps;
        uint256 denominator = uint256(NUM_TICKS) * 10_000 * unit;
        return numerator / denominator + (numerator % denominator == 0 ? 0 : 1);
    }
}

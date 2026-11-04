// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title DecimalMath
 * @notice Shared utility for WAD (18 decimal) to token decimal conversions
 * @dev Used by AMMEngine, MarketFactory, OrderEngine, and FeeVault
 *
 * Conversion rules:
 *   - TO contract (user pays): use ceiling to avoid underpayment
 *   - FROM contract (user receives): use floor to avoid overpayment
 */
library DecimalMath {
    uint256 private constant WAD = 1e18;

    /**
     * @notice Convert token decimals to WAD (18 decimals)
     * @param amount Amount in token decimals
     * @param tokenDecimals The token's decimal count
     * @return WAD-scaled amount
     */
    function toWad(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) {
            return amount;
        } else if (tokenDecimals < 18) {
            return amount * (10 ** (18 - tokenDecimals));
        } else {
            return amount / (10 ** (tokenDecimals - 18));
        }
    }

    /**
     * @notice Convert WAD to token decimals (floor - for outbound transfers)
     * @param wadAmount Amount in WAD
     * @param tokenDecimals The token's decimal count
     * @return Token-scaled amount (rounded down)
     */
    function fromWad(uint256 wadAmount, uint8 tokenDecimals)
        internal
        pure
        returns (uint256)
    {
        if (tokenDecimals == 18) {
            return wadAmount;
        } else if (tokenDecimals < 18) {
            return wadAmount / (10 ** (18 - tokenDecimals));
        } else {
            return wadAmount * (10 ** (tokenDecimals - 18));
        }
    }

    /**
     * @notice Convert WAD to token decimals (ceiling - for inbound transfers)
     * @param wadAmount Amount in WAD
     * @param tokenDecimals The token's decimal count
     * @return Token-scaled amount (rounded up)
     */
    function fromWadCeil(uint256 wadAmount, uint8 tokenDecimals)
        internal
        pure
        returns (uint256)
    {
        if (wadAmount == 0) return 0;
        if (tokenDecimals == 18) {
            return wadAmount;
        } else if (tokenDecimals < 18) {
            uint256 factor = 10 ** (18 - tokenDecimals);
            return (wadAmount + factor - 1) / factor;
        } else {
            return wadAmount * (10 ** (tokenDecimals - 18));
        }
    }
}

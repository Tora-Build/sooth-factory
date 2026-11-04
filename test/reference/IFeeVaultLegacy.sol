// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Minimal historical fee ABI used by the frozen OrderEngineV040 oracle.
/// @dev This is test-only compatibility, not successor fee policy. Preserve enum
///      ordinals and call signatures so the reference book's algorithm is unchanged.
interface IFeeVaultLegacy {
    enum Venue {
        AMM,
        BOOK
    }

    function feeBpsOf(address market, Venue venue) external view returns (uint16);

    function notifyDeposit(
        address market,
        Venue venue,
        address token,
        uint256 expected,
        uint256 preBalance
    ) external returns (uint256 credited);
}

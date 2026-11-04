// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title MockMinimalAdjudicator
 * @notice Bare-minimum adjudicator mock that accepts configureMarket with any (including empty) config.
 * @dev Used by tests that only need a valid adjudicator address and don't test adjudicator-specific logic.
 */
contract MockMinimalAdjudicator {
    function configureMarket(address, bytes calldata) external {}
}

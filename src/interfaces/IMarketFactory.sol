// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOrderEngine} from "./IOrderEngine.sol";

/// @notice Atomic node-market creation with bounded funding and pinned venue policies.
interface IMarketFactory {
    struct MarketParams {
        string question;
        uint64 startTime;
        uint64 deadline;
        address adjudicator;
        address tokenA;
        uint256 bBase;
        uint256 initialProbabilityWad;
        bytes adjudicatorConfig;
        uint256 maxInputNative;
        uint64 quoteDeadline;
        uint32 expectedAmmVersion;
        uint32 expectedBookVersion;
        bytes32 expectedAmmHash;
        bytes32 expectedBookHash;
        bytes32 resolutionTermsHash;
        bytes32 expectedProfileHash;
        uint64 expectedInvalidationBuffer;
    }

    event MarketCreated(
        address indexed market,
        address indexed creator,
        string question,
        uint64 startTime,
        uint64 deadline,
        address tokenA,
        uint8 tokenADecimals,
        uint256 bBase,
        address adjudicator,
        uint256 lpPositionId,
        uint256 nonce
    );
    event MarketCommitted(
        address indexed market,
        bytes32 indexed termsHash,
        bytes32 indexed profileHash,
        uint32 ammVersion,
        uint32 bookVersion,
        bytes32 ammHash,
        bytes32 bookHash
    );
    event LPTokenCreated(address indexed market, uint256 indexed lpPositionId);
    event InvalidationBufferUpdated(uint64 buffer);

    /// @notice Atomically fund and register both venues, issuing initial LP units to the caller.
    /// @dev The authenticated caller pays from its own token balance and is bound into the
    ///      market terms. No independent payer or initial LP beneficiary can be supplied.
    function createMarket(MarketParams calldata params)
        external
        returns (address market, uint256 lpPositionId);
    function creatorNonce(address creator) external view returns (uint256);
    function predictMarketAddress(
        address creator,
        MarketParams calldata params,
        uint256 nonce
    ) external view returns (address);
    function getMarkets() external view returns (address[] memory);
    function getMarketCount() external view returns (uint256);
    /// @notice Exposure pause is not implemented in this release; returns false.
    function isPaused() external view returns (bool);
    function getLPToken(address market) external view returns (uint256);
    function orderEngine() external view returns (IOrderEngine);
    function markets(address market)
        external
        view
        returns (
            address creator,
            uint256 lpPositionId,
            address tokenA,
            uint8 tokenADecimals,
            uint256 bBase,
            uint256 creatorDeposit
        );
}

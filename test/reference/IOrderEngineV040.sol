// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// FROZEN 0.4.0 REFERENCE — TEST ONLY. DO NOT EDIT, DO NOT IMPORT FROM `src/`.
///
/// The 0.4.0 `IOrderEngine`: `mint`, `merge` and the `escrow` flag still present.
///
/// Source: `src/interfaces/IOrderEngine.sol` at an earlier revision
///         (`ce65c68`, the two-ladder escrow-flagged book, before ADR-0008).
/// Vendored: 2026-10-07, for `test/integration/BookDifferential.t.sol`, which
/// replays one operation sequence against this engine and the single-axis one and
/// asserts they agree. ADR-0008 stage 4 calls this the confidence gate: stage 3's
/// tests had to change alongside its code, so a green suite there proves only that
/// the tests match the implementation. This file is the independent oracle.
///
/// Mechanical edits, and nothing else:
///   1. `interface IOrderEngine` renamed to `IOrderEngineV040`, so both
///      interfaces can coexist in one test compilation unit.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IOrderEngine
 * @notice The on-chain order book together with custody and settlement for the
 *         trades it matches.
 * @dev There is one settlement path and it is internal. The book and the custody
 *      ledger used to be two contracts (SoothBook and OrderEngine) so that an
 *      off-chain CLOB operator could drive custody through an EIP-712 signed-order
 *      surface. ADR-0007 removed that surface, and with one client left the two
 *      contracts were merged. There is no operator role, no signature
 *      verification, no filler, and no externally callable custody entry point.
 *
 *      Users approve this contract directly — single transfer, no intermediary
 *      custody. Collateral movement for resting orders and cancel refunds happens
 *      inside the same contract that owns the queue, so it needs no cross-contract
 *      authorization at all. `test/unit/MergedBookAuthorization.t.sol` asserts by
 *      selector that the former filler entry points stayed unreachable.
 */
interface IOrderEngineV040 {
    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a market is atomically registered at creation.
    /// @dev `baseToken` is always this engine's own custody token (never the
    ///      caller-supplied parameter).
    event MarketRegistered(
        address indexed market, address baseToken, uint256 initialPrice
    );

    /// @notice Canonical fill record — emitted for every matched trade across all venues
    event FillRecorded(
        address indexed market,
        address indexed taker,
        address indexed maker,
        uint8 takerSide,
        uint128 shares,
        uint16 yesTick,
        uint16 noTick,
        uint256 fillId
    );

    // ============================================
    // Market Registration
    // ============================================

    /**
     * @notice Register a newly created market for orderbook trading
     * @dev Called by MarketFactory in the same transaction as AMM initialization.
     * @param market TruthMarket address
     * @param baseToken IGNORED — retained for ABI compatibility only. Custody uses
     *        this engine's own immutable book token, and that is what the
     *        MarketRegistered event carries.
     * @param initialPrice Initial YES probability in WAD (from the initialized AMM)
     */
    function registerMarket(address market, address baseToken, uint256 initialPrice)
        external;

    // ============================================
    // Fills
    // ============================================

    // ============================================
    // User-Facing Complete Set Ops
    // ============================================

    /**
     * @notice Mint a complete YES/NO set by depositing collateral
     * @param market TruthMarket address
     * @param amount Complete-set amount in WAD
     */
    function mint(address market, uint256 amount) external;

    /**
     * @notice Merge a complete YES/NO set back into collateral
     * @param market TruthMarket address
     * @param amount Complete-set amount in WAD
     */
    function merge(address market, uint256 amount) external;

    // ============================================
    // Token Custody — Deposits (Deadline-Gated)
    // ============================================

    // ============================================
    // Token Custody — Withdrawals (No Deadline)
    // ============================================

    // ============================================
    // Position Management
    // ============================================

    // ============================================
    // Queries — Positions
    // ============================================

    /// @notice The node-wide book collateral token pinned at construction.
    function baseToken() external view returns (IERC20);

    function getPosition(address market, address user)
        external
        view
        returns (uint256 yesShares, uint256 noShares);

    // ============================================
    // Trading Guards
    // ============================================

    /**
     * @notice Revert unless TruthMarket.isTradingOpen() is true
     * @param market TruthMarket address
     */
    function requireBeforeDeadline(address market) external view;

    // ============================================
    // Queries
    // ============================================

    function getCollateralBacking(address market) external view returns (uint256);
    function isMarketRegistered(address market) external view returns (bool);
    function fillCount() external view returns (uint256);
}

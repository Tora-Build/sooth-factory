// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title ITruthMarket
 * @notice Canonical source of truth for market state.
 * @dev All execution venues (AMM, OrderEngine) query this interface to gate trading.
 *
 *      Lifecycle: LIVE → RESOLVING → ATTESTED → SETTLED
 *                                            ↘ LIVE (veto/dispute)
 */
interface ITruthMarket {
    // ============================================
    // Types
    // ============================================

    /**
     * @notice How the market reached SETTLED. Each venue fee vault applies its
     *         own committed terminal allocation to this same settlement kind.
     * @dev UNSET is the zero value so a pre-settlement read can never
     *      masquerade as adjudicated.
     */
    enum SettlementKind {
        UNSET,
        ADJUDICATED,
        INVALIDATED
    }

    // ============================================
    // Events
    // ============================================

    event MarketCreated(
        address indexed market,
        bytes32 questionHash,
        string question,
        uint64 startTime,
        uint64 deadline
    );
    event MarketResolved(address indexed market, uint8 outcome);
    event MarketAttested(address indexed market, uint8 outcome);
    event MarketSettled(address indexed market);
    event MarketVetoed(address indexed market, uint8 previousOutcome);
    event MarketInvalidated(address indexed market, address indexed caller);

    // ============================================
    // Resolution Flow (Adjudicator Only)
    // ============================================

    /**
     * @notice Propose a resolution outcome (adjudicator only)
     * @dev Finite markets require now < deadline + invalidationBuffer.
     * @param outcome Winning outcome (0=NO, 1=YES, 2=INVALID)
     */
    function resolve(uint8 outcome) external;

    /**
     * @notice Confirm proposed resolution (adjudicator only)
     * @dev Moves from RESOLVING → ATTESTED. Finite markets require
     *      now < deadline + invalidationBuffer.
     */
    function attest() external;

    /**
     * @notice Lock resolution permanently (adjudicator only)
     * @dev Moves from ATTESTED → SETTLED (irreversible, opens redemption) and
     *      records `settlementKind = ADJUDICATED`. Finite markets require
     *      now < deadline + invalidationBuffer, including adjudicated INVALID.
     */
    function settle() external;

    /**
     * @notice Veto resolution — reverts market back to LIVE
     * @dev Adjudicator-only. Guardians trigger this path via the adjudicator's
     *      dispute() entry point so PHASE_DISPUTED tracking stays in sync.
     *      Finite markets require now < deadline + invalidationBuffer.
     */
    function veto() external;

    /**
     * @notice Permissionless invalidation when the adjudicator fails to settle.
     * @dev Fires at or after `deadline + invalidationBuffer` regardless of current state
     *      (LIVE, RESOLVING, or ATTESTED). Sets outcome to INVALID and transitions
     *      to SETTLED. Reverts on already-SETTLED markets (`AlreadySettled`) and on
     *      infinite-deadline markets (`InfiniteDeadline`). The adjudicator must
     *      drive the full resolve → attest → settle flow strictly before that cutoff;
     *      after it only permissionless timeout INVALID can finalize. Records
     *      `settlementKind = INVALIDATED`, which is how fee accounting detects
     *      adjudicator failure (their accrued fees are redirected).
     */
    function invalidate() external;

    // ============================================
    // Lifecycle State
    // ============================================

    /// @notice Compatibility predicate: LIVE state at or after startTime.
    /// @dev This intentionally does not enforce deadline. Trading venues must
    ///      use isTradingOpen() instead.
    function isLive() external view returns (bool);

    /// @notice Canonical entry predicate for all trades and new collateral.
    /// @dev Exactly: state == LIVE && !resolutionAttempted && startTime <= now
    ///      && now < deadline. The first successful proposal sets the marker.
    ///      veto() leaves it set, so trading stays closed.
    function isTradingOpen() external view returns (bool);

    /// @notice Canonical eligibility predicate for future liquidity work.
    /// @dev Exactly: state == LIVE && !resolutionAttempted && now < deadline.
    ///      There is intentionally no start-time lower bound. veto() leaves the
    ///      marker set, so a proposal closes new liquidity for the rest of the market.
    function isLiquidityOpen() external view returns (bool);

    /// @notice True if adjudicator has proposed an outcome, awaiting attestation
    function isResolving() external view returns (bool);

    /// @notice True only while resolution is attested and not yet settled.
    function isAttested() external view returns (bool);

    /// @notice True if market is fully settled (terminal, irreversible)
    function isSettled() external view returns (bool);

    // ============================================
    // Market Data
    // ============================================

    /// @notice Winning outcome (0=NO, 1=YES, 2=INVALID)
    function winningOutcome() external view returns (uint8);

    /// @notice How the market reached SETTLED (UNSET until settlement).
    function settlementKind() external view returns (SettlementKind);

    /// @notice True after the first successful proposal. `veto()` leaves it set.
    /// @dev settle() and invalidate() leave the value unchanged. Trading and
    ///      new liquidity stay closed while it is set.
    function resolutionAttempted() external view returns (bool);

    /// @notice Redemption value per token (WAD). 1e18 for winner, 0 for loser.
    function getRedemptionValue(uint8 outcome) external view returns (uint256);

    function questionHash() external view returns (bytes32);
    /// @notice Complete creation terms commitment, including the resolver profile.
    function termsHash() external view returns (bytes32);
    function startTime() external view returns (uint64);
    function deadline() external view returns (uint64);
    function invalidationBuffer() external view returns (uint64);
    function creator() external view returns (address);
    function adjudicator() external view returns (address);
    function marketFactory() external view returns (address);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IAdjudicator
 * @notice Standard interface for market adjudicators (settlement authorities).
 * @dev Phase lifecycle: IDLE → ACTIVE → RESOLVED → ATTESTED → SETTLED
 *                                                  ↘ DISPUTED → ACTIVE (re-resolve)
 *      Outcome is always 0 (NO), 1 (YES), or 2 (INVALID).
 */
interface IAdjudicator {
    struct MarketState {
        uint8 phase;
        uint8 outcome;
        uint64 deadline;
        uint64 vetoEndsAt;
        address resolver;
        bytes32 dataHash;
    }

    // ─── Events ────────────────────────────────────────────────────

    event MarketConfigured(
        address indexed market, address indexed resolver, uint64 deadline
    );
    event OutcomeProposed(address indexed market, uint8 outcome, bytes32 dataHash);
    event AttestationVerified(address indexed market, uint256 index);
    event MarketSettled(address indexed market, uint8 outcome);
    event MarketDisputed(address indexed market, uint8 previousOutcome);

    // ─── Errors ────────────────────────────────────────────────────

    error InvalidPhase(uint8 expected, uint8 actual);
    error NotResolver();
    error NotMarketFactory();
    error DeadlinePassed();
    error VetoWindowActive();
    error NotGuardian();
    error VetoWindowClosed();

    // ─── Lifecycle ─────────────────────────────────────────────────

    /// @notice Configure for a market. config = abi.encode(resolver, deadline, typeConfig)
    /// @dev vetoPeriod is fixed at adjudicator deployment, not per-market.
    function configureMarket(address market, bytes calldata config) external;

    /// @notice Propose outcome. Resolver-only. ACTIVE → RESOLVED.
    /// @dev Finite markets require the full veto period to end before deadline + buffer.
    function resolve(address market, uint8 outcome, bytes32 dataHash) external;

    /// @notice Submit attestation proof. RESOLVED → ATTESTED when complete.
    /// @dev Finite markets reject attestations at or after deadline + buffer.
    function attest(address market, bytes calldata proof) external;

    /// @notice Finalize after veto window. RESOLVED|ATTESTED → SETTLED.
    /// @dev Finite markets require now < deadline + buffer; later finalization is timeout INVALID.
    function settle(address market) external;

    /// @notice Guardian disputes outcome during veto window. RESOLVED|ATTESTED → DISPUTED.
    /// @dev Finite markets reject disputes at or after deadline + buffer.
    function dispute(address market) external;

    // ─── Queries ───────────────────────────────────────────────────

    function canSettle(address market) external view returns (bool);
    function getPhase(address market) external view returns (uint8);
    function getOutcome(address market) external view returns (uint8);
    function getMarketState(address market) external view returns (MarketState memory);

    // ─── Identity ──────────────────────────────────────────────────

    function adjudicatorType() external view returns (string memory);
    function marketFactory() external view returns (address);
    function vetoPeriod() external view returns (uint48);
    function profileFrozen() external view returns (bool);
    function profileHash() external view returns (bytes32);
    function resolutionRecipient() external view returns (address);
}

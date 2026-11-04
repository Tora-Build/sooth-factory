// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ITruthMarket} from "./interfaces/ITruthMarket.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title TruthMarket
 * @notice Canonical source of truth for market lifecycle and settlement
 * @dev All execution venues query this contract for market state.
 *
 *      Deployed as CREATE2 minimal proxy clones with immutable args (EIP-1167)
 *      from a shared TruthMarketImpl via MarketFactory.
 *
 *      Immutable args layout (148 bytes, abi.encodePacked):
 *        | offset | size | field               |
 *        |--------|------|---------------------|
 *        | 0      | 32   | questionHash        |
 *        | 32     | 8    | startTime           |
 *        | 40     | 8    | deadline            |
 *        | 48     | 20   | adjudicator         |
 *        | 68     | 20   | marketFactory     |
 *        | 88     | 20   | creator             |
 *        | 108    | 8    | invalidationBuffer  |
 *        | 116    | 32   | termsHash           |
 *
 * Lifecycle: LIVE → RESOLVING → ATTESTED → SETTLED
 *   - LIVE: Trading follows the schedule (startTime through deadline) until the
 *     first successful proposal. A veto returns here and leaves trading closed.
 *   - RESOLVING: Adjudicator proposed outcome, awaiting attestation; trading closed
 *   - ATTESTED: Resolution attested, guardian can still veto → back to LIVE.
 *     The first successful proposal leaves resolutionAttempted set, so trading
 *     and new liquidity stay closed after a veto. Cancellation and, once the
 *     market has settled, LP redemption stay available.
 *   - SETTLED: Terminal state, irreversible, redemption opens
 *
 * Deadline semantics:
 *   - Finite deadline: adjudication completes before deadline + invalidationBuffer
 *   - At or after that cutoff: only permissionless invalidate() can finalize
 *   - Infinite deadline (type(uint64).max): only adjudicator resolves
 */
contract TruthMarket is ITruthMarket {
    // ============================================
    // Enums
    // ============================================

    enum MarketState {
        LIVE, // Trading active
        RESOLVING, // Adjudicator proposed outcome, awaiting attestation
        ATTESTED, // Resolution attested, guardian can veto
        SETTLED // Terminal: redemption open, irreversible
    }

    // ============================================
    // Constants
    // ============================================

    uint256 private constant WAD = 1e18;

    // ============================================
    // Mutable State Variables
    // ============================================

    MarketState public state;
    uint8 public override winningOutcome;
    SettlementKind public override settlementKind;
    bool public override resolutionAttempted;

    // ============================================
    // Errors
    // ============================================

    error NotAdjudicator();
    error BeforeStart();
    error NotLive();
    error NotResolving();
    error NotAttested();
    error InvalidOutcome();
    error DeadlineNotPassed();
    error SettlementDeadlinePassed();
    error InfiniteDeadline();
    error InvalidLength();
    error AlreadySettled();

    // ============================================
    // Resolution Flow
    // ============================================

    /**
     * @notice Propose a resolution outcome (adjudicator only)
     * @dev LIVE → RESOLVING. Re-proposing requires veto first.
     * @param outcome Winning outcome (0=NO, 1=YES, 2=INVALID)
     */
    function resolve(uint8 outcome) external override {
        require(msg.sender == adjudicator(), NotAdjudicator());
        require(block.timestamp >= startTime(), BeforeStart());
        require(state == MarketState.LIVE, NotLive());
        require(outcome <= 2, InvalidOutcome());
        _requireBeforeSettlementDeadline();

        // Set only after every authorization and input check succeeds. veto()
        // leaves it set, so orders and quotes from before the proposal cannot
        // fill afterwards. settle() and invalidate() leave the value as they found it.
        resolutionAttempted = true;
        winningOutcome = outcome;
        state = MarketState.RESOLVING;

        emit MarketResolved(address(this), outcome);
    }

    /**
     * @notice Confirm proposed resolution (adjudicator only)
     * @dev RESOLVING → ATTESTED
     */
    function attest() external override {
        require(msg.sender == adjudicator(), NotAdjudicator());
        require(state == MarketState.RESOLVING, NotResolving());
        _requireBeforeSettlementDeadline();

        state = MarketState.ATTESTED;

        emit MarketAttested(address(this), winningOutcome);
    }

    /**
     * @notice Lock resolution permanently (adjudicator only)
     * @dev ATTESTED → SETTLED (irreversible, opens redemption)
     */
    function settle() external override {
        require(msg.sender == adjudicator(), NotAdjudicator());
        require(state == MarketState.ATTESTED, NotAttested());
        _requireBeforeSettlementDeadline();

        state = MarketState.SETTLED;
        settlementKind = SettlementKind.ADJUDICATED;
        emit MarketSettled(address(this));
    }

    /**
     * @notice Veto resolution — reverts market back to LIVE
     * @dev Only callable by the adjudicator (via dispute(), or when a resolver
     *      replaces a proposal that was never attested).
     *      Guardians must go through AdjudicatorBase.dispute() to ensure
     *      the adjudicator phase is tracked correctly (PHASE_DISPUTED).
     *      Leaves `resolutionAttempted` set. Trading and new liquidity stay
     *      closed. Order cancellation does not read that flag. LP redemption
     *      opens at settlement and does not read it either.
     */
    function veto() external {
        require(msg.sender == adjudicator(), NotAdjudicator());
        require(
            state == MarketState.ATTESTED || state == MarketState.RESOLVING, NotAttested()
        );
        _requireBeforeSettlementDeadline();

        uint8 previousOutcome = winningOutcome;

        state = MarketState.LIVE;
        winningOutcome = 0;

        emit MarketVetoed(address(this), previousOutcome);
    }

    /// @notice Permissionless invalidation when the adjudicator fails to settle.
    /// @dev The adjudicator has `deadline + invalidationBuffer` to drive the full
    ///      resolve → attest → settle flow strictly before the cutoff. At or after
    ///      that cutoff adjudication is closed and anyone can finalize
    ///      the market as INVALID, regardless of its current phase:
    ///
    ///      - LIVE: adjudicator never called resolve()
    ///      - RESOLVING: adjudicator proposed but never attested
    ///      - ATTESTED: adjudicator attested but never settled
    ///      - SETTLED: already finalized, reverts AlreadySettled
    ///
    ///      One timeout, one function, no escalation tier. If the adjudicator
    ///      cannot complete the lifecycle within the buffer, the market falls
    ///      back to INVALID. AdjudicatorBase phase tracking will desync when
    ///      this fires from RESOLVING or ATTESTED — intentional, since the
    ///      adjudicator has missed its deadline.
    ///
    ///      Infinite-deadline markets are excluded: choosing an infinite
    ///      deadline is an explicit opt-out from any timeout safety net.
    ///
    ///      The buffer is frozen per market at creation (see immutable args);
    ///      changes to MarketFactory's global default do not affect existing
    ///      markets.
    function invalidate() external {
        require(state != MarketState.SETTLED, AlreadySettled());
        uint64 dl = deadline();
        require(dl < type(uint64).max, InfiniteDeadline());
        uint64 buffer = invalidationBuffer();
        require(block.timestamp >= uint256(dl) + uint256(buffer), DeadlineNotPassed());

        winningOutcome = 2; // INVALID
        state = MarketState.SETTLED;
        settlementKind = SettlementKind.INVALIDATED;

        emit MarketInvalidated(address(this), msg.sender);
    }

    /// @dev Enforced by TruthMarket itself so a custom adjudicator cannot turn
    ///      an overdue proposal into an adjudicated outcome or extend its window.
    function _requireBeforeSettlementDeadline() private view {
        uint64 dl = deadline();
        require(
            dl == type(uint64).max
                || block.timestamp < uint256(dl) + uint256(invalidationBuffer()),
            SettlementDeadlinePassed()
        );
    }

    // ============================================
    // Lifecycle Queries
    // ============================================

    /// @inheritdoc ITruthMarket
    function isLive() external view override returns (bool) {
        return state == MarketState.LIVE && block.timestamp >= startTime();
    }

    /// @inheritdoc ITruthMarket
    function isTradingOpen() external view override returns (bool) {
        // The first successful proposal closes trading for the rest of the market.
        // veto() leaves the marker set, so a pre-proposal order or quote cannot fill.
        return state == MarketState.LIVE && !resolutionAttempted
            && block.timestamp >= startTime() && block.timestamp < deadline();
    }

    /// @inheritdoc ITruthMarket
    function isLiquidityOpen() external view override returns (bool) {
        return
            state == MarketState.LIVE && !resolutionAttempted
                && block.timestamp < deadline();
    }

    /// @inheritdoc ITruthMarket
    function isResolving() external view override returns (bool) {
        return state == MarketState.RESOLVING;
    }

    /// @inheritdoc ITruthMarket
    /// @dev ATTESTED only. It used to return true for SETTLED as well, which made it
    ///      useless for the one question it exists to answer — "is this attested but
    ///      not yet settled", i.e. is the guardian veto window still the thing
    ///      standing between this market and payout. Callers wanting the union have
    ///      `isSettled()` alongside. No caller in `src/` reads this; it is an
    ///      integrator view (blind audit 2026-09-10).
    function isAttested() external view override returns (bool) {
        return state == MarketState.ATTESTED;
    }

    /// @inheritdoc ITruthMarket
    function isSettled() external view override returns (bool) {
        return state == MarketState.SETTLED;
    }

    // ============================================
    // Redemption Logic
    // ============================================

    /// @inheritdoc ITruthMarket
    function getRedemptionValue(uint8 outcome) external view override returns (uint256) {
        require(state == MarketState.SETTLED, NotAttested());
        require(outcome <= 1, InvalidOutcome());

        if (winningOutcome == 0) {
            return outcome == 0 ? WAD : 0;
        } else if (winningOutcome == 1) {
            return outcome == 1 ? WAD : 0;
        } else {
            return WAD / 2;
        }
    }

    // ============================================
    // Public Getters (decoded from immutable args)
    // ============================================

    /// @inheritdoc ITruthMarket
    function questionHash() external view override returns (bytes32) {
        (bytes32 h,,,,,,) = _getImmutableArgs();
        return h;
    }

    /// @inheritdoc ITruthMarket
    function creator() external view override returns (address) {
        (,,,,, address c,) = _getImmutableArgs();
        return c;
    }

    /// @inheritdoc ITruthMarket
    function startTime() public view override returns (uint64) {
        (, uint64 st,,,,,) = _getImmutableArgs();
        return st;
    }

    /// @inheritdoc ITruthMarket
    function deadline() public view override returns (uint64) {
        (,, uint64 dl,,,,) = _getImmutableArgs();
        return dl;
    }

    /// @inheritdoc ITruthMarket
    function adjudicator() public view override returns (address) {
        (,,, address adj,,,) = _getImmutableArgs();
        return adj;
    }

    /// @inheritdoc ITruthMarket
    function marketFactory() public view override returns (address) {
        (,,,, address lpe,,) = _getImmutableArgs();
        return lpe;
    }

    function invalidationBuffer() public view returns (uint64) {
        (,,,,,, uint64 buf) = _getImmutableArgs();
        return buf;
    }

    /// @inheritdoc ITruthMarket
    function termsHash() external view override returns (bytes32 commitment) {
        bytes memory data = Clones.fetchCloneArgs(address(this));
        require(data.length >= 148, InvalidLength());
        assembly {
            commitment := mload(add(data, 148))
        }
    }

    // ============================================
    // Immutable Args Decoder
    // ============================================

    function _getImmutableArgs()
        internal
        view
        virtual
        returns (
            bytes32 _questionHash,
            uint64 _startTime,
            uint64 _deadline,
            address _adjudicator,
            address _marketFactory,
            address _creator,
            uint64 _invalidationBuffer
        )
    {
        bytes memory data = Clones.fetchCloneArgs(address(this));
        require(data.length >= 148, InvalidLength());
        assembly {
            let ptr := add(data, 32)
            _questionHash := mload(ptr)
            _startTime := shr(192, mload(add(ptr, 32)))
            _deadline := shr(192, mload(add(ptr, 40)))
            _adjudicator := shr(96, mload(add(ptr, 48)))
            _marketFactory := shr(96, mload(add(ptr, 68)))
            _creator := shr(96, mload(add(ptr, 88)))
            _invalidationBuffer := shr(192, mload(add(ptr, 108)))
        }
    }
}

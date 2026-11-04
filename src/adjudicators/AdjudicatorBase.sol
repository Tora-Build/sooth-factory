// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IAdjudicator} from "src/interfaces/IAdjudicator.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AdjudicatorBase
 * @notice Abstract base for all adjudicator implementations.
 * @dev Phase lifecycle: IDLE → ACTIVE → RESOLVED → ATTESTED → SETTLED
 *                                                  ↘ DISPUTED → ACTIVE (re-resolve)
 *      Hooks: _onConfigure, _onResolve, _verifyAttestation, _onAttested,
 *             _isFullyAttested, _requiresAttestation, _beforeSettle, _onDispute
 *      Settlement targets: _resolveMarket, _attestMarket, _settleMarket
 *      Authority runs node admin → adjudicator profile → resolver: the node admin
 *      admits a frozen profile, and the profile names every account that may resolve.
 *      A market creator selects one approved resolver; it cannot add one.
 *      The resolver set, guardian set, early-resolution rule and resolution recipient
 *      are fixed by freezeProfile() before any market can bind this profile. Changed
 *      policies need a new instance.
 *
 *      configureMarket rejects a deadline of zero or type(uint64).max. This
 *      profile cannot bind a market that has no schedule or no timeout.
 */
abstract contract AdjudicatorBase is IAdjudicator, Ownable {
    // ─── Phases ────────────────────────────────────────────────────

    uint8 public constant PHASE_IDLE = 0;
    uint8 public constant PHASE_ACTIVE = 1;
    uint8 public constant PHASE_RESOLVED = 2;
    uint8 public constant PHASE_ATTESTED = 3;
    uint8 public constant PHASE_SETTLED = 4;
    uint8 public constant PHASE_DISPUTED = 5;

    // ─── Outcomes ──────────────────────────────────────────────────

    uint8 public constant OUTCOME_NO = 0;
    uint8 public constant OUTCOME_YES = 1;
    uint8 public constant OUTCOME_INVALID = 2;

    // ─── Immutables ────────────────────────────────────────────────

    address public immutable override marketFactory;
    /// @notice Guardian veto window in seconds. Any `uint48` value. 0 = explicit opt-out.
    /// @dev Set at adjudicator deployment. Applies to all markets bound to this adjudicator.
    ///      The core protocol enforces no bounds — adjudicator deployments are responsible
    ///      for choosing a value short enough to limit redemption delay but long enough for
    ///      guardians to react.
    uint48 public immutable override vetoPeriod;

    // ─── Storage ───────────────────────────────────────────────────

    mapping(address => MarketState) internal _markets;
    mapping(address => bool) private _guardians;
    address[] private _guardianList;
    mapping(address => uint256) private _guardianIndex;
    mapping(address => bool) private _resolvers;
    address[] private _resolverList;
    mapping(address => uint256) private _resolverIndex;
    /// @notice Whether a resolver may propose before the market deadline.
    /// @dev False by default: a proposal closes trading, so it opens at the deadline
    ///      unless the profile owner allows early resolution before the freeze.
    bool public earlyResolution;
    bool public override profileFrozen;
    bytes32 public override profileHash;
    address public override resolutionRecipient;
    /// @notice Counted vetoes one guardian may cast on one market. The veto that
    ///         reaches the cap locks that market. A profile that requires
    ///         attestation accepts a veto only after the proof, so every counted
    ///         veto is of a proposal that could settle.
    uint8 public constant GUARDIAN_VETO_CAP = 3;

    /// @dev The longest time from configuration to the deadline. A longer schedule
    ///      would put the timeout INVALID out of reach.
    uint64 public constant MAX_MARKET_DURATION = 1825 days;
    mapping(address market => mapping(address guardian => uint256 count)) public
        guardianVetoCount;
    /// @notice Set by the counted veto that reaches the cap. `resolve` reverts
    ///         afterwards. Only timeout `invalidate` can finish a finite market.
    mapping(address market => bool) public resolutionLocked;

    // ─── Events ────────────────────────────────────────────────────

    event GuardianApproved(address indexed guardian);
    event GuardianRevoked(address indexed guardian);
    event ResolverApproved(address indexed resolver);
    event ResolverRevoked(address indexed resolver);
    event EarlyResolutionConfigured(bool allowed);
    event ResolutionRecipientConfigured(address indexed recipient);
    event ProfileFrozen(bytes32 indexed profileHash, address indexed resolutionRecipient);
    // ─── Errors ────────────────────────────────────────────────────

    error ZeroAddress();
    error EmptyConfig();
    error MarketAlreadySettled();
    error FrozenProfile();
    error UnfrozenProfile();
    error InvalidMarketBinding();
    error ResolverNotApproved();
    error NoResolver();
    error ResolutionTooEarly();
    error GuardianVetoCapReached();
    error ResolutionVetoLocked();

    // ─── Constructor ───────────────────────────────────────────────

    constructor(address _owner, address _marketFactory, uint48 _vetoPeriod)
        Ownable(_owner)
    {
        require(_marketFactory != address(0), ZeroAddress());
        // vetoPeriod has no protocol-level bounds. 0 = explicit opt-out (no guardian
        // protection). Adjudicator deployments choose the value; trade-off is between
        // guardian reaction time and settlement latency for traders awaiting redemption.
        marketFactory = _marketFactory;
        vetoPeriod = _vetoPeriod;
        resolutionRecipient = _owner;
    }

    // ─── Lifecycle: Configure ──────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function configureMarket(address market, bytes calldata config)
        external
        virtual
        override
    {
        require(msg.sender == marketFactory, NotMarketFactory());
        require(profileFrozen, UnfrozenProfile());
        require(
            ITruthMarket(market).marketFactory() == marketFactory
                && ITruthMarket(market).adjudicator() == address(this),
            InvalidMarketBinding()
        );

        MarketState storage st = _markets[market];
        require(st.phase == PHASE_IDLE, InvalidPhase(PHASE_IDLE, st.phase));

        // Subclasses that support empty config should override configureMarket
        require(config.length > 0, EmptyConfig());

        (address resolver, uint64 deadline, bytes memory typeConfig) =
            abi.decode(config, (address, uint64, bytes));
        require(resolver != address(0), ZeroAddress());
        // The creator selects among the profile's resolvers; it cannot name its own.
        require(_resolvers[resolver], ResolverNotApproved());
        require(deadline == ITruthMarket(market).deadline(), InvalidMarketBinding());
        // Zero has no schedule. A deadline past the limit has no reachable timeout,
        // so a veto lock or a silent resolver would leave the market unsettled.
        // Reject both here, including when the profile allows early resolution.
        // Factory creation applies the same limit.
        require(
            deadline != 0 && deadline <= block.timestamp + MAX_MARKET_DURATION,
            InvalidMarketBinding()
        );

        st.phase = PHASE_ACTIVE;
        st.resolver = resolver;
        st.deadline = deadline;

        _onConfigure(market, typeConfig);

        emit MarketConfigured(market, resolver, deadline);
    }

    // ─── Lifecycle: Resolve ────────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function resolve(address market, uint8 outcome, bytes32 dataHash)
        external
        virtual
        override
    {
        require(!ITruthMarket(market).isSettled(), MarketAlreadySettled());
        require(!resolutionLocked[market], ResolutionVetoLocked());
        MarketState storage st = _markets[market];
        require(msg.sender == st.resolver, NotResolver());
        if (st.phase == PHASE_RESOLVED && _requiresAttestation()) {
            // A proposal that still lacks its attestation cannot settle. The resolver
            // may replace it, so a proposal no proof can match does not hold the
            // market until the timeout. A subclass that collects several attestations
            // must discard them in _onResolve. TruthMarket: RESOLVING → LIVE.
            ITruthMarket(market).veto();
        } else {
            require(
                st.phase == PHASE_ACTIVE || st.phase == PHASE_DISPUTED,
                InvalidPhase(PHASE_ACTIVE, st.phase)
            );
        }
        uint64 marketDeadline = ITruthMarket(market).deadline();
        require(
            earlyResolution || block.timestamp >= marketDeadline, ResolutionTooEarly()
        );
        if (marketDeadline != type(uint64).max) {
            uint64 buffer = ITruthMarket(market).invalidationBuffer();
            // The proposal must be settleable before permissionless
            // invalidation opens: settle() waits out the full veto period, so a
            // proposal landing inside the last vetoPeriod of the buffer could
            // only ever be flipped to INVALID by a third party.
            require(
                block.timestamp + uint256(vetoPeriod)
                    < uint256(marketDeadline) + uint256(buffer),
                DeadlinePassed()
            );
        }

        st.phase = PHASE_RESOLVED;
        st.outcome = outcome;
        st.dataHash = dataHash;
        st.vetoEndsAt = uint64(block.timestamp) + uint64(vetoPeriod);

        _onResolve(market, outcome, dataHash);

        // TruthMarket: LIVE → RESOLVING
        _resolveMarket(market, outcome);

        emit OutcomeProposed(market, outcome, dataHash);
    }

    // ─── Lifecycle: Attest ─────────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function attest(address market, bytes calldata proof) external virtual override {
        require(!ITruthMarket(market).isSettled(), MarketAlreadySettled());
        require(!_settlementDeadlinePassed(market), DeadlinePassed());
        MarketState storage st = _markets[market];
        require(st.phase == PHASE_RESOLVED, InvalidPhase(PHASE_RESOLVED, st.phase));

        _verifyAttestation(market, proof);

        if (_isFullyAttested(market)) {
            if (_requiresAttestation()) {
                // Guardians review the proof, so the veto period runs from the
                // completed attestation, with the same bound resolve() applies.
                ITruthMarket truth = ITruthMarket(market);
                uint64 marketDeadline = truth.deadline();
                require(
                    marketDeadline == type(uint64).max
                        || block.timestamp + uint256(vetoPeriod)
                            < uint256(marketDeadline)
                                + uint256(truth.invalidationBuffer()),
                    DeadlinePassed()
                );
                st.vetoEndsAt = uint64(block.timestamp) + uint64(vetoPeriod);
            }
            st.phase = PHASE_ATTESTED;

            // TruthMarket: RESOLVING → ATTESTED
            _attestMarket(market);
            _onAttested(market, proof);

            emit AttestationVerified(market, 0);
        }
    }

    // ─── Lifecycle: Settle ─────────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function settle(address market) external virtual override {
        require(!ITruthMarket(market).isSettled(), MarketAlreadySettled());
        require(!_settlementDeadlinePassed(market), DeadlinePassed());
        MarketState storage st = _markets[market];

        if (_requiresAttestation()) {
            require(st.phase == PHASE_ATTESTED, InvalidPhase(PHASE_ATTESTED, st.phase));
        } else {
            require(
                st.phase == PHASE_RESOLVED || st.phase == PHASE_ATTESTED,
                InvalidPhase(PHASE_RESOLVED, st.phase)
            );
            if (st.phase == PHASE_RESOLVED) {
                _attestMarket(market);
            }
        }

        require(block.timestamp >= st.vetoEndsAt, VetoWindowActive());

        st.phase = PHASE_SETTLED;
        _beforeSettle(market);

        // TruthMarket: ATTESTED → SETTLED
        _settleMarket(market, st.outcome);

        emit MarketSettled(market, st.outcome);
    }

    // ─── Lifecycle: Dispute (Guardian Veto) ────────────────────────

    /// @inheritdoc IAdjudicator
    function dispute(address market) external virtual override {
        require(_guardians[msg.sender], NotGuardian());
        require(!ITruthMarket(market).isSettled(), MarketAlreadySettled());
        require(!_settlementDeadlinePassed(market), DeadlinePassed());

        MarketState storage st = _markets[market];
        // An unattested proposal on a profile that requires attestation cannot
        // settle, and the resolver can replace it. A veto before the proof would
        // let a guardian run the market to timeout without spending the cap.
        // `attest` restarts the veto window, so review of the proof still has
        // a full period. A profile that can settle from PHASE_RESOLVED still
        // accepts that veto, and every accepted veto counts.
        require(
            _requiresAttestation()
                ? st.phase == PHASE_ATTESTED
                : (st.phase == PHASE_RESOLVED || st.phase == PHASE_ATTESTED),
            InvalidPhase(PHASE_ATTESTED, st.phase)
        );
        require(block.timestamp < st.vetoEndsAt, VetoWindowClosed());
        uint256 cast = guardianVetoCount[market][msg.sender];
        require(cast < GUARDIAN_VETO_CAP, GuardianVetoCapReached());
        unchecked {
            ++cast;
        }
        guardianVetoCount[market][msg.sender] = cast;
        // The veto that reaches the cap closes adjudication for every guardian.
        // A later proposal cannot settle. Timeout INVALID remains for a finite
        // market.
        if (cast == GUARDIAN_VETO_CAP) resolutionLocked[market] = true;

        uint8 previousOutcome = st.outcome;
        st.phase = PHASE_DISPUTED;
        st.outcome = 0;

        // Sync TruthMarket back to LIVE
        ITruthMarket(market).veto();

        _onDispute(market);

        emit MarketDisputed(market, previousOutcome);
    }

    // Fee vaults pay the committed resolutionRecipient directly. This profile
    // has no fee forwarding or owner-selected withdrawal destination.

    // ─── Guardian Management ───────────────────────────────────────

    function approveGuardian(address guardian) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        require(guardian != address(0), ZeroAddress());
        _setGuardian(guardian, true);
    }

    function revokeGuardian(address guardian) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        _setGuardian(guardian, false);
    }

    function batchUpdateGuardians(
        address[] calldata toApprove,
        address[] calldata toRevoke
    ) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        for (uint256 i; i < toApprove.length;) {
            require(toApprove[i] != address(0), ZeroAddress());
            _setGuardian(toApprove[i], true);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < toRevoke.length;) {
            _setGuardian(toRevoke[i], false);
            unchecked {
                ++i;
            }
        }
    }

    // ─── Resolver Management ───────────────────────────────────────

    function approveResolver(address resolver) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        require(resolver != address(0), ZeroAddress());
        _setResolver(resolver, true);
    }

    function revokeResolver(address resolver) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        _setResolver(resolver, false);
    }

    function setEarlyResolution(bool allowed) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        earlyResolution = allowed;
        emit EarlyResolutionConfigured(allowed);
    }

    function setResolutionRecipient(address recipient) external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        require(recipient != address(0) && recipient != address(this), ZeroAddress());
        resolutionRecipient = recipient;
        emit ResolutionRecipientConfigured(recipient);
    }

    /// @notice Commit the effective resolver set, guardian set, early-resolution
    ///         rule, service recipient and profile extension before use.
    /// @dev Guardian and resolver array order is part of this instance's profile
    ///      identity. The complete frozen profile can be reproduced from guardians(),
    ///      resolvers(), getters and the extension. A profile without a resolver
    ///      cannot serve a market. The baseline extension is empty.
    function freezeProfile() external onlyOwner {
        require(!profileFrozen, FrozenProfile());
        require(_resolverList.length != 0, NoResolver());
        profileHash = keccak256(
            abi.encode(
                "SOOTH_FACTORY_RESOLVER_PROFILE_V3",
                block.chainid,
                address(this),
                address(this).codehash,
                marketFactory,
                vetoPeriod,
                resolutionRecipient,
                _guardianList,
                _resolverList,
                earlyResolution,
                _profileExtension()
            )
        );
        profileFrozen = true;
        emit ProfileFrozen(profileHash, resolutionRecipient);
    }

    /// @dev Extra identity committed by the freeze. Empty on the baseline profile.
    function _profileExtension() internal view virtual returns (bytes memory) {
        return "";
    }

    function guardians() external view returns (address[] memory) {
        return _guardianList;
    }

    function resolvers() external view returns (address[] memory) {
        return _resolverList;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        require(!profileFrozen, FrozenProfile());
        super.transferOwnership(newOwner);
    }

    function renounceOwnership() public override onlyOwner {
        require(!profileFrozen, FrozenProfile());
        super.renounceOwnership();
    }

    function _setGuardian(address guardian, bool approved) private {
        if (_guardians[guardian] == approved) return;
        _guardians[guardian] = approved;
        if (approved) {
            _guardianIndex[guardian] = _guardianList.length + 1;
            _guardianList.push(guardian);
            emit GuardianApproved(guardian);
        } else {
            uint256 index = _guardianIndex[guardian] - 1;
            address last = _guardianList[_guardianList.length - 1];
            _guardianList[index] = last;
            _guardianIndex[last] = index + 1;
            _guardianList.pop();
            delete _guardianIndex[guardian];
            emit GuardianRevoked(guardian);
        }
    }

    function _setResolver(address resolver, bool approved) private {
        if (_resolvers[resolver] == approved) return;
        _resolvers[resolver] = approved;
        if (approved) {
            _resolverIndex[resolver] = _resolverList.length + 1;
            _resolverList.push(resolver);
            emit ResolverApproved(resolver);
        } else {
            uint256 index = _resolverIndex[resolver] - 1;
            address last = _resolverList[_resolverList.length - 1];
            _resolverList[index] = last;
            _resolverIndex[last] = index + 1;
            _resolverList.pop();
            delete _resolverIndex[resolver];
            emit ResolverRevoked(resolver);
        }
    }

    // ─── Queries ───────────────────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function canSettle(address market) external view virtual override returns (bool) {
        if (ITruthMarket(market).isSettled() || _settlementDeadlinePassed(market)) {
            return false;
        }

        MarketState memory st = _markets[market];

        if (_requiresAttestation()) {
            if (st.phase != PHASE_ATTESTED) return false;
        } else {
            if (st.phase != PHASE_RESOLVED && st.phase != PHASE_ATTESTED) return false;
        }

        if (block.timestamp < st.vetoEndsAt) return false;
        return true;
    }

    function _settlementDeadlinePassed(address market) private view returns (bool) {
        ITruthMarket truth = ITruthMarket(market);
        uint64 dl = truth.deadline();
        return dl != type(uint64).max
            && block.timestamp >= uint256(dl) + uint256(truth.invalidationBuffer());
    }

    /// @inheritdoc IAdjudicator
    function getPhase(address market) external view virtual override returns (uint8) {
        return _markets[market].phase;
    }

    /// @inheritdoc IAdjudicator
    function getOutcome(address market) external view virtual override returns (uint8) {
        return _markets[market].outcome;
    }

    /// @inheritdoc IAdjudicator
    function getMarketState(address market)
        external
        view
        virtual
        override
        returns (MarketState memory)
    {
        return _markets[market];
    }

    // ─── Identity ──────────────────────────────────────────────────

    /// @inheritdoc IAdjudicator
    function adjudicatorType() external view virtual override returns (string memory) {
        return "base";
    }

    function isGuardian(address account) external view returns (bool) {
        return _guardians[account];
    }

    function isResolver(address account) external view returns (bool) {
        return _resolvers[account];
    }

    // ─── Hooks ─────────────────────────────────────────────────────

    function _onConfigure(address _market, bytes memory _typeConfig) internal virtual {
        _market;
        _typeConfig;
    }

    function _onResolve(address _market, uint8 _outcome, bytes32 _dataHash)
        internal
        virtual
    {
        _market;
        _outcome;
        _dataHash;
    }

    function _verifyAttestation(address _market, bytes calldata _proof) internal virtual {
        _market;
        _proof;
        revert("not implemented");
    }

    function _beforeSettle(address _market) internal virtual {
        _market;
    }

    function _onDispute(address _market) internal virtual {
        _market;
    }

    /// @dev The proof has been accepted and the market is ATTESTED.
    function _onAttested(address, bytes calldata) internal virtual {}

    // ─── Settlement Targets (override for offchain/L2) ─────────────

    function _resolveMarket(address _market, uint8 _outcome) internal virtual {
        ITruthMarket(_market).resolve(_outcome);
    }

    function _attestMarket(address _market) internal virtual {
        ITruthMarket(_market).attest();
    }

    function _settleMarket(address _market, uint8 _outcome) internal virtual {
        _outcome;
        ITruthMarket(_market).settle();
    }

    function _isFullyAttested(address _market) internal view virtual returns (bool) {
        _market;
        return true;
    }

    function _requiresAttestation() internal pure virtual returns (bool) {
        return false;
    }
}

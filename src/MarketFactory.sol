// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IAMMEngine} from "./interfaces/IAMMEngine.sol";
import {IAmmFeeVault} from "./interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "./interfaces/IBookFeeVault.sol";
import {INodeRoles} from "./interfaces/INodeRoles.sol";
import {IAdjudicator} from "./interfaces/IAdjudicator.sol";
import {IOrderEngine} from "./interfaces/IOrderEngine.sol";
import {PositionPricing} from "./libraries/PositionPricing.sol";
import {DecimalMath} from "./libraries/DecimalMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

interface INodeResolutionProfile {
    function marketFactory() external view returns (address);
    function profileFrozen() external view returns (bool);
    function profileHash() external view returns (bytes32);
    function resolutionRecipient() external view returns (address);
    function vetoPeriod() external view returns (uint48);
}

/// @notice Creates fully funded dual-venue markets under separate node authorities.
/// @dev Holds no collateral. Admission changes affect future markets only.
contract MarketFactory is IMarketFactory, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MarketState {
        address creator;
        uint256 lpPositionId;
        address tokenA;
        uint8 tokenADecimals;
        uint256 bBase;
        uint256 creatorDeposit;
    }

    struct InitialLiquidity {
        uint256 qYes;
        uint256 qNo;
        uint256 depositWad;
    }

    address public immutable truthMarketImpl;
    IAMMEngine public immutable ammEngine;
    IAmmFeeVault public immutable ammFeeVault;
    IBookFeeVault public immutable bookFeeVault;
    IOrderEngine public immutable override orderEngine;
    INodeRoles public immutable nodeRoles;

    uint64 public invalidationBuffer;
    bool public creationPaused;
    bool public permissionlessCreation;
    mapping(address => bool) public allowedTokens;
    mapping(address => bool) public allowedCreators;
    mapping(address => bytes32) public admittedProfileHash;
    mapping(address => MarketState) public override markets;
    mapping(address => bytes32) public marketTermsHash;
    mapping(address => uint256) public override creatorNonce;
    address[] public allMarkets;

    error Unauthorized();
    error InvalidAddress();
    error CreationClosed();
    error TokenNotAllowed();
    error UnsupportedDecimals();
    error TokenRiskUnacknowledged();
    error TokenHasTransferHook();
    error TokenPaused();
    error TokenBlacklisted();
    error InvalidSchedule();
    error InvalidBuffer();
    error InvalidProfile();
    error StaleConfig();
    error QuoteExpired();
    error FundingLimit();
    error ZeroLiquidity();
    error TransferAmountMismatch();

    /// @dev A deadline further ahead would put the timeout INVALID out of reach, and
    ///      a market without a reachable timeout can freeze funds permanently.
    uint64 public constant MAX_MARKET_DURATION = 1825 days;

    /// @notice Acknowledgement required to admit a token. On-chain probes do not
    ///         detect every hook, future pause, or future blacklist.
    bytes32 public constant TOKEN_RISK_ACKNOWLEDGEMENT =
        keccak256("SOOTH_TOKEN_ADMISSION_V1:hooks,pause,blacklist-not-fully-detectable");
    /// @dev Canonical ERC-1820 registry. Absent code means no ERC-777 registration
    ///      can be observed; admission does not treat that absence as safety.
    address private constant ERC1820_REGISTRY =
        0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    bytes32 private constant ERC777_INTERFACE_HASH = keccak256("ERC777Token");

    event TokenAdmission(address indexed token, bool allowed);
    event CreatorAdmission(address indexed creator, bool allowed);
    event PermissionlessCreationSet(bool allowed);
    event ProfileAdmission(address indexed adjudicator, bytes32 profileHash);
    event CreationPauseSet(bool paused);

    constructor(
        address truth_,
        address amm_,
        address ammVault_,
        address book_,
        address bookVault_,
        address roles_
    ) {
        require(
            truth_ != address(0) && amm_ != address(0) && ammVault_ != address(0)
                && book_ != address(0) && bookVault_ != address(0)
                && roles_ != address(0),
            InvalidAddress()
        );
        truthMarketImpl = truth_;
        ammEngine = IAMMEngine(amm_);
        ammFeeVault = IAmmFeeVault(ammVault_);
        orderEngine = IOrderEngine(book_);
        bookFeeVault = IBookFeeVault(bookVault_);
        nodeRoles = INodeRoles(roles_);
    }

    modifier onlyNodeAdmin() {
        require(msg.sender == nodeRoles.nodeAdmin(), Unauthorized());
        _;
    }

    /// @notice Revoke future-market token admission.
    /// @dev Admitting a token requires `TOKEN_RISK_ACKNOWLEDGEMENT`. Passing
    ///      `allowed = true` here reverts. Detection of transfer hooks, pausing
    ///      and blacklisting is not reliable, so admission is an explicit
    ///      node-admin allowlist plus the probes in the acknowledging overload.
    function setTokenAllowed(address token, bool allowed) external onlyNodeAdmin {
        require(!allowed, TokenRiskUnacknowledged());
        allowedTokens[token] = false;
        emit TokenAdmission(token, false);
    }

    /// @notice Set future-market AMM token admission, including the book token.
    /// @dev `allowed = true` requires the acknowledgement constant. Probes reject
    ///      a currently registered ERC-777 token, a token that reports
    ///      `paused() == true`, and a token that currently blacklists this
    ///      factory, the AMM, the order book, or either fee vault under the
    ///      common USDC/USDT selectors. A custom hook, a token that pauses or
    ///      blacklists later, and a proxy that adds those behaviors after
    ///      admission are not visible here. Exact balance checks still reject
    ///      fee-on-transfer when value moves.
    function setTokenAllowed(address token, bool allowed, bytes32 acknowledgement)
        external
        onlyNodeAdmin
    {
        if (allowed) {
            require(
                acknowledgement == TOKEN_RISK_ACKNOWLEDGEMENT, TokenRiskUnacknowledged()
            );
            _readDecimals(token);
            _rejectDetectableTokenRisks(token);
        }
        allowedTokens[token] = allowed;
        emit TokenAdmission(token, allowed);
    }

    /// @notice Admit a creator without changing any existing market.
    function setCreatorAllowed(address creator, bool allowed) external onlyNodeAdmin {
        require(creator != address(0), InvalidAddress());
        allowedCreators[creator] = allowed;
        emit CreatorAdmission(creator, allowed);
    }

    /// @notice Choose whether future creation is public within the node's other policies.
    function setPermissionlessCreation(bool allowed) external onlyNodeAdmin {
        permissionlessCreation = allowed;
        emit PermissionlessCreationSet(allowed);
    }

    /// @notice Admit a frozen, node-bound resolution profile for future markets.
    function setAdjudicatorAllowed(address adjudicator, bool allowed)
        external
        onlyNodeAdmin
    {
        bytes32 hash;
        if (allowed) {
            require(adjudicator.code.length != 0, InvalidProfile());
            INodeResolutionProfile profile = INodeResolutionProfile(adjudicator);
            require(
                profile.marketFactory() == address(this) && profile.profileFrozen(),
                InvalidProfile()
            );
            require(profile.resolutionRecipient() != address(0), InvalidProfile());
            hash = profile.profileHash();
            require(hash != bytes32(0), InvalidProfile());
        }
        admittedProfileHash[adjudicator] = hash;
        emit ProfileAdmission(adjudicator, hash);
    }

    /// @notice Stop future creation without pausing any existing AMM or book.
    function setCreationPaused(bool paused) external onlyNodeAdmin {
        creationPaused = paused;
        emit CreationPauseSet(paused);
    }

    /// @notice Explicit future-market timeout setting; zero at deployment disables creation.
    function setInvalidationBuffer(uint64 buffer) external onlyNodeAdmin {
        require(buffer >= 1 hours && buffer <= 30 days, InvalidBuffer());
        invalidationBuffer = buffer;
        emit InvalidationBufferUpdated(buffer);
    }

    /// @inheritdoc IMarketFactory
    function createMarket(MarketParams calldata params)
        external
        override
        nonReentrant
        returns (address market, uint256 lpPositionId)
    {
        require(!creationPaused, CreationClosed());
        require(
            msg.sender == nodeRoles.nodeAdmin() || permissionlessCreation
                || allowedCreators[msg.sender],
            Unauthorized()
        );
        MarketParams memory p = params;
        if (p.startTime == 0) p.startTime = uint64(block.timestamp);
        uint8 decimals = _validateCreation(p);
        bytes32 termsHash = _termsHash(msg.sender, p, decimals);
        uint256 nonce = creatorNonce[msg.sender]++;
        market = Clones.cloneDeterministicWithImmutableArgs(
            truthMarketImpl,
            _cloneArgs(msg.sender, p, termsHash),
            _salt(msg.sender, nonce, termsHash)
        );
        InitialLiquidity memory initial = _collectInitialLiquidity(p, decimals);
        _register(market, p, decimals, initial);
        markets[market] =
            MarketState(msg.sender, 0, p.tokenA, decimals, p.bBase, initial.depositWad);
        marketTermsHash[market] = termsHash;
        lpPositionId = ammEngine.mintLPTokens(market, msg.sender, initial.depositWad);
        markets[market].lpPositionId = lpPositionId;
        allMarkets.push(market);
        IAdjudicator(p.adjudicator).configureMarket(market, p.adjudicatorConfig);
        emit LPTokenCreated(market, lpPositionId);
        _emitMarket(market, p, lpPositionId, nonce, termsHash);
    }

    function _validateCreation(MarketParams memory p)
        private
        view
        returns (uint8 decimals)
    {
        require(p.quoteDeadline >= block.timestamp, QuoteExpired());
        require(p.bBase >= 1e17, ZeroLiquidity());
        require(
            p.maxInputNative != 0 && p.maxInputNative != type(uint256).max, FundingLimit()
        );
        require(p.quoteDeadline <= p.deadline, QuoteExpired());
        require(
            p.startTime >= block.timestamp && p.startTime < p.deadline
                && p.deadline <= block.timestamp + MAX_MARKET_DURATION,
            InvalidSchedule()
        );
        require(
            invalidationBuffer != 0 && p.expectedInvalidationBuffer == invalidationBuffer,
            InvalidBuffer()
        );
        require(allowedTokens[p.tokenA], TokenNotAllowed());
        decimals = _readDecimals(p.tokenA);
        if (p.tokenA == bookFeeVault.baseToken()) {
            require(decimals == bookFeeVault.baseTokenDecimals(), UnsupportedDecimals());
        }
        require(
            p.resolutionTermsHash != bytes32(0) && p.expectedProfileHash != bytes32(0),
            InvalidProfile()
        );
        INodeResolutionProfile profile = INodeResolutionProfile(p.adjudicator);
        require(
            admittedProfileHash[p.adjudicator] == p.expectedProfileHash
                && profile.profileFrozen() && profile.marketFactory() == address(this)
                && profile.profileHash() == p.expectedProfileHash
                && profile.vetoPeriod() < invalidationBuffer,
            InvalidProfile()
        );
        require(
            p.expectedAmmVersion == ammFeeVault.activeConfigVersion()
                && p.expectedBookVersion == bookFeeVault.activeConfigVersion()
                && p.expectedAmmHash == ammFeeVault.configHash(p.expectedAmmVersion)
                && p.expectedBookHash == bookFeeVault.configHash(p.expectedBookVersion),
            StaleConfig()
        );
    }

    function _register(
        address market,
        MarketParams memory p,
        uint8 decimals,
        InitialLiquidity memory initial
    ) private {
        address recipient = INodeResolutionProfile(p.adjudicator).resolutionRecipient();
        ammFeeVault.registerMarket(
            market, p.tokenA, decimals, p.expectedAmmVersion, recipient
        );
        bookFeeVault.registerMarket(
            market,
            bookFeeVault.baseToken(),
            bookFeeVault.baseTokenDecimals(),
            p.expectedBookVersion,
            recipient
        );
        ammEngine.initializeMarket(
            market,
            p.tokenA,
            decimals,
            p.bBase,
            initial.qYes,
            initial.qNo,
            initial.depositWad
        );
        (,, uint256 yesPrice) = ammEngine.getMarketState(market);
        orderEngine.registerMarket(market, bookFeeVault.baseToken(), yesPrice);
    }

    function _collectInitialLiquidity(MarketParams memory p, uint8 decimals)
        private
        returns (InitialLiquidity memory initial)
    {
        (initial.qYes, initial.qNo) =
            PositionPricing.initialQuantities(p.bBase, p.initialProbabilityWad);
        (, initial.depositWad) =
            PositionPricing.costBounds(p.bBase, initial.qYes, initial.qNo);
        uint256 amount = DecimalMath.fromWadCeil(initial.depositWad, decimals);
        require(amount != 0 && amount <= p.maxInputNative, FundingLimit());
        IERC20 token = IERC20(p.tokenA);
        uint256 engineBefore = token.balanceOf(address(ammEngine));
        uint256 payerBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(ammEngine), amount);
        uint256 engineAfter = token.balanceOf(address(ammEngine));
        uint256 payerAfter = token.balanceOf(msg.sender);
        require(
            engineAfter >= engineBefore && engineAfter - engineBefore == amount
                && payerBefore >= payerAfter && payerBefore - payerAfter == amount,
            TransferAmountMismatch()
        );
        initial.depositWad = DecimalMath.toWad(amount, decimals);
    }

    function _readDecimals(address token) private view returns (uint8 decimals) {
        require(token.code.length != 0, InvalidAddress());
        decimals = IERC20Metadata(token).decimals();
        require(decimals <= 18, UnsupportedDecimals());
    }

    /// @dev Sound when it reverts, incomplete when it does not. A missing
    ///      ERC-1820 registry, a failed probe, or a token that will become
    ///      hostile later is not treated as proof of safety.
    function _rejectDetectableTokenRisks(address token) private view {
        if (ERC1820_REGISTRY.code.length != 0) {
            (bool ok, bytes memory ret) = ERC1820_REGISTRY.staticcall(
                abi.encodeWithSignature(
                    "getInterfaceImplementer(address,bytes32)",
                    token,
                    ERC777_INTERFACE_HASH
                )
            );
            if (ok && ret.length >= 32 && abi.decode(ret, (address)) != address(0)) {
                revert TokenHasTransferHook();
            }
        }
        if (_staticBool(token, abi.encodeWithSignature("paused()"))) {
            revert TokenPaused();
        }
        address[5] memory custodians = [
            address(this),
            address(ammEngine),
            address(orderEngine),
            address(ammFeeVault),
            address(bookFeeVault)
        ];
        bytes4[3] memory blacklistSelectors = [
            bytes4(keccak256("isBlacklisted(address)")),
            bytes4(keccak256("isBlackListed(address)")),
            bytes4(keccak256("getBlackListStatus(address)"))
        ];
        for (uint256 c; c < custodians.length; ++c) {
            for (uint256 s; s < blacklistSelectors.length; ++s) {
                if (_staticBool(
                        token,
                        abi.encodeWithSelector(blacklistSelectors[s], custodians[c])
                    )) revert TokenBlacklisted();
            }
        }
    }

    function _staticBool(address token, bytes memory data) private view returns (bool) {
        (bool ok, bytes memory ret) = token.staticcall(data);
        return ok && ret.length >= 32 && uint256(bytes32(ret)) == 1;
    }

    function _termsHash(address creator, MarketParams memory p, uint8 decimals)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                creator,
                p,
                decimals,
                bookFeeVault.baseToken(),
                invalidationBuffer
            )
        );
    }

    function _cloneArgs(address creator, MarketParams memory p, bytes32 termsHash)
        private
        view
        returns (bytes memory)
    {
        return abi.encodePacked(
            keccak256(bytes(p.question)),
            p.startTime,
            p.deadline,
            p.adjudicator,
            address(this),
            creator,
            invalidationBuffer,
            termsHash
        );
    }

    function _salt(address creator, uint256 nonce, bytes32 termsHash)
        private
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(creator, nonce, termsHash));
    }

    function _emitMarket(
        address market,
        MarketParams memory p,
        uint256 lpId,
        uint256 nonce,
        bytes32 termsHash
    ) private {
        emit MarketCreated(
            market,
            msg.sender,
            p.question,
            p.startTime,
            p.deadline,
            p.tokenA,
            markets[market].tokenADecimals,
            p.bBase,
            p.adjudicator,
            lpId,
            nonce
        );
        emit MarketCommitted(
            market,
            termsHash,
            p.expectedProfileHash,
            p.expectedAmmVersion,
            p.expectedBookVersion,
            p.expectedAmmHash,
            p.expectedBookHash
        );
    }

    /// @inheritdoc IMarketFactory
    function predictMarketAddress(
        address creator,
        MarketParams calldata params,
        uint256 nonce
    ) external view override returns (address) {
        MarketParams memory p = params;
        if (p.startTime == 0) p.startTime = uint64(block.timestamp);
        bytes32 termsHash = _termsHash(creator, p, _readDecimals(p.tokenA));
        return Clones.predictDeterministicAddressWithImmutableArgs(
            truthMarketImpl,
            _cloneArgs(creator, p, termsHash),
            _salt(creator, nonce, termsHash),
            address(this)
        );
    }

    /// @notice Expose the exact canonical commitment used by creation and prediction.
    function hashMarketTerms(address creator, MarketParams calldata params)
        external
        view
        returns (bytes32)
    {
        MarketParams memory p = params;
        if (p.startTime == 0) p.startTime = uint64(block.timestamp);
        return _termsHash(creator, p, _readDecimals(p.tokenA));
    }

    function isPaused() external pure override returns (bool) {
        return false;
    }

    function getMarkets() external view override returns (address[] memory) {
        return allMarkets;
    }

    function getMarketCount() external view override returns (uint256) {
        return allMarkets.length;
    }

    function getLPToken(address market) external view override returns (uint256) {
        return markets[market].lpPositionId;
    }
}

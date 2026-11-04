// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITruthMarket} from "../interfaces/ITruthMarket.sol";
import {INodeRoles} from "../interfaces/INodeRoles.sol";

/// @notice Shared mechanics, never shared custody or administration.
abstract contract VenueFeeVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MarketInfo {
        uint32 configVersion;
        address token;
        uint8 decimals;
        address resolutionRecipient;
        bool finalized;
        bool timedOut;
    }

    uint256 internal constant BPS = 10_000;
    address public immutable engine;
    address public immutable marketFactory;
    INodeRoles public immutable roles;
    address public immutable surplusRecipient;
    uint16 public immutable maxFeeBps;
    uint8 public immutable venue;
    uint32 public activeConfigVersion;
    mapping(uint32 => bytes32) internal _configHashes;
    mapping(address => MarketInfo) internal _markets;
    mapping(address => mapping(uint8 => uint256)) internal _accounts;
    mapping(address => uint256) internal _marketLiabilities;
    mapping(address => uint256) internal _totalLiabilities;

    error NotAuthorized();
    error InvalidConfig();
    error InvalidToken();
    error NotRegistered();
    error AlreadyRegistered();
    error StaleConfig();
    error InvalidPhase();
    error NotFinalizable();
    error NothingToClaim();
    error ResolutionForfeited();
    error DepositAmountMismatch();
    error TransferAmountMismatch();
    error Insolvent();

    event ConfigPublished(uint32 indexed version, bytes32 indexed configHash);
    event MarketRegistered(
        address indexed market,
        uint8 indexed venue,
        address indexed token,
        uint32 configVersion,
        address resolutionRecipient
    );
    event RevenueDeposited(
        address indexed market,
        uint8 indexed venue,
        address indexed token,
        address feePayer,
        uint256 amount
    );
    event FeeDistributed(
        address indexed market,
        uint8 indexed venue,
        address indexed token,
        uint8 bucket,
        uint256 amount
    );
    event Claimed(
        address indexed market,
        uint8 indexed venue,
        address indexed token,
        uint8 bucket,
        address recipient,
        uint256 amount
    );
    event MarketFinalized(
        address indexed market, uint8 indexed venue, uint8 settlementKind
    );
    event SurplusSwept(
        uint8 indexed venue,
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    constructor(
        address engine_,
        address marketFactory_,
        address roles_,
        address surplusRecipient_,
        uint16 maxFeeBps_,
        uint8 venue_
    ) {
        require(
            engine_ != address(0) && marketFactory_ != address(0) && roles_ != address(0)
                && engine_ != address(this),
            InvalidConfig()
        );
        require(
            surplusRecipient_ != address(0) && surplusRecipient_ != address(this)
                && surplusRecipient_ != engine_,
            InvalidConfig()
        );
        require(maxFeeBps_ <= BPS, InvalidConfig());
        engine = engine_;
        marketFactory = marketFactory_;
        roles = INodeRoles(roles_);
        surplusRecipient = surplusRecipient_;
        maxFeeBps = maxFeeBps_;
        venue = venue_;
    }

    modifier onlyEngine() {
        require(msg.sender == engine, NotAuthorized());
        _;
    }

    function configHash(uint32 version) public view returns (bytes32) {
        require(version != 0 && version <= activeConfigVersion, InvalidConfig());
        return _configHashes[version];
    }

    function marketConfigVersion(address market) public view returns (uint32) {
        return _registered(market).configVersion;
    }

    function totalLiabilitiesOf(address token) public view returns (uint256) {
        return _totalLiabilities[token];
    }

    function marketLiabilitiesOf(address market, address token)
        public
        view
        returns (uint256)
    {
        return _markets[market].token == token ? _marketLiabilities[market] : 0;
    }

    function finalize(address market) external nonReentrant {
        _finalize(market);
    }

    function sweepUnattributedSurplus(address token)
        external
        nonReentrant
        returns (uint256 amount)
    {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance >= _totalLiabilities[token], Insolvent());
        amount = balance - _totalLiabilities[token];
        if (amount != 0) {
            _pushExact(token, surplusRecipient, amount);
            _requireSolvent(token);
            emit SurplusSwept(venue, token, surplusRecipient, amount);
        }
    }

    function _registered(address market) internal view returns (MarketInfo storage info) {
        info = _markets[market];
        require(info.configVersion != 0, NotRegistered());
    }

    function _register(
        address market,
        address token,
        uint8 decimals,
        uint32 expectedVersion,
        address resolutionRecipient
    ) internal {
        require(msg.sender == marketFactory, NotAuthorized());
        require(_markets[market].configVersion == 0, AlreadyRegistered());
        require(
            expectedVersion != 0 && expectedVersion == activeConfigVersion, StaleConfig()
        );
        require(market.code.length != 0 && token.code.length != 0, InvalidToken());
        require(
            decimals <= 18 && IERC20Metadata(token).decimals() == decimals, InvalidToken()
        );
        _checkRecipient(resolutionRecipient);
        ITruthMarket truth = ITruthMarket(market);
        require(truth.marketFactory() == marketFactory, NotAuthorized());
        require(truth.deadline() < type(uint64).max && !truth.isSettled(), InvalidPhase());
        _markets[market] = MarketInfo(
            expectedVersion, token, decimals, resolutionRecipient, false, false
        );
        emit MarketRegistered(market, venue, token, expectedVersion, resolutionRecipient);
    }

    function _checkRecipient(address recipient) internal view {
        require(
            recipient != address(0) && recipient != address(this) && recipient != engine,
            InvalidConfig()
        );
    }

    function _receive(address market, uint256 amount, address payer) internal {
        MarketInfo storage info = _registered(market);
        require(!info.finalized && !ITruthMarket(market).isSettled(), InvalidPhase());
        IERC20 token = IERC20(info.token);
        _requireSolvent(info.token);
        uint256 vaultBefore = token.balanceOf(address(this));
        uint256 sourceBefore = token.balanceOf(engine);
        token.safeTransferFrom(engine, address(this), amount);
        uint256 vaultAfter = token.balanceOf(address(this));
        uint256 sourceAfter = token.balanceOf(engine);
        require(
            vaultAfter >= vaultBefore && vaultAfter - vaultBefore == amount
                && sourceBefore >= sourceAfter && sourceBefore - sourceAfter == amount,
            DepositAmountMismatch()
        );
        _marketLiabilities[market] += amount;
        _totalLiabilities[info.token] += amount;
        emit RevenueDeposited(market, venue, info.token, payer, amount);
    }

    function _credit(address market, uint8 bucket, uint256 amount) internal {
        if (amount == 0) return;
        _accounts[market][bucket] += amount;
        emit FeeDistributed(market, venue, _markets[market].token, bucket, amount);
    }

    function _pay(address market, uint8 bucket, address recipient, uint256 amount)
        internal
    {
        if (amount == 0) return;
        address token = _registered(market).token;
        _requireSolvent(token);
        _accounts[market][bucket] -= amount;
        _marketLiabilities[market] -= amount;
        _totalLiabilities[token] -= amount;
        _pushExact(token, recipient, amount);
        _requireSolvent(token);
        emit Claimed(market, venue, token, bucket, recipient, amount);
    }

    function _pushExact(address tokenAddress, address recipient, uint256 amount) private {
        IERC20 token = IERC20(tokenAddress);
        uint256 beforeVault = token.balanceOf(address(this));
        uint256 beforeRecipient = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 afterVault = token.balanceOf(address(this));
        uint256 afterRecipient = token.balanceOf(recipient);
        require(
            beforeVault >= afterVault && beforeVault - afterVault == amount
                && afterRecipient >= beforeRecipient
                && afterRecipient - beforeRecipient == amount,
            TransferAmountMismatch()
        );
    }

    function _requireSolvent(address token) internal view {
        require(
            IERC20(token).balanceOf(address(this)) >= _totalLiabilities[token],
            Insolvent()
        );
    }

    function _finalize(address market) internal {
        MarketInfo storage info = _registered(market);
        if (info.finalized) return;
        ITruthMarket truth = ITruthMarket(market);
        if (!truth.isSettled()) {
            require(
                block.timestamp
                    >= uint256(truth.deadline()) + uint256(truth.invalidationBuffer()),
                NotFinalizable()
            );
            truth.invalidate();
        }
        ITruthMarket.SettlementKind kind = truth.settlementKind();
        require(
            truth.isSettled() && kind != ITruthMarket.SettlementKind.UNSET, InvalidPhase()
        );
        info.finalized = true;
        info.timedOut = kind == ITruthMarket.SettlementKind.INVALIDATED;
        _afterFinalization(market, info.timedOut);
        emit MarketFinalized(market, venue, uint8(kind));
    }

    function _afterFinalization(address market, bool timedOut) internal virtual;
}

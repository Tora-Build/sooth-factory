// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBookFeeVault} from "./interfaces/IBookFeeVault.sol";
import {VenueFeeVault} from "./fees/VenueFeeVault.sol";

/// @notice Node-local stablecoin book revenue with source-payer timeout refunds.
/// @dev Implements IBookFeeVault's ABI. Refund records are alternative beneficiaries
/// of the resolution bucket, never a second funded liability.
contract BookFeeVault is VenueFeeVault {
    address public immutable baseToken;
    uint8 public immutable baseTokenDecimals;
    mapping(uint32 => IBookFeeVault.BookConfig) private _configs;
    mapping(address => mapping(address => uint256)) private _refunds;

    constructor(IBookFeeVault.Init memory init)
        VenueFeeVault(
            init.engine,
            init.marketFactory,
            init.roles,
            init.surplusRecipient,
            init.maxFeeBps,
            1
        )
    {
        require(init.baseToken.code.length != 0, InvalidToken());
        uint8 decimals = IERC20Metadata(init.baseToken).decimals();
        require(decimals <= 18, InvalidToken());
        baseToken = init.baseToken;
        baseTokenDecimals = decimals;
        _publish(init.initialConfig);
    }

    function publishBookConfig(IBookFeeVault.BookConfig calldata config)
        external
        nonReentrant
        returns (uint32)
    {
        require(msg.sender == roles.protocolAuthority(), NotAuthorized());
        return _publish(config);
    }

    function configByVersion(uint32 version)
        public
        view
        returns (IBookFeeVault.BookConfig memory)
    {
        configHash(version);
        return _configs[version];
    }

    function configOf(address market)
        public
        view
        returns (IBookFeeVault.BookConfig memory)
    {
        return _configs[_registered(market).configVersion];
    }

    function feeBpsOf(address market) external view returns (uint16) {
        return _configs[_registered(market).configVersion].feeBps;
    }

    function registerMarket(
        address market,
        address token,
        uint8 decimals,
        uint32 expectedVersion,
        address resolutionRecipient
    ) external nonReentrant {
        require(token == baseToken && decimals == baseTokenDecimals, InvalidToken());
        _register(market, token, decimals, expectedVersion, resolutionRecipient);
    }

    function depositRevenue(address market, uint256 amount, address feePayer)
        external
        onlyEngine
        nonReentrant
        returns (uint256)
    {
        MarketInfo storage info = _registered(market);
        require(feePayer != address(0) && feePayer != address(this), InvalidConfig());
        if (amount == 0) return 0;
        _receive(market, amount, feePayer);
        uint256 resolution =
            Math.mulDiv(amount, _configs[info.configVersion].resolutionBps, BPS);
        _credit(market, uint8(IBookFeeVault.Bucket.RESOLUTION), resolution);
        _credit(market, uint8(IBookFeeVault.Bucket.PROTOCOL), amount - resolution);
        _refunds[market][feePayer] += resolution;
        return amount;
    }

    function claimProtocolFees(address market)
        external
        nonReentrant
        returns (uint256 amount)
    {
        MarketInfo storage info = _registered(market);
        amount = _accounts[market][uint8(IBookFeeVault.Bucket.PROTOCOL)];
        _pay(
            market,
            uint8(IBookFeeVault.Bucket.PROTOCOL),
            _configs[info.configVersion].protocolRecipient,
            amount
        );
    }

    function claimResolutionFees(address market)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _finalize(market);
        MarketInfo storage info = _markets[market];
        require(!info.timedOut, ResolutionForfeited());
        amount = _accounts[market][uint8(IBookFeeVault.Bucket.RESOLUTION)];
        _pay(
            market,
            uint8(IBookFeeVault.Bucket.RESOLUTION),
            info.resolutionRecipient,
            amount
        );
    }

    function claimTimeoutRefund(address market, address payer)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _finalize(market);
        require(_markets[market].timedOut, InvalidPhase());
        amount = _refunds[market][payer];
        _refunds[market][payer] = 0;
        _pay(market, uint8(IBookFeeVault.Bucket.RESOLUTION), payer, amount);
    }

    /// @notice Conditional until timeout; normal completion permanently disables it.
    function refundableResolutionOf(address market, address payer)
        external
        view
        returns (uint256)
    {
        MarketInfo storage info = _registered(market);
        if (info.finalized && !info.timedOut) return 0;
        return _refunds[market][payer];
    }

    function accountOf(address market, IBookFeeVault.Bucket bucket, address token)
        external
        view
        returns (uint256)
    {
        return _markets[market].token == token ? _accounts[market][uint8(bucket)] : 0;
    }

    function _afterFinalization(address, bool) internal override {}

    function _publish(IBookFeeVault.BookConfig memory cfg)
        private
        returns (uint32 version)
    {
        require(
            cfg.feeBps <= maxFeeBps
                && uint256(cfg.resolutionBps) + cfg.protocolBps == BPS,
            InvalidConfig()
        );
        _checkRecipient(cfg.protocolRecipient);
        version = ++activeConfigVersion;
        _configs[version] = cfg;
        _configHashes[version] = keccak256(abi.encode(cfg));
        emit ConfigPublished(version, _configHashes[version]);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAmmFeeVault} from "./interfaces/IAmmFeeVault.sol";
import {LPPositionManager} from "./LPPositionManager.sol";
import {VenueFeeVault} from "./fees/VenueFeeVault.sol";

/// @notice Node-local AMM revenue. Principal and CAPITAL remain in the engine.
/// @dev Implements IAmmFeeVault's ABI; shared mechanics live in VenueFeeVault.
contract AmmFeeVault is VenueFeeVault {
    mapping(uint32 => IAmmFeeVault.AmmConfig) private _configs;
    mapping(address => address) public positionController;

    event LPBurnRecorded(
        address indexed market,
        address indexed holder,
        uint256 units,
        uint256 supplyBeforeBurn
    );

    constructor(IAmmFeeVault.Init memory init)
        VenueFeeVault(
            init.engine, init.marketFactory, init.roles, init.surplusRecipient, 10_000, 0
        )
    {
        _publish(init.initialConfig);
    }

    function publishAmmConfig(IAmmFeeVault.AmmConfig calldata config)
        external
        nonReentrant
        returns (uint32)
    {
        require(msg.sender == roles.nodeAdmin(), NotAuthorized());
        return _publish(config);
    }

    function configByVersion(uint32 version)
        public
        view
        returns (IAmmFeeVault.AmmConfig memory)
    {
        configHash(version);
        return _configs[version];
    }

    function configOf(address market)
        public
        view
        returns (IAmmFeeVault.AmmConfig memory)
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
        _register(market, token, decimals, expectedVersion, resolutionRecipient);
    }

    function tokenAOf(address market) external view returns (address) {
        return _registered(market).token;
    }

    function tokenADecimalsOf(address market) external view returns (uint8) {
        return _registered(market).decimals;
    }

    function enablePositionFees(address market, address controller)
        external
        onlyEngine
        nonReentrant
    {
        MarketInfo storage info = _registered(market);
        require(
            controller != address(0) && positionController[market] == address(0)
                && _marketLiabilities[market] == 0 && !info.finalized,
            InvalidConfig()
        );
        LPPositionManager manager = LPPositionManager(controller);
        require(
            manager.engine() == engine && manager.vault() == address(this),
            InvalidConfig()
        );
        positionController[market] = controller;
    }

    function depositRevenue(address market, uint256 amount, address feePayer)
        external
        onlyEngine
        nonReentrant
        returns (uint256)
    {
        MarketInfo storage info = _registered(market);
        require(positionController[market] != address(0), InvalidConfig());
        if (amount == 0) return 0;
        IAmmFeeVault.AmmConfig storage cfg = _configs[info.configVersion];
        uint256 denom = BPS - cfg.capitalBps;
        require(denom != 0, InvalidConfig()); // full CAPITAL produces no vault revenue
        _receive(market, amount, feePayer);
        uint256 lp = Math.mulDiv(amount, cfg.lpBps, denom);
        uint256 resolution = Math.mulDiv(amount, cfg.resolutionBps, denom);
        _credit(market, uint8(IAmmFeeVault.Bucket.LP), lp);
        _credit(market, uint8(IAmmFeeVault.Bucket.RESOLUTION), resolution);
        _credit(market, uint8(IAmmFeeVault.Bucket.OPERATOR), amount - lp - resolution);
        LPPositionManager(positionController[market]).accrueFees(market, lp, resolution);
        return amount;
    }

    function notifyLPBurn(
        address market,
        address holder,
        uint256 units,
        uint256 supplyBeforeBurn
    ) external onlyEngine nonReentrant {
        require(supplyBeforeBurn > 0 && units <= supplyBeforeBurn, InvalidConfig());
        _finalize(market);
        // Earning-time controller accounts already own fees. Never reslice on burn.
        emit LPBurnRecorded(market, holder, units, supplyBeforeBurn);
    }

    function claimLPDividend(address market) external nonReentrant returns (uint256) {
        _finalize(market);
        return _claimLP(market, msg.sender);
    }

    function claimLPDividendForPosition(address market, uint256 positionId)
        external
        nonReentrant
        returns (uint256)
    {
        _finalize(market);
        LPPositionManager manager = _controller(market, positionId);
        manager.checkpointFees(positionId, msg.sender);
        return _claimLP(market, msg.sender);
    }

    function claimLPDividendFor(address market, uint256 positionId, address holder)
        external
        onlyEngine
        nonReentrant
        returns (uint256)
    {
        _finalize(market);
        // Only the engine may reach the controller checkpoint bypass while its own
        // accounting guard is held, after principal/floor effects are complete.
        _controller(market, positionId).checkpointFeesForClaim(positionId, holder);
        return _claimLP(market, holder);
    }

    function claimOperatorFees(address market)
        external
        nonReentrant
        returns (uint256 amount)
    {
        MarketInfo storage info = _registered(market);
        amount = _accounts[market][uint8(IAmmFeeVault.Bucket.OPERATOR)];
        _pay(
            market,
            uint8(IAmmFeeVault.Bucket.OPERATOR),
            _configs[info.configVersion].operatorRecipient,
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
        amount = _accounts[market][uint8(IAmmFeeVault.Bucket.RESOLUTION)];
        _pay(
            market,
            uint8(IAmmFeeVault.Bucket.RESOLUTION),
            info.resolutionRecipient,
            amount
        );
    }

    function accountOf(address market, IAmmFeeVault.Bucket bucket, address token)
        external
        view
        returns (uint256)
    {
        return _markets[market].token == token ? _accounts[market][uint8(bucket)] : 0;
    }

    function lpEntitlementOf(address market, address holder, address token)
        external
        view
        returns (uint256)
    {
        if (_markets[market].token != token || positionController[market] == address(0)) return 0;
        return LPPositionManager(positionController[market]).claimableFees(market, holder);
    }

    function _controller(address market, uint256 positionId)
        private
        view
        returns (LPPositionManager manager)
    {
        address controller = positionController[market];
        require(controller != address(0), InvalidConfig());
        manager = LPPositionManager(controller);
        require(manager.positionMarket(positionId) == market, InvalidConfig());
    }

    function _claimLP(address market, address holder) private returns (uint256 amount) {
        address controller = positionController[market];
        require(controller != address(0), InvalidConfig());
        amount = LPPositionManager(controller).takeFees(market, holder);
        _pay(market, uint8(IAmmFeeVault.Bucket.LP), holder, amount);
    }

    function _afterFinalization(address market, bool timedOut) internal override {
        address controller = positionController[market];
        require(controller != address(0), InvalidConfig());
        if (timedOut) {
            uint256 amount = _accounts[market][uint8(IAmmFeeVault.Bucket.RESOLUTION)];
            _accounts[market][uint8(IAmmFeeVault.Bucket.RESOLUTION)] = 0;
            _accounts[market][uint8(IAmmFeeVault.Bucket.LP)] += amount;
        }
        LPPositionManager(controller).finalizeFees(market, timedOut);
    }

    function _publish(IAmmFeeVault.AmmConfig memory cfg)
        private
        returns (uint32 version)
    {
        require(
            cfg.feeBps <= maxFeeBps
                && uint256(cfg.capitalBps) + cfg.lpBps + cfg.resolutionBps
                        + cfg.operatorBps == BPS,
            InvalidConfig()
        );
        _checkRecipient(cfg.operatorRecipient);
        version = ++activeConfigVersion;
        _configs[version] = cfg;
        _configHashes[version] = keccak256(abi.encode(cfg));
        emit ConfigPublished(version, _configHashes[version]);
    }
}

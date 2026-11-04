// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IAmmFeeVault {
    enum Bucket {
        LP,
        RESOLUTION,
        OPERATOR
    }

    /// @notice OPERATOR receives integer split remainder even when operatorBps is zero.
    /// @dev Weights are nominal; native effective allocations depend on receipt size.
    struct AmmConfig {
        uint16 feeBps;
        uint16 capitalBps;
        uint16 lpBps;
        uint16 resolutionBps;
        uint16 operatorBps;
        address operatorRecipient;
    }

    struct Init {
        address engine;
        address marketFactory;
        address roles;
        address surplusRecipient;
        AmmConfig initialConfig;
    }
    function engine() external view returns (address);
    function marketFactory() external view returns (address);
    function roles() external view returns (address);
    function surplusRecipient() external view returns (address);
    /// @notice Fixed arithmetic bound of 10_000 bps; not an operator-chosen ceiling.
    function maxFeeBps() external view returns (uint16);
    function activeConfigVersion() external view returns (uint32);
    function publishAmmConfig(AmmConfig calldata config) external returns (uint32);
    function configHash(uint32 version) external view returns (bytes32);
    function configOf(address market) external view returns (AmmConfig memory);
    function configByVersion(uint32 version) external view returns (AmmConfig memory);
    function marketConfigVersion(address market) external view returns (uint32);
    function registerMarket(
        address market,
        address token,
        uint8 decimals,
        uint32 expectedVersion,
        address resolutionRecipient
    ) external;
    function tokenAOf(address market) external view returns (address);
    function tokenADecimalsOf(address market) external view returns (uint8);
    function feeBpsOf(address market) external view returns (uint16);
    function depositRevenue(address market, uint256 amount, address feePayer)
        external
        returns (uint256);
    function enablePositionFees(address market, address controller) external;
    function positionController(address market) external view returns (address);
    function notifyLPBurn(
        address market,
        address holder,
        uint256 units,
        uint256 supplyBeforeBurn
    ) external;
    function finalize(address market) external;
    function claimLPDividend(address market) external returns (uint256);
    function claimLPDividendForPosition(address market, uint256 positionId)
        external
        returns (uint256);
    function claimLPDividendFor(address market, uint256 positionId, address holder)
        external
        returns (uint256);
    function claimOperatorFees(address market) external returns (uint256);
    function claimResolutionFees(address market) external returns (uint256);
    function accountOf(address market, Bucket bucket, address token)
        external
        view
        returns (uint256);
    function lpEntitlementOf(address market, address holder, address token)
        external
        view
        returns (uint256);
    function totalLiabilitiesOf(address token) external view returns (uint256);
    function marketLiabilitiesOf(address market, address token)
        external
        view
        returns (uint256);
    function sweepUnattributedSurplus(address token) external returns (uint256);
}

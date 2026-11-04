// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IBookFeeVault {
    enum Bucket {
        RESOLUTION,
        PROTOCOL
    }

    struct BookConfig {
        uint16 feeBps;
        uint16 resolutionBps;
        uint16 protocolBps;
        address protocolRecipient;
    }

    struct Init {
        address engine;
        address marketFactory;
        address roles;
        address baseToken;
        address surplusRecipient;
        uint16 maxFeeBps;
        BookConfig initialConfig;
    }
    function engine() external view returns (address);
    function marketFactory() external view returns (address);
    function roles() external view returns (address);
    function surplusRecipient() external view returns (address);
    function maxFeeBps() external view returns (uint16);
    function baseToken() external view returns (address);
    function baseTokenDecimals() external view returns (uint8);
    function activeConfigVersion() external view returns (uint32);
    function publishBookConfig(BookConfig calldata config) external returns (uint32);
    function configHash(uint32 version) external view returns (bytes32);
    function configOf(address market) external view returns (BookConfig memory);
    function configByVersion(uint32 version) external view returns (BookConfig memory);
    function marketConfigVersion(address market) external view returns (uint32);
    function registerMarket(
        address market,
        address token,
        uint8 decimals,
        uint32 expectedVersion,
        address resolutionRecipient
    ) external;
    function feeBpsOf(address market) external view returns (uint16);
    function depositRevenue(address market, uint256 amount, address feePayer)
        external
        returns (uint256);
    function finalize(address market) external;
    function claimProtocolFees(address market) external returns (uint256);
    function claimResolutionFees(address market) external returns (uint256);
    function claimTimeoutRefund(address market, address payer) external returns (uint256);
    function refundableResolutionOf(address market, address payer)
        external
        view
        returns (uint256);
    function accountOf(address market, Bucket bucket, address token)
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

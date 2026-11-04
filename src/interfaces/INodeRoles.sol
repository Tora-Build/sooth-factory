// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Independent authority references for one node. Neither role owns custody.
interface INodeRoles {
    function nodeAdmin() external view returns (address);
    function protocolAuthority() external view returns (address);
    function activationGate() external view returns (address);
}

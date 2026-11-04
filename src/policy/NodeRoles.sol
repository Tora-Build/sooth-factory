// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {INodeRoles} from "../interfaces/INodeRoles.sol";

interface INodeActivationGate {
    function activated() external view returns (bool);
}

/// @notice Two independent, two-step authorities. The deployer retains no privilege.
contract NodeRoles is INodeRoles {
    address public immutable override activationGate;
    address public override nodeAdmin;
    address public pendingNodeAdmin;
    address public override protocolAuthority;
    address public pendingProtocolAuthority;

    error Unauthorized();
    error ZeroAddress();
    error NodeNotActive();

    event NodeAdminProposed(address indexed current, address indexed proposed);
    event ProtocolAuthorityProposed(address indexed current, address indexed proposed);
    event NodeAdminTransferred(address indexed previous, address indexed current);
    event ProtocolAuthorityTransferred(address indexed previous, address indexed current);

    constructor(address admin_, address authority_, address activationGate_) {
        require(admin_ != address(0) && authority_ != address(0), ZeroAddress());
        activationGate = activationGate_;
        nodeAdmin = admin_;
        protocolAuthority = authority_;
        emit NodeAdminTransferred(address(0), admin_);
        emit ProtocolAuthorityTransferred(address(0), authority_);
    }

    modifier whenNodeActive() {
        require(
            activationGate == address(0)
                || INodeActivationGate(activationGate).activated(),
            NodeNotActive()
        );
        _;
    }

    /// @notice Nominate a successor for this node's AMM administration.
    function proposeNodeAdmin(address next) external {
        require(msg.sender == nodeAdmin, Unauthorized());
        require(next != address(0), ZeroAddress());
        pendingNodeAdmin = next;
        emit NodeAdminProposed(nodeAdmin, next);
    }

    /// @notice Cancel this role's outstanding nomination.
    function cancelNodeAdminTransfer() external {
        require(msg.sender == nodeAdmin, Unauthorized());
        pendingNodeAdmin = address(0);
        emit NodeAdminProposed(nodeAdmin, address(0));
    }

    /// @notice Accept the nomination; existing market beneficiaries do not change.
    function acceptNodeAdmin() external {
        require(msg.sender == pendingNodeAdmin, Unauthorized());
        address previous = nodeAdmin;
        nodeAdmin = msg.sender;
        pendingNodeAdmin = address(0);
        emit NodeAdminTransferred(previous, msg.sender);
    }

    /// @notice Nominate a successor for this node's CLOB policy authority.
    function proposeProtocolAuthority(address next) external whenNodeActive {
        require(msg.sender == protocolAuthority, Unauthorized());
        require(next != address(0), ZeroAddress());
        pendingProtocolAuthority = next;
        emit ProtocolAuthorityProposed(protocolAuthority, next);
    }

    /// @notice Cancel this role's outstanding nomination.
    function cancelProtocolAuthorityTransfer() external whenNodeActive {
        require(msg.sender == protocolAuthority, Unauthorized());
        pendingProtocolAuthority = address(0);
        emit ProtocolAuthorityProposed(protocolAuthority, address(0));
    }

    /// @notice Accept the CLOB nomination independently of node administration.
    function acceptProtocolAuthority() external whenNodeActive {
        require(msg.sender == pendingProtocolAuthority, Unauthorized());
        address previous = protocolAuthority;
        protocolAuthority = msg.sender;
        pendingProtocolAuthority = address(0);
        emit ProtocolAuthorityTransferred(previous, msg.sender);
    }
}

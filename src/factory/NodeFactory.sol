// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NodeTypes} from "./NodeTypes.sol";
import {NodeDeployer} from "./NodeDeployer.sol";
import {ReleaseRegistry} from "./ReleaseRegistry.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Operator-authorized nodes under standing book terms; owns no node authority.
contract NodeFactory is ReentrancyGuard {
    ReleaseRegistry public immutable registry;
    mapping(address => mapping(bytes32 => bool)) public approvedRequests;
    mapping(bytes32 => address) public nodeDeployer;
    mapping(bytes32 => address) public pendingDeployer;
    mapping(bytes32 => bytes32) public pendingRequestHash;
    bytes32[] private _nodeIds;

    error Unauthorized();
    error InvalidRequest();
    error InvalidRelease();
    error NodeAlreadyExists();

    event RequestApproval(
        address indexed authority, bytes32 indexed requestHash, bool approved
    );
    event NodePrepared(
        bytes32 indexed nodeId, bytes32 indexed requestHash, address indexed deployer
    );
    event NodeCreated(
        bytes32 indexed nodeId,
        bytes32 indexed releaseId,
        address indexed nodeAdmin,
        address protocolAuthority,
        address bookToken,
        address deployer,
        address roles,
        address book,
        address amm,
        address ammVault,
        address bookVault,
        address marketFactory
    );

    constructor(address registry_) {
        require(registry_.code.length != 0, InvalidRequest());
        registry = ReleaseRegistry(registry_);
    }

    /// @notice Approve an exact complete request; works for EOAs and contract-wallet calls.
    function approveRequest(bytes32 hash) external {
        require(hash != bytes32(0), InvalidRequest());
        approvedRequests[msg.sender][hash] = true;
        emit RequestApproval(msg.sender, hash, true);
    }

    /// @notice Revoke an outstanding complete-request approval.
    function revokeRequest(bytes32 hash) external {
        approvedRequests[msg.sender][hash] = false;
        emit RequestApproval(msg.sender, hash, false);
    }

    function requestHash(NodeTypes.Request calldata request)
        external
        view
        returns (bytes32)
    {
        return NodeTypes.requestHash(address(this), request);
    }

    function nodeId(NodeTypes.Request calldata request) external view returns (bytes32) {
        return NodeTypes.nodeId(address(this), request);
    }

    /// @notice Prepare inert engines using node-admin consent and standing book policy.
    /// @dev There is deliberately no relayed-creation or signature-recovery API.
    function beginNode(NodeTypes.Request calldata request)
        external
        nonReentrant
        returns (bytes32 id, address deployer)
    {
        (bytes32 hash,) = _validate(request, true);
        id = NodeTypes.nodeId(address(this), request);
        require(
            nodeDeployer[id] == address(0) && pendingDeployer[id] == address(0),
            NodeAlreadyExists()
        );
        pendingDeployer[id] = address(1);
        pendingRequestHash[id] = hash;
        deployer = address(
            new NodeDeployer{salt: id}(
                address(this), address(registry), request.releaseId, hash
            )
        );
        NodeDeployer(deployer).prepare(request);
        pendingDeployer[id] = deployer;
        emit NodePrepared(id, hash, deployer);
    }

    /// @notice Revalidate consent and policy, finish children, then atomically activate discovery.
    function completeNode(NodeTypes.Request calldata request)
        external
        nonReentrant
        returns (bytes32 id, NodeTypes.Addresses memory a)
    {
        (bytes32 hash, NodeTypes.BookPolicy memory policy) = _validate(request, false);
        id = NodeTypes.nodeId(address(this), request);
        address deployer = pendingDeployer[id];
        require(
            deployer != address(0) && pendingRequestHash[id] == hash
                && nodeDeployer[id] == address(0),
            InvalidRequest()
        );
        a = NodeDeployer(deployer).complete(request);
        delete approvedRequests[request.nodeAdmin][hash];
        delete pendingDeployer[id];
        delete pendingRequestHash[id];
        nodeDeployer[id] = deployer;
        _nodeIds.push(id);
        _emitNode(id, request, policy.protocolAuthority, deployer, a);
    }

    function _validate(NodeTypes.Request calldata request, bool requireActivePolicy)
        private
        view
        returns (bytes32 hash, NodeTypes.BookPolicy memory policy)
    {
        require(msg.sender == request.requester, Unauthorized());
        require(
            request.nodeAdmin != address(0) && request.expiry >= block.timestamp,
            InvalidRequest()
        );
        // AmmFeeVault's constructor rejects these in the second stage. Reject them
        // here, so a request that can never complete cannot reserve its node identity.
        require(
            request.ammSurplusRecipient != address(0)
                && request.ammConfig.operatorRecipient != address(0)
                && request.ammConfig.feeBps <= 10_000
                && uint256(request.ammConfig.capitalBps) + request.ammConfig.lpBps
                        + request.ammConfig.resolutionBps + request.ammConfig.operatorBps
                    == 10_000,
            InvalidRequest()
        );
        policy = requireActivePolicy
            ? registry.validateActiveBookPolicy(
                request.bookToken,
                request.expectedBookPolicyVersion,
                request.expectedBookPolicyHash
            )
            : registry.validateBookPolicy(
                request.bookToken,
                request.expectedBookPolicyVersion,
                request.expectedBookPolicyHash
            );
        ReleaseRegistry.Release memory release = registry.release(request.releaseId);
        require(
            release.exists && !release.revoked
                && release.deployerCreationHash
                    == keccak256(type(NodeDeployer).creationCode),
            InvalidRelease()
        );
        hash = NodeTypes.requestHash(address(this), request);
        require(
            msg.sender == request.nodeAdmin || approvedRequests[request.nodeAdmin][hash],
            Unauthorized()
        );
    }

    function _emitNode(
        bytes32 id,
        NodeTypes.Request memory r,
        address protocolAuthority,
        address deployer,
        NodeTypes.Addresses memory a
    ) private {
        emit NodeCreated(
            id,
            r.releaseId,
            r.nodeAdmin,
            protocolAuthority,
            r.bookToken,
            deployer,
            a.roles,
            a.book,
            a.amm,
            a.ammVault,
            a.bookVault,
            a.marketFactory
        );
    }

    /// @notice Predict the same fixed recipe independently of node creation state.
    function predictNode(NodeTypes.Request calldata request)
        external
        view
        returns (address deployer, NodeTypes.Addresses memory a)
    {
        bytes32 id = NodeTypes.nodeId(address(this), request);
        bytes memory code = abi.encodePacked(
            type(NodeDeployer).creationCode,
            abi.encode(
                address(this),
                address(registry),
                request.releaseId,
                NodeTypes.requestHash(address(this), request)
            )
        );
        deployer = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), id, keccak256(code))
                    )
                )
            )
        );
        a = NodeTypes.predictChildren(deployer);
    }

    function nodeCount() external view returns (uint256) {
        return _nodeIds.length;
    }

    function nodeIdAt(uint256 index) external view returns (bytes32) {
        return _nodeIds[index];
    }
}

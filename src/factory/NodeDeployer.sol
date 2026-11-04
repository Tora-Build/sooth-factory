// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NodeTypes} from "./NodeTypes.sol";
import {NodeVerifier} from "./NodeVerifier.sol";
import {ReleaseRegistry} from "./ReleaseRegistry.sol";
import {IAmmFeeVault} from "../interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../interfaces/IBookFeeVault.sol";

/// @notice Fixed-sequence staged deployer; creation code is immutable registry data.
/// @dev No generic executor, initializer or retained administrative role is exposed.
contract NodeDeployer {
    address public immutable factory;
    ReleaseRegistry public immutable registry;
    bytes32 public immutable releaseId;
    bytes32 public immutable committedRequestHash;
    bool public prepared;
    bool public deployed;
    /// @notice Opens protocol-role transfers only after complete initialization succeeds.
    bool public activated;
    bytes32[8] public componentRuntimeHashes;

    event RuntimeCodeCommitted(
        uint8 indexed component, address indexed instance, bytes32 runtimeHash
    );

    error Unauthorized();
    error AlreadyDeployed();
    error InvalidRelease();
    error InvalidRequest();
    error ChildDeploymentFailed(uint8 child);
    error InitCodeTooLarge();
    error InvalidRuntimeCode(uint8 component);

    constructor(
        address factory_,
        address registry_,
        bytes32 releaseId_,
        bytes32 requestHash_
    ) {
        factory = factory_;
        registry = ReleaseRegistry(registry_);
        releaseId = releaseId_;
        committedRequestHash = requestHash_;
    }

    /// @notice Prepare roles and engines. No marketFactory or registered market exists yet.
    function prepare(NodeTypes.Request calldata request)
        external
        returns (NodeTypes.Addresses memory a)
    {
        require(msg.sender == factory, Unauthorized());
        require(!prepared && !deployed, AlreadyDeployed());
        (ReleaseRegistry.Release memory r, NodeTypes.BookPolicy memory policy) =
            _validate(request, true);
        prepared = true;
        a = NodeTypes.predictChildren(address(this));
        _deployChildren(request, policy, a, r.truthImplementation, 0, 3);
        address[8] memory instances = _instances(a, r.truthImplementation);
        for (uint8 i; i < 8; ++i) {
            if (i < 3 || i >= 6) _commitRuntime(i, instances[i]);
        }
    }

    /// @notice Deploy vaults and marketFactory; a failure leaves only the inert preparation.
    function complete(NodeTypes.Request calldata request)
        external
        returns (NodeTypes.Addresses memory a)
    {
        require(msg.sender == factory, Unauthorized());
        require(prepared && !deployed, AlreadyDeployed());
        (ReleaseRegistry.Release memory r, NodeTypes.BookPolicy memory policy) =
            _validate(request, false);
        a = NodeTypes.predictChildren(address(this));
        address[8] memory instances = _instances(a, r.truthImplementation);
        for (uint8 i; i < 8; ++i) {
            if (i < 3 || i >= 6) {
                require(
                    instances[i].codehash == componentRuntimeHashes[i],
                    InvalidRuntimeCode(i)
                );
            }
        }
        deployed = true;
        _deployChildren(request, policy, a, r.truthImplementation, 3, 6);
        NodeVerifier.verifyInitial(a, request, policy, r.truthImplementation);
        for (uint8 i = 3; i < 6; ++i) {
            _commitRuntime(i, instances[i]);
        }
        activated = true;
    }

    function _validate(NodeTypes.Request calldata request, bool requireActivePolicy)
        private
        view
        returns (ReleaseRegistry.Release memory r, NodeTypes.BookPolicy memory policy)
    {
        require(
            request.releaseId == releaseId
                && NodeTypes.requestHash(factory, request) == committedRequestHash,
            InvalidRequest()
        );
        r = registry.release(releaseId);
        require(
            r.exists && !r.revoked && r.truthImplementation.codehash == r.truthCodeHash,
            InvalidRelease()
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
    }

    function _deployChildren(
        NodeTypes.Request calldata request,
        NodeTypes.BookPolicy memory policy,
        NodeTypes.Addresses memory a,
        address truth,
        uint8 start,
        uint8 end
    ) private {
        for (uint8 i = start; i < end; ++i) {
            bytes memory initCode = bytes.concat(
                registry.creationCode(releaseId, i), _args(i, request, policy, a, truth)
            );
            require(initCode.length <= 49_152, InitCodeTooLarge());
            address child;
            assembly ("memory-safe") {
                child := create(0, add(initCode, 32), mload(initCode))
            }
            require(
                child == NodeTypes.createAddress(address(this), i + 1)
                    && child.code.length != 0,
                ChildDeploymentFailed(i)
            );
        }
    }

    function _commitRuntime(uint8 index, address instance) private {
        componentRuntimeHashes[index] = instance.codehash;
        emit RuntimeCodeCommitted(index, instance, componentRuntimeHashes[index]);
    }

    function _args(
        uint8 index,
        NodeTypes.Request memory r,
        NodeTypes.BookPolicy memory policy,
        NodeTypes.Addresses memory a,
        address truth
    ) private view returns (bytes memory) {
        if (index == 0) {
            return abi.encode(r.nodeAdmin, policy.protocolAuthority, address(this));
        }
        if (index == 1) return abi.encode(r.bookToken, a.marketFactory, a.bookVault);
        if (index == 2) return abi.encode(a.marketFactory, a.ammVault);
        if (index == 3) {
            IAmmFeeVault.Init memory init = IAmmFeeVault.Init({
                engine: a.amm,
                marketFactory: a.marketFactory,
                roles: a.roles,
                surplusRecipient: r.ammSurplusRecipient,
                initialConfig: r.ammConfig
            });
            return abi.encode(init);
        }
        if (index == 4) {
            IBookFeeVault.Init memory init = IBookFeeVault.Init({
                engine: a.book,
                marketFactory: a.marketFactory,
                roles: a.roles,
                baseToken: r.bookToken,
                surplusRecipient: policy.bookSurplusRecipient,
                maxFeeBps: policy.maxBookFeeBps,
                initialConfig: policy.bookConfig
            });
            return abi.encode(init);
        }
        return abi.encode(truth, a.amm, a.ammVault, a.book, a.bookVault, a.roles);
    }

    /// @notice Verify immutable wiring after legitimate role/configuration changes.
    function verifyWiring() external view returns (bool) {
        require(deployed, InvalidRequest());
        NodeTypes.Addresses memory a = NodeTypes.predictChildren(address(this));
        address truth = registry.release(releaseId).truthImplementation;
        address[8] memory instances = _instances(a, truth);
        for (uint8 i; i < 8; ++i) {
            require(
                instances[i].codehash == componentRuntimeHashes[i], InvalidRuntimeCode(i)
            );
        }
        NodeVerifier.verifyWiring(a, truth);
        return true;
    }

    function _instances(NodeTypes.Addresses memory a, address truth)
        private
        pure
        returns (address[8] memory)
    {
        return [
            a.roles,
            a.book,
            a.amm,
            a.ammVault,
            a.bookVault,
            a.marketFactory,
            a.positionManager,
            truth
        ];
    }
}

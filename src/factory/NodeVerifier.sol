// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NodeTypes} from "./NodeTypes.sol";
import {INodeRoles} from "../interfaces/INodeRoles.sol";
import {IAmmFeeVault} from "../interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../interfaces/IBookFeeVault.sol";

interface IEngineLinks {
    function marketFactory() external view returns (address);
    function feeVault() external view returns (address);
}

interface IAmmLinks is IEngineLinks {
    function positionManager() external view returns (address);
}

interface IBookLinks is IEngineLinks {
    function baseToken() external view returns (address);
    function baseTokenDecimals() external view returns (uint8);
}

interface IMarketFactoryLinks {
    function truthMarketImpl() external view returns (address);
    function ammEngine() external view returns (address);
    function orderEngine() external view returns (address);
    function ammFeeVault() external view returns (address);
    function bookFeeVault() external view returns (address);
    function nodeRoles() external view returns (address);
    function getMarketCount() external view returns (uint256);
}

interface IPositionLinks {
    function engine() external view returns (address);
    function vault() external view returns (address);
    function nextPositionId() external view returns (uint256);
}

/// @notice Separates immutable wiring verification from creation-only state checks.
library NodeVerifier {
    error InvalidWiring();
    error InvalidInitialState();

    function verifyWiring(NodeTypes.Addresses memory a, address truth) internal view {
        require(
            a.roles.code.length != 0 && a.book.code.length != 0 && a.amm.code.length != 0
                && a.ammVault.code.length != 0 && a.bookVault.code.length != 0
                && a.marketFactory.code.length != 0 && a.positionManager.code.length != 0,
            InvalidWiring()
        );
        require(
            INodeRoles(a.roles).nodeAdmin() != address(0)
                && INodeRoles(a.roles).protocolAuthority() != address(0)
                && INodeRoles(a.roles).activationGate() == address(this),
            InvalidWiring()
        );
        require(
            IBookLinks(a.book).marketFactory() == a.marketFactory
                && IBookLinks(a.book).feeVault() == a.bookVault,
            InvalidWiring()
        );
        require(
            IAmmLinks(a.amm).marketFactory() == a.marketFactory
                && IAmmLinks(a.amm).feeVault() == a.ammVault
                && IAmmLinks(a.amm).positionManager() == a.positionManager,
            InvalidWiring()
        );
        require(
            IPositionLinks(a.positionManager).engine() == a.amm
                && IPositionLinks(a.positionManager).vault() == a.ammVault,
            InvalidWiring()
        );
        require(
            IAmmFeeVault(a.ammVault).engine() == a.amm
                && IAmmFeeVault(a.ammVault).marketFactory() == a.marketFactory
                && IAmmFeeVault(a.ammVault).roles() == a.roles,
            InvalidWiring()
        );
        require(
            IBookFeeVault(a.bookVault).engine() == a.book
                && IBookFeeVault(a.bookVault).marketFactory() == a.marketFactory
                && IBookFeeVault(a.bookVault).roles() == a.roles
                && IBookFeeVault(a.bookVault).baseToken()
                    == IBookLinks(a.book).baseToken()
                && IBookFeeVault(a.bookVault).baseTokenDecimals()
                    == IBookLinks(a.book).baseTokenDecimals(),
            InvalidWiring()
        );
        IMarketFactoryLinks l = IMarketFactoryLinks(a.marketFactory);
        require(
            l.truthMarketImpl() == truth && l.ammEngine() == a.amm
                && l.orderEngine() == a.book && l.ammFeeVault() == a.ammVault
                && l.bookFeeVault() == a.bookVault && l.nodeRoles() == a.roles,
            InvalidWiring()
        );
    }

    function verifyInitial(
        NodeTypes.Addresses memory a,
        NodeTypes.Request memory r,
        NodeTypes.BookPolicy memory policy,
        address truth
    ) internal view {
        verifyWiring(a, truth);
        require(
            INodeRoles(a.roles).nodeAdmin() == r.nodeAdmin
                && INodeRoles(a.roles).protocolAuthority() == policy.protocolAuthority
                && IBookLinks(a.book).baseToken() == r.bookToken,
            InvalidInitialState()
        );
        IAmmFeeVault av = IAmmFeeVault(a.ammVault);
        IBookFeeVault bv = IBookFeeVault(a.bookVault);
        require(
            av.activeConfigVersion() == 1 && bv.activeConfigVersion() == 1
                && av.configHash(1) == keccak256(abi.encode(r.ammConfig))
                && bv.configHash(1) == keccak256(abi.encode(policy.bookConfig)),
            InvalidInitialState()
        );
        require(
            av.surplusRecipient() == r.ammSurplusRecipient
                && bv.surplusRecipient() == policy.bookSurplusRecipient
                && av.maxFeeBps() == 10_000 && bv.maxFeeBps() == policy.maxBookFeeBps,
            InvalidInitialState()
        );
        require(
            IMarketFactoryLinks(a.marketFactory).getMarketCount() == 0
                && IPositionLinks(a.positionManager).nextPositionId() == 1
                && av.totalLiabilitiesOf(r.bookToken) == 0
                && bv.totalLiabilitiesOf(r.bookToken) == 0,
            InvalidInitialState()
        );
    }
}

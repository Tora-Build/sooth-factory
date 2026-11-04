// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IAmmFeeVault} from "../interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "../interfaces/IBookFeeVault.sol";

/// @notice Release-pinned constructor request and the resulting custody manifest.
library NodeTypes {
    struct Request {
        bytes32 releaseId;
        bytes32 userSalt;
        address requester;
        address nodeAdmin;
        address bookToken;
        address ammSurplusRecipient;
        uint64 expiry;
        uint32 expectedBookPolicyVersion;
        bytes32 expectedBookPolicyHash;
        IAmmFeeVault.AmmConfig ammConfig;
    }

    /// @notice Standing protocol-owned terms; never supplied as operator choices.
    struct BookPolicy {
        address protocolAuthority;
        address bookSurplusRecipient;
        uint16 maxBookFeeBps;
        IBookFeeVault.BookConfig bookConfig;
    }

    struct Addresses {
        address roles;
        address book;
        address amm;
        address ammVault;
        address bookVault;
        address marketFactory;
        address positionManager;
    }

    function requestHash(address factory, Request memory request)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("SOOTH_FACTORY_NODE_REQUEST_V3"),
                block.chainid,
                factory,
                request
            )
        );
    }

    function nodeId(address factory, Request memory request)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                block.chainid,
                factory,
                request.requester,
                request.userSalt,
                request.releaseId
            )
        );
    }

    function createAddress(address deployer, uint8 nonce)
        internal
        pure
        returns (address)
    {
        assert(nonce > 0 && nonce < 128);
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", deployer, nonce))))
        );
    }

    function predictChildren(address deployer)
        internal
        pure
        returns (Addresses memory a)
    {
        a.roles = createAddress(deployer, 1);
        a.book = createAddress(deployer, 2);
        a.amm = createAddress(deployer, 3);
        a.ammVault = createAddress(deployer, 4);
        a.bookVault = createAddress(deployer, 5);
        a.marketFactory = createAddress(deployer, 6);
        a.positionManager = createAddress(a.amm, 1);
    }
}

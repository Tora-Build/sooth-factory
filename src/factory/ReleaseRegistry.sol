// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {NodeTypes} from "./NodeTypes.sol";

/// @notice Immutable release recipes and prospective node-admission policy.
/// @dev Existing nodes do not consult this registry for trading, roles or claims.
contract ReleaseRegistry {
    struct CodeInput {
        address[] chunks;
        bytes32 creationHash;
        uint32 length;
    }

    struct CodeRecord {
        address[] chunks;
        bytes32[] chunkHashes;
        bytes32 creationHash;
        uint32 length;
    }

    struct Release {
        bool exists;
        bool revoked;
        bytes20 sourceRevision;
        bytes32 manifestHash;
        address truthImplementation;
        bytes32 truthCodeHash;
        bytes32 deployerCreationHash;
    }

    address public protocolOwner;
    address public pendingProtocolOwner;
    mapping(address => bool) public supportedStablecoins;
    mapping(address => uint32) public activeBookPolicyVersion;
    mapping(address => mapping(uint32 => NodeTypes.BookPolicy)) private _bookPolicies;
    mapping(address => mapping(uint32 => bytes32)) private _bookPolicyHashes;
    mapping(bytes32 => Release) private _releases;
    mapping(bytes32 => mapping(uint8 => CodeRecord)) private _code;

    error Unauthorized();
    error InvalidRelease();
    error InvalidCode();
    error ZeroAddress();
    error InvalidBookPolicy();
    error StaleBookPolicy();

    event ReleasePublished(
        bytes32 indexed releaseId, bytes20 sourceRevision, bytes32 manifestHash
    );
    event ReleaseRevoked(bytes32 indexed releaseId);
    event StablecoinAdmission(address indexed token, bool allowed);
    event BookPolicyPublished(
        address indexed token, uint32 indexed version, bytes32 indexed policyHash
    );
    event ProtocolOwnerProposed(address indexed current, address indexed proposed);
    event ProtocolOwnerTransferred(address indexed previous, address indexed current);

    constructor(address owner_) {
        require(owner_ != address(0), ZeroAddress());
        protocolOwner = owner_;
        emit ProtocolOwnerTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        require(msg.sender == protocolOwner, Unauthorized());
        _;
    }

    /// @notice Authorize collateral for future factory requests only.
    function setStablecoin(address token, bool allowed) external onlyOwner {
        require(
            token != address(0) && (!allowed || token.code.length != 0), ZeroAddress()
        );
        supportedStablecoins[token] = allowed;
        emit StablecoinAdmission(token, allowed);
    }

    /// @notice Publish immutable standing CLOB terms for future nodes of this stablecoin.
    function publishBookPolicy(address token, NodeTypes.BookPolicy calldata policy)
        external
        onlyOwner
        returns (uint32 version)
    {
        require(
            supportedStablecoins[token] && policy.protocolAuthority != address(0)
                && policy.bookSurplusRecipient != address(0)
                && policy.bookConfig.protocolRecipient != address(0)
                && policy.maxBookFeeBps <= 10_000
                && policy.bookConfig.feeBps <= policy.maxBookFeeBps
                && uint256(policy.bookConfig.resolutionBps)
                        + policy.bookConfig.protocolBps == 10_000,
            InvalidBookPolicy()
        );
        version = ++activeBookPolicyVersion[token];
        _bookPolicies[token][version] = policy;
        bytes32 hash = keccak256(abi.encode(policy));
        _bookPolicyHashes[token][version] = hash;
        emit BookPolicyPublished(token, version, hash);
    }

    function bookPolicy(address token, uint32 version)
        external
        view
        returns (NodeTypes.BookPolicy memory)
    {
        require(
            version != 0 && version <= activeBookPolicyVersion[token], InvalidBookPolicy()
        );
        return _bookPolicies[token][version];
    }

    function bookPolicyHash(address token, uint32 version)
        external
        view
        returns (bytes32)
    {
        require(
            version != 0 && version <= activeBookPolicyVersion[token], InvalidBookPolicy()
        );
        return _bookPolicyHashes[token][version];
    }

    /// @notice New preparations must select the currently published policy.
    function validateActiveBookPolicy(address token, uint32 version, bytes32 expectedHash)
        external
        view
        returns (NodeTypes.BookPolicy memory)
    {
        require(version == activeBookPolicyVersion[token], StaleBookPolicy());
        return validateBookPolicy(token, version, expectedHash);
    }

    /// @notice Pending nodes may complete under their exact historical policy.
    /// @dev Collateral admission remains current even when the selected version is older.
    function validateBookPolicy(address token, uint32 version, bytes32 expectedHash)
        public
        view
        returns (NodeTypes.BookPolicy memory)
    {
        require(
            supportedStablecoins[token] && version != 0
                && version <= activeBookPolicyVersion[token]
                && expectedHash == _bookPolicyHashes[token][version],
            StaleBookPolicy()
        );
        return _bookPolicies[token][version];
    }

    /// @notice Publish a complete, immutable six-child creation recipe.
    function publishRelease(
        bytes32 releaseId,
        bytes20 sourceRevision,
        bytes32 manifestHash,
        address truthImplementation,
        bytes32 deployerCreationHash,
        CodeInput[6] calldata code
    ) external onlyOwner {
        require(
            releaseId != bytes32(0) && !_releases[releaseId].exists
                && sourceRevision != bytes20(0) && manifestHash != bytes32(0)
                && truthImplementation.code.length != 0
                && deployerCreationHash != bytes32(0),
            InvalidRelease()
        );
        _releases[releaseId] = Release(
            true,
            false,
            sourceRevision,
            manifestHash,
            truthImplementation,
            truthImplementation.codehash,
            deployerCreationHash
        );
        for (uint8 i; i < 6; ++i) {
            require(
                code[i].chunks.length != 0 && code[i].chunks.length <= 4
                    && code[i].length != 0 && code[i].length <= 49_152,
                InvalidCode()
            );
            CodeRecord storage record = _code[releaseId][i];
            record.creationHash = code[i].creationHash;
            record.length = code[i].length;
            for (uint256 j; j < code[i].chunks.length; ++j) {
                address chunk = code[i].chunks[j];
                bytes memory runtime = chunk.code;
                require(
                    runtime.length > 1 && runtime.length <= 24_576 && runtime[0] == 0,
                    InvalidCode()
                );
                record.chunks.push(chunk);
                record.chunkHashes.push(chunk.codehash);
            }
            bytes memory creation = _creationCode(record);
            require(keccak256(creation) == code[i].creationHash, InvalidCode());
        }
        emit ReleasePublished(releaseId, sourceRevision, manifestHash);
    }

    /// @notice Revoke future creation without changing the immutable release record.
    function revokeRelease(bytes32 releaseId) external onlyOwner {
        require(_releases[releaseId].exists, InvalidRelease());
        _releases[releaseId].revoked = true;
        emit ReleaseRevoked(releaseId);
    }

    function release(bytes32 releaseId) external view returns (Release memory) {
        return _releases[releaseId];
    }

    /// @notice Read verified creation bytecode; complete constructor args are added by NodeDeployer.
    function creationCode(bytes32 releaseId, uint8 child)
        external
        view
        returns (bytes memory)
    {
        require(_releases[releaseId].exists && child < 6, InvalidRelease());
        return _creationCode(_code[releaseId][child]);
    }

    function creationCodeHash(bytes32 releaseId, uint8 child)
        external
        view
        returns (bytes32)
    {
        require(_releases[releaseId].exists && child < 6, InvalidRelease());
        return _code[releaseId][child].creationHash;
    }

    function _creationCode(CodeRecord storage record)
        private
        view
        returns (bytes memory result)
    {
        result = new bytes(record.length);
        uint256 offset;
        for (uint256 i; i < record.chunks.length; ++i) {
            address chunk = record.chunks[i];
            require(chunk.codehash == record.chunkHashes[i], InvalidCode());
            uint256 len = chunk.code.length - 1;
            require(offset + len <= record.length, InvalidCode());
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(result, 32), offset), 1, len)
            }
            offset += len;
        }
        require(
            offset == record.length && keccak256(result) == record.creationHash,
            InvalidCode()
        );
    }

    function proposeProtocolOwner(address next) external onlyOwner {
        require(next != address(0), ZeroAddress());
        pendingProtocolOwner = next;
        emit ProtocolOwnerProposed(protocolOwner, next);
    }

    function cancelProtocolOwnerTransfer() external onlyOwner {
        pendingProtocolOwner = address(0);
        emit ProtocolOwnerProposed(protocolOwner, address(0));
    }

    function acceptProtocolOwner() external {
        require(msg.sender == pendingProtocolOwner, Unauthorized());
        address previous = protocolOwner;
        protocolOwner = msg.sender;
        pendingProtocolOwner = address(0);
        emit ProtocolOwnerTransferred(previous, msg.sender);
    }
}

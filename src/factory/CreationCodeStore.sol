// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @notice Immutable STOP-prefixed data. Split creation bytecode into <=24,575-byte chunks.
contract CreationCodeStore {
    error InvalidChunkLength();

    constructor(bytes memory data) {
        require(data.length != 0 && data.length <= 24_575, InvalidChunkLength());
        bytes memory code = bytes.concat(hex"00", data);
        assembly ("memory-safe") {
            return(add(code, 32), mload(code))
        }
    }
}

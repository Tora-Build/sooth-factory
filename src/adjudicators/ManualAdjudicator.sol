// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {AdjudicatorBase} from "./AdjudicatorBase.sol";

/**
 * @title ManualAdjudicator
 * @notice Demo / test-only adjudicator. Resolver calls resolve(), settle
 *         proceeds after veto period. No attestation required.
 *         DO NOT deploy as a canonical adjudicator on chains holding real value.
 */
contract ManualAdjudicator is AdjudicatorBase {
    constructor(address _owner, address _marketFactory, uint48 _vetoPeriod)
        AdjudicatorBase(_owner, _marketFactory, _vetoPeriod)
    {}

    function _requiresAttestation() internal pure override returns (bool) {
        return false;
    }

    function _verifyAttestation(address, bytes calldata) internal pure override {}

    function _onConfigure(address, bytes memory) internal pure override {}
}

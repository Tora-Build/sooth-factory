// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {LPPositionManager} from "src/LPPositionManager.sol";

/// @notice TEST-ONLY call-shape adapter for one ERC-6909 LP position.
/// @dev Not a mock: every call forwards to the real `LPPositionManager`. When each LP
///      entry was its own ERC-20 the accounting tests read `lp.balanceOf(who)` and
///      `lp.totalSupply()`. Those balances now live in the manager under a position id,
///      and this binds (manager, id) so the assertions keep their original shape and the
///      ERC-6909 migration stays reviewable. The 6909 surface itself is tested directly
///      in `test/unit/LPPositionToken.t.sol`.
contract LPPositionView {
    LPPositionManager public immutable manager;
    uint256 public immutable id;

    constructor(LPPositionManager manager_, uint256 id_) {
        manager = manager_;
        id = id_;
    }

    function balanceOf(address holder) external view returns (uint256) {
        return manager.balanceOf(holder, id);
    }

    function totalSupply() external view returns (uint256) {
        return manager.totalSupply(id);
    }
}

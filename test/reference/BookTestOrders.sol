// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// @dev Explicit v5 order terms for lifecycle fixtures; no external reads consume pranks.
library BookTestOrders {
    function buy(uint8 outcome, uint16 tick, uint128 amount, uint32 matchLimit)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p = _terms(outcome, tick, amount, matchLimit);
        p.maxTokenIn = uint256(amount) * 2 + 2;
    }

    function sell(uint8 outcome, uint16 tick, uint128 amount, uint32 matchLimit)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p = _terms(outcome, tick, amount, matchLimit);
        p.action = 1;
    }

    function _terms(uint8 outcome, uint16 tick, uint128 amount, uint32 matchLimit)
        private
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p.outcome = outcome;
        p.priceTick = tick;
        p.amount = amount;
        p.matchLimit = matchLimit;
        p.validUntil = uint64(block.timestamp + 1 days);
        p.rest = true;
    }
}

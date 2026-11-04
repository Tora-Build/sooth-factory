// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Earning-time ordinary and contingent Token-A fees for separate LP entries.
/// @dev Internal accounting only: no custody or public entrypoints. Positions are keyed
/// by the controller's global position id; the controller must checkpoint PRE-transfer
/// balances and freeze at settlement.
/// Weights are fixed entry weights; common CAPITAL growth does not change their ratios.
/// Each State belongs to exactly one market/token. All fee amounts are native units.
library PositionFeeAccounting {
    struct Pair {
        uint256 ordinary;
        uint256 contingent;
    }

    struct Position {
        uint256 weight;
        uint256 initialSupply;
        Pair entry;
        mapping(address => Pair) paidIndex;
    }

    struct Account {
        Pair earned;
        Pair remainder;
    }

    struct State {
        uint256 totalWeight;
        Pair index;
        Pair funded;
        uint256 paid;
        bool frozen;
        bool timeout;
        mapping(uint256 => Position) positions;
        mapping(address => Account) accounts;
    }

    uint256 internal constant R = 1e54;

    error InvalidPosition();
    error InvalidPhase();
    error InsufficientBacking();

    function register(
        State storage self,
        uint256 positionId,
        uint256 weight,
        uint256 supply
    ) internal {
        require(!self.frozen, InvalidPhase());
        require(
            weight > 0 && supply > 0 && self.positions[positionId].weight == 0,
            InvalidPosition()
        );
        Position storage p = self.positions[positionId];
        p.weight = weight;
        p.initialSupply = supply;
        p.entry = self.index;
        self.totalWeight += weight;
    }

    /// @dev Round down; unallocated division dust stays backed, not redistributed to
    /// later entrants. Never carry market-level division remainder across a weight change.
    function accrue(State storage self, uint256 ordinary, uint256 contingent) internal {
        require(!self.frozen && self.totalWeight > 0, InvalidPhase());
        self.index.ordinary += Math.mulDiv(ordinary, R, self.totalWeight);
        self.index.contingent += Math.mulDiv(contingent, R, self.totalWeight);
        self.funded.ordinary += ordinary;
        self.funded.contingent += contingent;
    }

    function checkpoint(
        State storage self,
        uint256 positionId,
        address holder,
        uint256 balance
    ) internal {
        Pair memory current = positionIndex(self, positionId);
        if (holder == address(0)) return;
        Pair storage prior = self.positions[positionId].paidIndex[holder];
        Account storage account = self.accounts[holder];
        (uint256 whole, uint256 fraction) =
            credit(balance, current.ordinary - prior.ordinary, account.remainder.ordinary);
        account.earned.ordinary += whole;
        account.remainder.ordinary = fraction;
        (whole, fraction) = credit(
            balance, current.contingent - prior.contingent, account.remainder.contingent
        );
        account.earned.contingent += whole;
        account.remainder.contingent = fraction;
        prior.ordinary = current.ordinary;
        prior.contingent = current.contingent;
    }

    function freeze(State storage self, bool timeoutInvalid) internal {
        require(!self.frozen, InvalidPhase());
        self.frozen = true;
        self.timeout = timeoutInvalid;
    }

    /// @notice Credit available after checkpoints. No iteration over positions.

    /// @dev Caller must pay from the same market's Token-A LP fee bucket. A reverted
    /// token transfer must revert this debit atomically. No USDG ledger is accepted.
    function take(State storage self, address holder) internal returns (uint256 amount) {
        require(self.frozen, InvalidPhase());
        amount = claimable(self, holder);
        Account storage account = self.accounts[holder];
        account.earned.ordinary = 0;
        if (self.timeout) {
            account.earned.contingent = 0;
            account.remainder.ordinary =
                (account.remainder.ordinary + account.remainder.contingent) % R;
            account.remainder.contingent = 0;
        }
        self.paid += amount;
        require(
            self.paid
                <= self.funded.ordinary + (self.timeout ? self.funded.contingent : 0),
            InsufficientBacking()
        );
    }

    function positionIndex(State storage self, uint256 positionId)
        internal
        view
        returns (Pair memory result)
    {
        Position storage p = self.positions[positionId];
        require(p.weight > 0, InvalidPosition());
        // The original supply is immutable, including after partial burns.
        result.ordinary = Math.mulDiv(
            self.index.ordinary - p.entry.ordinary, p.weight, p.initialSupply
        );
        result.contingent = Math.mulDiv(
            self.index.contingent - p.entry.contingent, p.weight, p.initialSupply
        );
    }

    function claimable(State storage self, address holder)
        internal
        view
        returns (uint256)
    {
        if (!self.frozen) return 0;
        Account storage account = self.accounts[holder];
        uint256 amount = account.earned.ordinary;
        if (self.timeout) {
            amount += account.earned.contingent;
            amount += (account.remainder.ordinary + account.remainder.contingent) / R;
        }
        return amount;
    }

    /// @dev Exact over the rationals: after every call,
    ///      `whole + fraction/R == balance*delta/R + carry/R`. Exposed `internal` so a
    ///      downstream 1:1 wrapper can run the identical accumulator over its own
    ///      holders rather than keeping a copy that can drift from this one.
    function credit(uint256 balance, uint256 delta, uint256 carry)
        internal
        pure
        returns (uint256 whole, uint256 fraction)
    {
        whole = Math.mulDiv(balance, delta, R);
        uint256 remainder = mulmod(balance, delta, R) + carry;
        whole += remainder / R;
        fraction = remainder % R;
    }
}

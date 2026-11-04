// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Test-only interval accounting. No tokens, pricing, authorization or lifecycle.
/// @dev Caller supplies funded deposits and valid trade costs. Never a production entrypoint.
contract PositionLedgerHarness {
    uint256 public constant SCALE = 1e36;

    struct Interval {
        int256 low;
        int256 high;
    }

    struct Position {
        uint256 deposit;
        uint256 weight;
        Interval cashEntry;
        Interval[2] shareEntry;
        Interval feeEntry;
        address owner;
        uint256 remaining;
        uint256 frozenPayout;
        uint256 feePaidScaled;
        uint256 claimedWad;
        uint256 nativePaid;
        uint256 claimScale;
    }

    Interval public growth = Interval(int256(SCALE), int256(SCALE));
    Interval public cash;
    Interval[2] public shares;
    Interval public fees;
    uint256 public totalWeight;
    uint256 public nextId;
    bool public settled;
    uint8 public outcome;
    int256 public collateral;
    int256[2] public actualShares;
    uint256 public feeBacking;
    uint256 public residualBacking;
    mapping(uint256 => Position) internal positions;
    mapping(address => uint256) public earnedFees;
    mapping(address => uint256) public feeRemainder;

    // Directed division handles negative values by rounding toward -/+ infinity.
    function divide(int256 value, uint256 multiplier, uint256 denominator)
        public
        pure
        returns (Interval memory r)
    {
        require(value != type(int256).min && denominator != 0, "domain");
        uint256 magnitude = uint256(value < 0 ? -value : value);
        uint256 floor = Math.mulDiv(magnitude, multiplier, denominator);
        uint256 ceil = floor + (mulmod(magnitude, multiplier, denominator) == 0 ? 0 : 1);
        require(ceil <= uint256(type(int256).max), "range");
        if (value >= 0) return Interval(int256(floor), int256(ceil));
        return Interval(-int256(ceil), -int256(floor));
    }

    function increment(Interval storage accumulator, int256 amount) internal {
        Interval memory delta = divide(amount, SCALE, totalWeight);
        accumulator.low += delta.low;
        accumulator.high += delta.high;
    }

    function difference(Interval memory current, Interval memory entry)
        internal
        pure
        returns (Interval memory)
    {
        return Interval(current.low - entry.high, current.high - entry.low);
    }

    function add(uint256 deposit, uint256 additionalB, address owner)
        external
        returns (uint256 id)
    {
        require(
            !settled && deposit > 0 && additionalB > 0 && owner != address(0), "entry"
        );
        require(deposit <= uint256(type(int256).max), "range");
        // Credit no more depth than requested; upper growth endpoint is conservative.
        uint256 weight = Math.mulDiv(additionalB, SCALE, uint256(growth.high));
        require(weight > 0, "zero weight");
        id = nextId++;
        Position storage p = positions[id];
        p.deposit = deposit;
        p.weight = weight;
        p.cashEntry = cash;
        p.shareEntry = shares;
        p.feeEntry = fees;
        p.owner = owner;
        p.remaining = deposit;
        totalWeight += weight;
        collateral += int256(deposit);
    }

    function trade(
        uint8 side,
        int256 delta,
        int256 signedCost,
        uint256 capital,
        uint256 lpFee
    ) external {
        require(!settled && totalWeight > 0 && side < 2, "trade");
        require(
            capital <= uint256(type(int256).max) && lpFee <= uint256(type(int256).max),
            "range"
        );
        actualShares[side] += delta;
        require(actualShares[side] >= 0, "unowned shares");
        int256 retained = signedCost + int256(capital);
        collateral += retained;
        require(collateral >= 0, "collateral");
        increment(cash, retained);
        increment(shares[side], delta);
        increment(fees, int256(lpFee));
        increment(growth, int256(capital));
        feeBacking += lpFee;
    }

    function residual(uint256 id, uint8 selected)
        public
        view
        returns (Interval memory r)
    {
        require(id < nextId && selected < 3, "position/outcome");
        Position storage p = positions[id];
        Interval memory c = difference(cash, p.cashEntry);
        Interval memory y = difference(shares[0], p.shareEntry[0]);
        Interval memory n = difference(shares[1], p.shareEntry[1]);
        Interval memory exposure;
        if (selected == 0) {
            exposure = y;
        } else if (selected == 1) {
            exposure = n;
        } else {
            exposure.low = divide(y.low + n.low, 1, 2).low;
            exposure.high = divide(y.high + n.high, 1, 2).high;
        }
        r.low = int256(p.deposit) + divide(c.low - exposure.high, p.weight, SCALE).low;
        r.high = int256(p.deposit) + divide(c.high - exposure.low, p.weight, SCALE).high;
    }

    function checkpoint(uint256 id) public {
        require(id < nextId, "position");
        Position storage p = positions[id];
        Interval memory accrued = difference(fees, p.feeEntry);
        int256 low = divide(accrued.low, p.weight, 1).low;
        uint256 cumulative = low > 0 ? uint256(low) : 0;
        if (cumulative > p.feePaidScaled) {
            uint256 total = feeRemainder[p.owner] + cumulative - p.feePaidScaled;
            earnedFees[p.owner] += total / SCALE;
            feeRemainder[p.owner] = total % SCALE;
            p.feePaidScaled = cumulative;
        }
    }

    function transfer(uint256 id, address recipient) external {
        require(
            !settled && id < nextId && msg.sender == positions[id].owner
                && recipient != address(0),
            "owner"
        );
        checkpoint(id);
        positions[id].feeEntry = fees;
        positions[id].feePaidScaled = 0;
        positions[id].owner = recipient;
    }

    function finalize(uint8 selected) external {
        require(!settled && selected < 3, "outcome");
        int256 liability = selected == 0 ? actualShares[0] : actualShares[1];
        if (selected == 2) {
            liability = divide(actualShares[0] + actualShares[1], 1, 2).high;
        }
        require(collateral >= liability, "insolvent");
        residualBacking = uint256(collateral - liability);
        outcome = selected;
        settled = true;
        // Deliberate test-only loop: production computes each position lazily.
        for (uint256 id; id < nextId; id++) {
            Interval memory r = residual(id, selected);
            require(r.high >= 0, "negative residual");
            positions[id].frozenPayout = r.low > 0 ? uint256(r.low) : 0;
        }
    }

    function claim(uint256 id, uint256 units, uint8 decimals)
        external
        returns (uint256 native)
    {
        require(settled && decimals <= 18 && id < nextId, "claim");
        Position storage p = positions[id];
        require(msg.sender == p.owner && units > 0 && units <= p.remaining, "owner/units");
        uint256 scale = 10 ** (18 - decimals);
        if (p.claimScale == 0) p.claimScale = scale;
        require(p.claimScale == scale, "precision changed");
        p.remaining -= units;
        uint256 cumulativeWad =
            Math.mulDiv(p.frozenPayout, p.deposit - p.remaining, p.deposit);
        // Cumulative rounding makes splitting a claim immaterial for one owner.
        uint256 cumulativeNative = cumulativeWad / scale;
        native = cumulativeNative - p.nativePaid;
        p.claimedWad = cumulativeWad;
        p.nativePaid = cumulativeNative;
        residualBacking -= native * scale;
    }

    function claimFees() external returns (uint256 amount) {
        require(settled, "settlement");
        amount = earnedFees[msg.sender];
        earnedFees[msg.sender] = 0;
        feeBacking -= amount;
    }
}

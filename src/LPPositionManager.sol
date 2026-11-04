// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ERC6909TokenSupply
} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import {ITruthMarket} from "./interfaces/ITruthMarket.sol";
import {PositionFeeAccounting} from "./libraries/PositionFeeAccounting.sol";

interface IPositionEngineGuard {
    function accountingLocked() external view returns (bool);
}

/// @notice Separate-entry accounting and the receipts themselves. Holds no collateral.
/// @dev Only the AMM supplies funded entries/trades; only its FeeVault supplies fees.
/// Market quantities use WAD, entry weights have 18 additional precision digits,
/// signed per-weight intervals use 1e54. All work is constant-size per position.
///
/// Each entry is an ERC-6909 id in this contract rather than its own deployed ERC-20.
/// Ids are global across markets because ERC-6909 balances are keyed `[owner][id]`;
/// `Entry.market` records which market an id belongs to. Because the receipts live
/// here, the pre-transfer fee checkpoint is an internal `_update` hook rather than an
/// external callback, so the old controller callback and its guard are gone.
contract LPPositionManager is ERC6909TokenSupply {
    using PositionFeeAccounting for PositionFeeAccounting.State;

    struct Interval {
        int256 low;
        int256 high;
    }

    struct Market {
        uint256 weight;
        uint256 count;
        Interval cash;
        Interval[2] shares;
    }

    struct Entry {
        address market;
        uint256 deposit;
        uint256 weight;
        Interval cash;
        Interval[2] shares;
        mapping(address => uint256) burned;
        mapping(address => uint256) credited;
    }

    uint256 private constant R = 1e54;
    uint256 private constant WEIGHT_SCALE = 1e18;
    address public immutable engine;
    address public immutable vault;
    mapping(address => Market) private _markets;
    mapping(uint256 => Entry) private _entries;
    /// @notice Next global position id. Ids are never reused and START AT 1, so that
    ///         zero is always "no position" — callers and storage can use it as a null
    ///         sentinel the way address(0) worked when each entry was its own contract.
    uint256 public nextPositionId = 1;
    mapping(address => PositionFeeAccounting.State) private _fees;

    event PositionOpened(
        address indexed market,
        uint256 indexed positionId,
        address indexed owner,
        uint256 marketIndex,
        uint256 deposit,
        uint256 weight
    );

    error Unauthorized();
    error InvalidEntry();
    error InvalidPhase();
    error ArithmeticDomain();

    modifier onlyEngine() {
        require(msg.sender == engine, Unauthorized());
        _;
    }
    modifier onlyVault() {
        require(msg.sender == vault, Unauthorized());
        _;
    }

    constructor(address engine_, address vault_) {
        require(engine_ != address(0) && vault_ != address(0), Unauthorized());
        engine = engine_;
        vault = vault_;
    }

    function bootstrap(address market, address owner, uint256 b, uint256 deposit)
        external
        onlyEngine
        returns (uint256 positionId)
    {
        require(_markets[market].count == 0, InvalidEntry());
        positionId = nextPositionId++;
        _open(market, positionId, owner, b * WEIGHT_SCALE, deposit);
    }

    function add(
        address market,
        address owner,
        uint256 bBefore,
        uint256 db,
        uint256 deposit
    ) external onlyEngine returns (uint256 positionId) {
        Market storage m = _markets[market];
        require(m.count > 0 && ITruthMarket(market).isLiquidityOpen(), InvalidPhase());
        // Round new weight UP: normalization can only reduce old positions' depth,
        // never give them extra unfunded risk. The quote funds the new entry's
        // sub-weight over-allocation using the old market's max-loss / weight bound.
        uint256 weight = Math.mulDiv(db, m.weight, bBefore, Math.Rounding.Ceil);
        positionId = nextPositionId++;
        _open(market, positionId, owner, weight, deposit);
    }

    function recordTrade(address market, uint8 side, int256 shares, int256 retainedCash)
        external
        onlyEngine
    {
        Market storage m = _markets[market];
        require(m.weight > 0 && side < 2, InvalidEntry());
        _increment(m.cash, retainedCash, m.weight);
        _increment(m.shares[side], shares, m.weight);
    }

    function redeem(address market, uint256 positionId, address holder, uint256 units)
        external
        onlyEngine
        returns (uint256 wad)
    {
        Entry storage e = _entries[positionId];
        require(e.market == market && units > 0, InvalidEntry());
        require(ITruthMarket(market).isSettled(), InvalidPhase());
        // Transfers are locked at settlement, so cumulative rounding can be per holder.
        e.burned[holder] += units;
        uint256 cumulative = Math.mulDiv(
            residual(positionId, ITruthMarket(market).winningOutcome()),
            e.burned[holder],
            e.deposit
        );
        wad = cumulative - e.credited[holder];
        e.credited[holder] = cumulative;
        _burn(holder, positionId, units);
    }

    function checkpointFees(uint256 positionId, address holder) external {
        require(!IPositionEngineGuard(engine).accountingLocked(), InvalidPhase());
        _checkpoint(positionId, holder);
    }

    /// @notice Checkpoint during an engine-orchestrated combined claim.
    /// @dev `checkpointFees` refuses to run while the engine's reentrancy guard is held,
    ///      so a fee checkpoint can never observe half-written engine accounting. The
    ///      engine's own combined claim holds that guard for its whole body, so it needs
    ///      a path that does not consult it.
    ///
    ///      Safety rests on the call chain, not on the guard: only the vault may call
    ///      this, only the engine may call the vault entry point that reaches it
    ///      (`claimLPDividendFor` is engine-gated), and the engine only calls it AFTER
    ///      the redeem and floor legs have fully completed their writes. The state this
    ///      checkpoint reads is therefore already settled, which is exactly what the
    ///      guard protects. Any new caller of this function breaks that argument.
    function checkpointFeesForClaim(uint256 positionId, address holder)
        external
        onlyVault
    {
        _checkpoint(positionId, holder);
    }

    function accrueFees(address market, uint256 ordinary, uint256 contingent)
        external
        onlyVault
    {
        _fees[market].accrue(ordinary, contingent);
    }

    function finalizeFees(address market, bool timeout) external onlyVault {
        _fees[market].freeze(timeout);
    }

    function takeFees(address market, address holder)
        external
        onlyVault
        returns (uint256)
    {
        return _fees[market].take(holder);
    }

    function claimableFees(address market, address holder)
        external
        view
        returns (uint256)
    {
        return _fees[market].claimable(holder);
    }

    /// @notice The position's CUMULATIVE per-unit fee index, plus the owning market's
    ///         finalization flags.
    /// @dev Both legs are R = 1e54 scaled and denominated in native Token-A units per
    ///      unit of the entry's IMMUTABLE `initialSupply`, so they apply unchanged to
    ///      any balance denominated in 6909 units of this id — including an ERC-20 that
    ///      is 1:1 with them. Monotone non-decreasing, and terminal once `frozen`:
    ///      `accrue` reverts while frozen and `entry`/`weight`/`initialSupply` never
    ///      move.
    ///
    ///      Unlike `claimableFees` this does NOT gate on the freeze, which is exactly
    ///      what lets a wrapper checkpoint its own holders mid-life. Pure view, safe to
    ///      call from inside another contract's transfer hook.
    ///
    ///      `timeout` is the flag `claimable()`/`take()` branch on — the adjudicator
    ///      bucket redirected to LPs by permissionless invalidation. A downstream
    ///      accumulator must read it here rather than infer it from `settlementKind()`.
    function positionFeeIndex(uint256 positionId)
        external
        view
        returns (uint256 ordinary, uint256 contingent, bool frozen, bool timeout)
    {
        address market = _entries[positionId].market;
        require(market != address(0), InvalidEntry());
        PositionFeeAccounting.State storage s = _fees[market];
        PositionFeeAccounting.Pair memory p = s.positionIndex(positionId);
        return (p.ordinary, p.contingent, s.frozen, s.timeout);
    }

    function positionMarket(uint256 positionId) external view returns (address) {
        return _entries[positionId].market;
    }

    function positionCount(address market) external view returns (uint256) {
        return _markets[market].count;
    }

    function totalWeight(address market) external view returns (uint256) {
        return _markets[market].weight;
    }

    function residual(uint256 positionId, uint8 outcome) public view returns (uint256) {
        Entry storage e = _entries[positionId];
        require(e.market != address(0) && outcome <= 2, InvalidEntry());
        Market storage m = _markets[e.market];
        int256 cash = m.cash.low - e.cash.high;
        int256 exposure;
        if (outcome < 2) {
            exposure = m.shares[outcome].high - e.shares[outcome].low;
        } else {
            exposure =
            _divide(
                m.shares[0].high - e.shares[0].low + m.shares[1].high - e.shares[1].low,
                1,
                2
            )
            .high;
        }
        int256 value = int256(e.deposit) + _divide(cash - exposure, e.weight, R).low;
        return value > 0 ? uint256(value) : 0;
    }

    /// @dev Fee entitlement is credited against PRE-transfer balances, so both sides
    ///      are checkpointed before ERC-6909 moves any units. Settlement locks holder
    ///      transfers; mints and burns still pass so redemption works after settlement.
    function _update(address from, address to, uint256 id, uint256 amount)
        internal
        override
    {
        address market = _entries[id].market;
        require(market != address(0), InvalidEntry());
        if (from != address(0) && to != address(0)) {
            require(!ITruthMarket(market).isSettled(), InvalidPhase());
        }
        _checkpoint(id, from);
        if (to != from) _checkpoint(id, to);
        super._update(from, to, id, amount);
    }

    function _open(
        address market,
        uint256 positionId,
        address owner,
        uint256 weight,
        uint256 deposit
    ) private {
        require(weight > 0 && deposit > 0 && deposit <= 1e36, ArithmeticDomain());
        require(_entries[positionId].market == address(0), InvalidEntry());
        Market storage m = _markets[market];
        require(m.count < type(uint32).max, ArithmeticDomain());
        Entry storage e = _entries[positionId];
        e.market = market;
        e.deposit = deposit;
        e.weight = weight;
        e.cash = m.cash;
        e.shares = m.shares;
        m.weight += weight;
        require(m.weight <= 1e54, ArithmeticDomain());
        _fees[market].register(positionId, weight, deposit);
        _mint(owner, positionId, deposit);
        emit PositionOpened(market, positionId, owner, m.count++, deposit, weight);
    }

    function _increment(Interval storage value, int256 delta, uint256 weight) private {
        Interval memory d = _divide(delta, R, weight);
        value.low += d.low;
        value.high += d.high;
    }

    function _checkpoint(uint256 positionId, address holder) private {
        if (holder == address(0)) return;
        address market = _entries[positionId].market;
        require(market != address(0), InvalidEntry());
        _fees[market].checkpoint(positionId, holder, balanceOf(holder, positionId));
    }

    function _divide(int256 value, uint256 numerator, uint256 denominator)
        private
        pure
        returns (Interval memory r)
    {
        require(value != type(int256).min, ArithmeticDomain());
        uint256 magnitude = uint256(value < 0 ? -value : value);
        uint256 lo = Math.mulDiv(magnitude, numerator, denominator);
        uint256 hi = lo + (mulmod(magnitude, numerator, denominator) == 0 ? 0 : 1);
        require(hi <= uint256(type(int256).max), ArithmeticDomain());
        return
            value < 0
                ? Interval(-int256(hi), -int256(lo))
                : Interval(int256(lo), int256(hi));
    }
}

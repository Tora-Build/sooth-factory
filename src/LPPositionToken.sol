// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAMMEngine} from "./interfaces/IAMMEngine.sol";
import {ITruthMarket} from "./interfaces/ITruthMarket.sol";
import {LPPositionManager} from "./LPPositionManager.sol";
import {PositionFeeAccounting} from "./libraries/PositionFeeAccounting.sol";

/// @notice Opt-in ERC-20 wrapper around ONE ERC-6909 LP position.
/// @dev LP entries are ERC-6909 ids in `LPPositionManager`, which nothing outside
///      this protocol understands: no wallet shows the balance, no AMM or lending market can
///      hold it. This wraps a single id 1:1 so one position can travel as an ordinary
///      ERC-20. It is deployed only for positions that need that, so the deployment cost
///      is paid per position that leaves rather than on every entry.
///
///      Fee entitlement follows the ERC-20 balance OVER TIME. The wrapper runs the same
///      accumulator `LPPositionManager` runs one level up: on every ERC-20 balance
///      change it credits both parties against their PRE-transfer balances at the
///      position's current per-unit index. Wrapping late therefore earns only what
///      accrues after the wrap, and cannot take a share of what accrued before it.
///      (Audit M-1, fixed.)
///
///      `settle()` collects TWO independently measured pots — fees and principal — and
///      they are paid on different keys. Principal is pro rata by units against the
///      supply frozen at settlement. Fees are an absolute per-address receivable, so a
///      post-settlement ERC-20 transfer conveys the principal claim and NOT the
///      seller's earned fees: the seller must call `claimFees()`. Sell before
///      `settle()` to sell everything.
///
///      CONSEQUENCE FOR POOLED UNITS, stated plainly: while the ERC-20 sits in an AMM
///      pair, a lending market or a vault, that CONTRACT is the holder of record and
///      the fees accrue to its address. `claimFeesFor(address)` is permissionless and
///      push-only so those fees can always be delivered to it, but what the venue then
///      does with them is that venue's business. This is inherent to any time-weighted
///      accrual, not a quirk of this implementation.
///
///      Settlement changes the instrument. `LPPositionManager` locks holder-to-holder
///      6909 transfers once a market settles, so `unwrap` cannot work after that.
///      Instead anyone may call `settle()`; from then on the ERC-20 is a claim on
///      Token-A proceeds and holders call `redeem()`.
contract LPPositionToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Mirrors `PositionFeeAccounting.Pair`.
    struct Pair {
        uint256 ordinary;
        uint256 contingent;
    }

    /// @dev Mirrors `PositionFeeAccounting.{Position.paidIndex, Account}`, flattened:
    ///      this wrapper covers exactly one position, so there is no positionId key.
    struct Account {
        Pair paidIndex; // per-unit index this holder has already been credited to
        Pair earned; // whole native Token-A units credited to this holder
        Pair remainder; // sub-unit carry scaled by R; invariant: always < R
    }

    uint256 private constant R = PositionFeeAccounting.R;

    LPPositionManager public immutable manager;
    IAMMEngine public immutable engine;
    address public immutable market;
    uint256 public immutable positionId;
    IERC20 public immutable tokenA;

    /// @dev Per-ERC-20-holder fee accumulator.
    mapping(address => Account) private _accounts;

    /// @dev The per-unit index frozen at `settle()`. Read instead of the manager once
    ///      `indexFrozen`, so post-settle transfers make no external call.
    Pair private _finalIndex;

    /// @notice True once `_finalIndex` is authoritative. Set only after every external
    ///         call in `settle()` has returned, so a Token-A callback that re-enters
    ///         `transfer` mid-settle takes the live-manager branch and can never
    ///         checkpoint anyone against an unwritten cache.
    bool public indexFrozen;
    /// @notice The market invalidated, so the contingent (adjudicator) leg is payable.
    ///         Mirrors `PositionFeeAccounting.State.timeout`.
    bool public contingentPayable;
    bool public settled;

    /// @notice Native Token A measured on the FEE leg of `settle()`. Paid per address.
    uint256 public feePot;
    /// @notice Fee cash not yet paid out. The hard cap on every fee payout.
    uint256 public feeCashRemaining;
    /// @notice Native Token A measured on the PRINCIPAL leg, split pro rata by units.
    uint256 public proceeds;
    /// @notice ERC-20 supply frozen at `settle()`; denominator for the principal split.
    uint256 public supplyAtSettle;

    event Wrapped(address indexed holder, uint256 amount);
    event Unwrapped(address indexed holder, uint256 amount);
    event Settled(
        uint256 proceeds, uint256 feePot, uint256 supply, bool contingentPayable
    );
    event Redeemed(
        address indexed holder, uint256 amount, uint256 principal, uint256 fees
    );
    event FeesClaimed(address indexed holder, uint256 paid);

    error AlreadySettled();
    error NotSettled();
    error MarketNotSettled();
    error ZeroAmount();
    error WrongPosition();
    error NothingToClaim();
    error SelfTransfer();

    constructor(LPPositionManager manager_, uint256 positionId_)
        ERC20("Sooth LP position", "sLP-P")
    {
        address market_ = manager_.positionMarket(positionId_);
        require(market_ != address(0), WrongPosition());
        manager = manager_;
        positionId = positionId_;
        market = market_;
        engine = IAMMEngine(manager_.engine());
        tokenA = IERC20(IAMMEngine(manager_.engine()).tokenAOf(market_));
    }

    // ============================================
    // Wrap / unwrap
    // ============================================

    /// @notice Deposit 6909 units and receive ERC-20 units 1:1.
    /// @dev Approve this contract on the manager first, with `approve(spender, id,
    ///      amount)` or `setOperator`.
    function wrap(uint256 amount) external nonReentrant {
        require(!settled, AlreadySettled());
        require(amount > 0, ZeroAmount());
        manager.transferFrom(msg.sender, address(this), positionId, amount);
        _mint(msg.sender, amount);
        emit Wrapped(msg.sender, amount);
    }

    /// @notice Burn ERC-20 units and take the 6909 units back 1:1.
    /// @dev Only before the market settles: the manager locks holder transfers after
    ///      that, so use `settle()` then `redeem()` instead. Fees already accrued stay
    ///      claimable here via `claimFees()` after settlement.
    function unwrap(uint256 amount) external nonReentrant {
        require(!settled, AlreadySettled());
        require(amount > 0, ZeroAmount());
        _burn(msg.sender, amount);
        manager.transfer(msg.sender, positionId, amount);
        emit Unwrapped(msg.sender, amount);
    }

    // ============================================
    // Settlement
    // ============================================

    /// @notice Collect this position's proceeds once the market has settled.
    /// @dev TWO measured claims, not one pot split in two.
    ///
    ///      Leg 1 passes `units == 0`: `_redeemLP` is skipped entirely and
    ///      `_claimFloor` finds a zero entitlement under `allowZero`, so the vault
    ///      dividend is the only thing that can pay — every native unit that arrives is
    ///      fee cash. That call is also what drives `feeVault.finalize` →
    ///      `finalizeFees`, freezing the index.
    ///
    ///      Leg 2 passes the full unit balance. The index is frozen and leg 1 emptied
    ///      this contract's dividend account, so the fee call pays zero — every native
    ///      unit that arrives is principal.
    ///
    ///      Each leg measures its own Token-A balance delta, so a fee-on-transfer or
    ///      otherwise non-standard Token A can never let a split hand out more than
    ///      actually arrived. The engine's declared `feesPaid` (native units) is used
    ///      only to REATTRIBUTE within a leg, always clamped by that leg's measured
    ///      delta, so the total distributed is exactly `delta1 + delta2`. Both
    ///      reattribution branches are dead under today's engine; they exist so a future
    ///      engine change misroutes nothing and — unlike a `require` — cannot brick a
    ///      wrapper whose only exit is this function.
    ///
    ///      There is deliberately no `totalSupply() > 0` guard. Post-settlement `wrap`
    ///      is already impossible (the manager rejects the inbound 6909 transfer), and
    ///      a zero-supply wrapper can hold a real fee entitlement — everyone unwrapped,
    ///      but the fees they earned while wrapped are still owed to them. A guard here
    ///      would strand that cash for ever. `redeem` guards the denominator instead.
    function settle() external nonReentrant {
        require(!settled, AlreadySettled());
        require(ITruthMarket(market).isSettled(), MarketNotSettled());
        settled = true;
        // Supply cannot move during the legs: wrap/unwrap/redeem share this guard.
        supplyAtSettle = totalSupply();

        // ── leg 1: fees ──
        uint256 before = tokenA.balanceOf(address(this));
        (,, uint256 declared) = engine.claimAvailable(market, positionId, 0);
        uint256 delta = tokenA.balanceOf(address(this)) - before;
        uint256 fee = declared < delta ? declared : delta;
        feePot = fee;
        proceeds = delta - fee; // structurally zero today

        // ── leg 2: principal ──
        uint256 units = manager.balanceOf(address(this), positionId);
        // `units` can exceed `supplyAtSettle` only via a bare 6909 donation, which is
        // shared out per unit as a gift. With zero supply there is nobody to pay, so
        // the cash is left in the engine rather than pulled somewhere it cannot leave.
        if (units > 0 && supplyAtSettle > 0) {
            before = tokenA.balanceOf(address(this));
            (,, declared) = engine.claimAvailable(market, positionId, units);
            delta = tokenA.balanceOf(address(this)) - before;
            fee = declared < delta ? declared : delta; // structurally zero today
            feePot += fee;
            proceeds += delta - fee;
        }
        feeCashRemaining = feePot;

        // ── freeze the accumulator's inputs, only now that nothing external remains ──
        (uint256 o, uint256 c, bool frozen, bool timeout) =
            manager.positionFeeIndex(positionId);
        _finalIndex.ordinary = o;
        _finalIndex.contingent = c;
        contingentPayable = frozen && timeout;
        indexFrozen = frozen;

        emit Settled(proceeds, feePot, supplyAtSettle, contingentPayable);
    }

    // ============================================
    // Payouts
    // ============================================

    /// @notice Burn ERC-20 units for their principal share, plus this caller's whole
    ///         unpaid fee entitlement. One call.
    /// @dev Principal rounds down; the dust stays backing the remaining holders rather
    ///      than being paid to whoever redeems first. `_burn` runs the pre-burn
    ///      checkpoint, so the `_takeFees` immediately after it is a zero-delta harvest.
    function redeem(uint256 amount) external nonReentrant returns (uint256 paid) {
        require(settled, NotSettled());
        require(amount > 0, ZeroAmount());
        require(supplyAtSettle > 0, ZeroAmount());

        uint256 principal = Math.mulDiv(proceeds, amount, supplyAtSettle);
        _burn(msg.sender, amount);
        uint256 fees = _takeFees(msg.sender);

        paid = principal + fees;
        if (paid > 0) tokenA.safeTransfer(msg.sender, paid);
        emit Redeemed(msg.sender, amount, principal, fees);
    }

    /// @notice Collect your fee entitlement without burning units.
    function claimFees() external nonReentrant returns (uint256 paid) {
        return _payFees(msg.sender);
    }

    /// @notice Pay `holder` the fees it accrued, on anyone's behalf.
    /// @dev PERMISSIONLESS and PUSH-ONLY — the cash always goes to `holder`, never to
    ///      the caller, so this grants no authority over anyone's funds. It exists
    ///      because the ERC-20 holder of record may be a contract with no way to call
    ///      `claimFees()` itself: an AMM pair, a lending market, a vault — which is the
    ///      very population this wrapper exists to serve. Without it, the fees earned by
    ///      pooled units would be unreachable for ever.
    function claimFeesFor(address holder) external nonReentrant returns (uint256 paid) {
        return _payFees(holder);
    }

    // ============================================
    // Views
    // ============================================

    /// @notice What `redeem(amount)` would pay `holder`, split into its components.
    function previewRedeem(address holder, uint256 amount)
        external
        view
        returns (uint256 principal, uint256 fees)
    {
        if (settled && supplyAtSettle > 0 && amount > 0) {
            principal = Math.mulDiv(proceeds, amount, supplyAtSettle);
        }
        fees = feesClaimable(holder);
    }

    /// @notice Everything `settle()` collected, across both pots.
    /// @dev `proceeds` narrowed to principal-only in the M-1 fix; this is the old
    ///      meaning, kept for anything that reported the total.
    function totalCollected() external view returns (uint256) {
        return proceeds + feePot;
    }

    /// @notice What `holder` has accrued so far, in native Token A.
    /// @dev Indicative before `settle()`: nothing is payable until the market's fee
    ///      state freezes, and the contingent (adjudicator-redirect) leg is excluded
    ///      until the freeze says whether it is payable, so an invalidated market reads
    ///      LOW here. Not clamped by available cash — use `feesClaimable` for what
    ///      `redeem`/`claimFees` would actually pay.
    function feesAccrued(address holder) public view returns (uint256 owed) {
        Pair memory current = _currentIndex();
        Account storage a = _accounts[holder];
        uint256 balance = balanceOf(holder);
        (uint256 wo, uint256 fo) = PositionFeeAccounting.credit(
            balance, current.ordinary - a.paidIndex.ordinary, a.remainder.ordinary
        );
        owed = a.earned.ordinary + wo;
        if (!contingentPayable) return owed;
        (uint256 wc, uint256 fc) = PositionFeeAccounting.credit(
            balance, current.contingent - a.paidIndex.contingent, a.remainder.contingent
        );
        owed += a.earned.contingent + wc + (fo + fc) / R;
    }

    /// @notice Exactly what a fee claim would pay `holder` right now.
    function feesClaimable(address holder) public view returns (uint256) {
        if (!settled) return 0;
        uint256 owed = feesAccrued(holder);
        return owed > feeCashRemaining ? feeCashRemaining : owed;
    }

    // ============================================
    // Internal — the accumulator
    // ============================================

    /// @dev Fee entitlement is credited against PRE-transfer balances, so both sides are
    ///      checkpointed before ERC-20 moves any units — the same hook, at the same
    ///      point, in the same order as `LPPositionManager._update` one level up.
    ///      Applies to mint, burn and transfer alike, and STAYS ACTIVE after
    ///      settlement: a holder who never checkpointed and then transfers everything
    ///      away must be credited at the balance they actually held, or they lose the
    ///      lot. This is the single line most likely to be broken by a later refactor.
    function _update(address from, address to, uint256 value) internal override {
        // Units sent to this contract would accrue to an account with no beneficiary
        // and a principal claim nobody can burn. Refuse rather than create a black hole.
        require(to != address(this), SelfTransfer());
        Pair memory current = _currentIndex();
        _checkpoint(from, current);
        if (to != from) _checkpoint(to, current);
        super._update(from, to, value);
    }

    function _checkpoint(address holder, Pair memory current) private {
        if (holder == address(0)) return;
        Account storage a = _accounts[holder];
        uint256 balance = balanceOf(holder); // PRE-transfer: super._update has not run
        (uint256 whole, uint256 fraction) = PositionFeeAccounting.credit(
            balance, current.ordinary - a.paidIndex.ordinary, a.remainder.ordinary
        );
        a.earned.ordinary += whole;
        a.remainder.ordinary = fraction;
        (whole, fraction) = PositionFeeAccounting.credit(
            balance, current.contingent - a.paidIndex.contingent, a.remainder.contingent
        );
        a.earned.contingent += whole;
        a.remainder.contingent = fraction;
        a.paidIndex.ordinary = current.ordinary;
        a.paidIndex.contingent = current.contingent;
    }

    /// @dev Mirrors `PositionFeeAccounting.{claimable, take}`, including the timeout
    ///      rule and the `% R` remainder fold, with one difference: the payout is
    ///      clamped to the fee cash that actually arrived, and anything the cash could
    ///      not cover is RETAINED as entitlement rather than zeroed. The clamp is what
    ///      makes `sum(paid) <= feePot` hold unconditionally — for a fee-on-transfer,
    ///      rebasing or partially-paying Token A as much as for a well-behaved one.
    function _takeFees(address holder) private returns (uint256 paid) {
        _checkpoint(holder, _currentIndex());
        Account storage a = _accounts[holder];

        uint256 owed = a.earned.ordinary;
        if (contingentPayable) {
            owed += a.earned.contingent;
            owed += (a.remainder.ordinary + a.remainder.contingent) / R; // 0 or 1
        }
        if (owed == 0) return 0;

        uint256 cap = feeCashRemaining;
        paid = owed > cap ? cap : owed;
        feeCashRemaining = cap - paid;

        a.earned.ordinary = owed - paid; // retained, still claimable later
        if (contingentPayable) {
            a.earned.contingent = 0;
            a.remainder.ordinary = (a.remainder.ordinary + a.remainder.contingent) % R;
            a.remainder.contingent = 0;
        }
    }

    function _payFees(address holder) private returns (uint256 paid) {
        require(settled, NotSettled());
        require(holder != address(0), ZeroAmount());
        paid = _takeFees(holder);
        require(paid > 0, NothingToClaim());
        tokenA.safeTransfer(holder, paid);
        emit FeesClaimed(holder, paid);
    }

    /// @dev Before `settle()` the index is read live from the manager; afterwards the
    ///      frozen snapshot is used (`accrue` reverts once frozen, so it is the same
    ///      number without the staticcall).
    function _currentIndex() private view returns (Pair memory p) {
        if (indexFrozen) return _finalIndex;
        (p.ordinary, p.contingent,,) = manager.positionFeeIndex(positionId);
    }
}

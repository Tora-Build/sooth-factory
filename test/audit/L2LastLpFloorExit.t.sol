// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

/// @notice Token A at a factory-legal precision. Zero decimals is the minimum.
contract FloorToken is ERC20 {
    uint8 private immutable _precision;

    constructor(uint8 precision_) ERC20("Floor token", "FLR") {
        _precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Eight uneven LPs, dust trades, then a last-LP exit.
/// @dev Slack is `floor − sum(unpaid residuals)` in WAD. A single LP who still
///      owns the whole pool sits at slack 0 by construction: their residual is
///      the pool and `_redeemLP` uses `<=`. That bootstrap figure is stored
///      apart from the multi-LP minimum. The searched quantity is the slack
///      while two or more residuals are still unpaid, and the slack immediately
///      before the designated last LP redeems.
///
///      Redeem pays `mulDiv(residual, burned, deposit) − credited`. A full burn
///      of the holder who owns the supply pays exactly `residual`, and the floor
///      falls by the same wad. Slack 0 is the equality the check allows. Slack
///      −1 is a trapped exit.
contract LpFloorHandler is DualTokenBase {
    uint256 private constant SLOT_SETTLED = 10;
    uint256 private constant SLOT_SEED_YES = 11;
    uint256 private constant SLOT_SEED_NO = 12;
    uint256 private constant MAX_ACTS = 64;
    uint8 private constant ACT_ADD = 0;
    uint8 private constant ACT_BUY = 1;
    uint8 private constant ACT_SELL = 2;
    uint8 private constant ACT_SETTLE_MKT = 3;
    uint8 private constant ACT_SETTLE_TRADER = 4;
    uint8 private constant ACT_REDEEM = 5;
    uint8 private constant ACT_DUST = 6;
    uint8 private constant ACT_EXIT = 7;

    uint8 public immutable dec;
    uint16 public immutable feeBps;
    FloorToken public cash;
    LPPositionManager public manager;
    address[8] public actors;

    struct Entry {
        address owner;
        uint256 id;
        uint256 redeemed;
    }

    Entry[] internal entries;
    uint256[] internal actions;
    uint256[] public minActions;
    uint256[] public sharedActions;
    uint256[] public lastActions;

    bool public marketSettled;
    bool public cleared;
    uint8 public winning;
    int256 public bootstrapSlack = type(int256).max;
    int256 public minSlack = type(int256).max;
    int256 public minSharedSlack = type(int256).max;
    int256 public minLastLpSlack = type(int256).max;
    uint8 public minOutcome;
    uint8 public sharedOutcome;
    uint8 public lastOutcome;
    uint256 public sharedActive;
    bytes32 public trace;
    bytes32 public minTrace;
    bytes32 public sharedTrace;
    bytes32 public lastTrace;
    uint256 public calls;
    uint256 public buys;
    uint256 public sells;
    uint256 public adds;
    uint256 public redeems;
    uint256 public dusts;
    uint256 public campaignSeed;
    uint256 public notedSteps;
    uint8 public campaignKind;

    constructor(uint8 dec_, uint16 feeBps_) {
        dec = dec_;
        feeBps = feeBps_;
    }

    function setUp() public override {
        super.setUp();
        cash = new FloorToken(dec);
        actors[0] = creator;
        actors[1] = trader;
        actors[2] = alice;
        actors[3] = bob;
        actors[4] = address(0xA1004);
        actors[5] = address(0xA1005);
        actors[6] = address(0xA1006);
        actors[7] = address(0xA1007);
        uint256 endowment = 1_000_000 * 10 ** dec;
        for (uint256 i; i < actors.length; ++i) {
            cash.mint(actors[i], endowment);
            vm.startPrank(actors[i]);
            cash.approve(address(amm), type(uint256).max);
            cash.approve(address(marketFactory), type(uint256).max);
            vm.stopPrank();
        }
        // Publish before createMarket. The market pins the active version.
        vault.publishAmmConfig(
            IAmmFeeVault.AmmConfig(feeBps, 5000, 3000, 1000, 1000, treasury)
        );
        IMarketFactory.MarketParams memory p = _marketParams(
            "last LP floor",
            0,
            uint64(block.timestamp + 20 days),
            address(cash),
            25e18,
            0.5e18
        );
        vm.prank(creator);
        uint256 bootstrap;
        (market, bootstrap) = marketFactory.createMarket(p);
        entries.push(Entry(creator, bootstrap, 0));
        manager = LPPositionManager(amm.positionManager());
        assertEq(vault.feeBpsOf(market), feeBps, "fee pin");
        (uint256 qYes, uint256 qNo,) = amm.getMarketState(market);
        assertEq(_word(SLOT_SEED_YES), qYes, "seed YES slot");
        assertEq(_word(SLOT_SEED_NO), qNo, "seed NO slot");
        assertEq(_word(SLOT_SETTLED), 0, "settled slot");
        _measureBootstrap();
        _openUnevenBook();
        _seedDust();
        assertEq(entries.length, 8, "eight LP entries");
        assertGt(buys, 0, "no trade landed");
        assertFits();
    }

    function label(uint256 steps, uint8 kind) external {
        notedSteps = steps;
        campaignKind = kind;
    }

    function addLiquidity(uint256 who, uint256 raw) external {
        calls++;
        if (!_liquidityOpen()) return;
        uint256 span = bound(raw, 1, 4e18);
        uint256 db = raw % 11 == 0 ? 1 : span;
        if (_add(actors[who % 8], db)) {
            _act(ACT_ADD, who % 8, db);
            _observeAll();
        }
    }

    function buy(uint256 who, uint256 outcome, uint256 raw) external {
        calls++;
        if (!_trading()) return;
        uint256 shares = _shareSize(raw);
        outcome %= 2;
        if (_buy(actors[who % 8], uint8(outcome), shares)) {
            _act(ACT_BUY, outcome, shares);
            _observeAll();
        }
    }

    function sell(uint256 who, uint256 outcome, uint256 raw) external {
        calls++;
        if (!_trading()) return;
        address actor = actors[who % 8];
        outcome %= 2;
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        uint256 held = outcome == 1 ? yes : no;
        if (held < 2) return;
        uint256 shares = raw % 5 == 0 ? 1 : bound(raw, 1, held);
        if (_sell(actor, uint8(outcome), shares)) {
            _act(ACT_SELL, outcome, shares);
            _observeAll();
        }
    }

    function settleMarket(uint8 outcome) public {
        calls++;
        if (marketSettled) return;
        outcome %= 3;
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("l2-floor"));
        vm.warp(block.timestamp + 1 hours + 1);
        adjudicator.settle(market);
        marketSettled = true;
        winning = ITruthMarket(market).winningOutcome();
        assertEq(winning, outcome, "settled outcome");
        _act(ACT_SETTLE_MKT, outcome, 0);
        _observeAll();
    }

    function settleTrader(uint256 who) external {
        calls++;
        if (!marketSettled) return;
        if (_settleOne(actors[who % 8])) {
            _act(ACT_SETTLE_TRADER, who % 8, winning);
            _observeAll();
        }
    }

    function partialRedeem(uint256 index, uint256 raw) external {
        calls++;
        if (!marketSettled || entries.length == 0) return;
        uint256 i = index % entries.length;
        uint256 bal = manager.balanceOf(entries[i].owner, entries[i].id);
        if (bal < 2) return;
        uint256 amt = bound(raw, 1, bal - 1);
        _act(ACT_REDEEM, i, amt);
        _redeem(i, amt);
    }

    /// @dev Burn exactly one receipt wei. This is the rounding grain of a partial exit.
    function dustBurn(uint256 index) external {
        calls++;
        if (!marketSettled || entries.length == 0) return;
        _burnOne(index % entries.length);
    }

    /// @dev Last LP redeems after everyone else has been nibbled by 1-wei burns.
    ///      A trader settlement is inserted between burn rounds and between the
    ///      other full exits. Idempotent so a second call is a no-op.
    function exitAdversarial(uint8 outcome, uint256 seed) external {
        if (cleared) return;
        campaignSeed = seed;
        if (!marketSettled) settleMarket(outcome);
        _act(ACT_EXIT, outcome, seed);
        uint256 last = _pickLast(seed);
        if (seed & 1 == 1) {
            for (uint256 i; i < 4; ++i) {
                _settleOne(actors[i]);
            }
            _observeAll();
        }
        uint256 rounds = 4 + (seed % 4);
        for (uint256 r; r < rounds; ++r) {
            uint256 count = entries.length;
            for (uint256 i; i < count; ++i) {
                if (i == last) continue;
                _burnOne(i);
            }
            _settleOne(_actorAt(seed, r));
            _observeAll();
        }
        uint256 lastBurns = 4 + ((seed >> 4) % 4);
        for (uint256 r; r < lastBurns; ++r) {
            _burnOne(last);
        }
        bool reverse = (seed >> 1) & 1 == 1;
        uint256 n = entries.length;
        for (uint256 k; k < n; ++k) {
            uint256 i = reverse ? n - 1 - k : k;
            if (i == last) continue;
            _settleOne(_actorAt(seed, k));
            _redeemFull(i);
        }
        _recordLastSlack(last);
        _redeemFull(last);
        _settleTraders();
        _claimFloors();
        _assertClear();
        cleared = true;
        _writeCsv();
    }

    function assertFits() public {
        _assertShares();
        _assertSolvent();
        _observeAll();
    }

    function sharedActionCount() external view returns (uint256) {
        return sharedActions.length;
    }

    function lastActionCount() external view returns (uint256) {
        return lastActions.length;
    }

    function _measureBootstrap() internal {
        int256 tight = type(int256).max;
        for (uint8 outcome; outcome < 3; ++outcome) {
            (uint256 sum, uint256 active) = _residualSum(outcome);
            assertEq(active, 1, "bootstrap is the creator entry");
            int256 slack = _signedSlack(_floor(outcome), sum);
            if (slack < tight) tight = slack;
            assertGe(slack, 0, "bootstrap slack negative");
        }
        bootstrapSlack = tight;
    }

    function _openUnevenBook() internal {
        for (uint256 i; i < 7; ++i) {
            uint256 db = _unevenDepth(i);
            address actor = actors[(i + 1) % 8];
            _addStrict(actor, db);
            _act(ACT_ADD, (i + 1) % 8, db);
            _observeAll();
        }
    }

    function _seedDust() internal {
        uint256[3] memory sizes = [uint256(1), 1e12 + 1, 1e15];
        for (uint256 i; i < sizes.length; ++i) {
            if (_buy(actors[i % 8], uint8(i % 2), sizes[i])) {
                _act(ACT_BUY, i % 2, sizes[i]);
            }
            if (_buy(actors[(i + 3) % 8], uint8((i + 1) % 2), sizes[i])) {
                _act(ACT_BUY, (i + 1) % 2, sizes[i]);
            }
        }
        if (_buy(actors[1], 1, 1e18)) _act(ACT_BUY, 1, 1e18);
        (uint256 yes,) = amm.getPosition(market, actors[1]);
        if (yes > 1 && _sell(actors[1], 1, 1)) _act(ACT_SELL, 1, 1);
        _observeAll();
    }

    function _unevenDepth(uint256 i) internal pure returns (uint256) {
        if (i == 0) return 1e17;
        if (i == 1) return 1e17 + 1;
        if (i == 2) return 2e17 + 9;
        if (i == 3) return 4e17 + 27;
        if (i == 4) return 1e18 + 81;
        if (i == 5) return 2e18 + 243;
        return 6e18 + 1;
    }

    function _shareSize(uint256 raw) internal pure returns (uint256 span) {
        uint256 pick = raw % 7;
        if (pick == 0) return 1;
        if (pick == 1) return 1e12 + 1;
        if (pick == 2) return 1e15;
        span = raw % (2e18) + 1;
    }

    function _add(address actor, uint256 db) internal returns (bool) {
        if (!_liquidityOpen() || cash.balanceOf(actor) == 0) return false;
        try amm.quoteLiquidityWithState(market, db) returns (
            uint256 input, uint256 units, uint256 price, bytes32 stateHash
        ) {
            if (input == 0 || units == 0 || cash.balanceOf(actor) < input) return false;
            uint64 deadline = ITruthMarket(market).deadline();
            vm.prank(actor);
            (uint256 id,) = amm.increaseLiquidity(
                market,
                db,
                IAMMEngine.LiquidityLimits(
                    input, units, price, price, deadline, stateHash
                )
            );
            entries.push(Entry(actor, id, 0));
            adds++;
            return true;
        } catch {
            return false;
        }
    }

    function _addStrict(address actor, uint256 db) internal {
        (uint256 input, uint256 units, uint256 price, bytes32 stateHash) =
            amm.quoteLiquidityWithState(market, db);
        assertGt(input, 0, "uneven quote input");
        assertGt(units, 0, "uneven quote units");
        assertGe(cash.balanceOf(actor), input, "uneven endowment");
        uint64 deadline = ITruthMarket(market).deadline();
        vm.prank(actor);
        (uint256 id,) = amm.increaseLiquidity(
            market,
            db,
            IAMMEngine.LiquidityLimits(input, units, price, price, deadline, stateHash)
        );
        entries.push(Entry(actor, id, 0));
        adds++;
    }

    function _buy(address actor, uint8 outcome, uint256 shares) internal returns (bool) {
        if (!_trading() || shares == 0) return false;
        try amm.getPositionQuote(market, outcome, int256(shares)) returns (
            uint256, uint256, uint256 net, uint256
        ) {
            uint256 native = DecimalMath.fromWadCeil(net, dec);
            if (cash.balanceOf(actor) < native) return false;
            vm.prank(actor);
            amm.tradePositions(market, outcome, int256(shares), type(uint256).max);
            buys++;
            return true;
        } catch {
            return false;
        }
    }

    function _sell(address actor, uint8 outcome, uint256 shares) internal returns (bool) {
        if (!_trading() || shares == 0) return false;
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        if ((outcome == 1 ? yes : no) < shares) return false;
        try amm.getPositionQuote(market, outcome, -int256(shares)) returns (
            uint256, uint256, uint256 net, uint256
        ) {
            vm.prank(actor);
            amm.tradePositions(market, outcome, -int256(shares), net);
            sells++;
            return true;
        } catch {
            return false;
        }
    }

    function _settleTraders() internal {
        for (uint256 i; i < actors.length; ++i) {
            _settleOne(actors[i]);
        }
    }

    function _settleOne(address actor) internal returns (bool) {
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        if (yes == 0 && no == 0) return false;
        vm.prank(actor);
        amm.settlePosition(market);
        return true;
    }

    function _burnOne(uint256 i) internal {
        uint256 bal = manager.balanceOf(entries[i].owner, entries[i].id);
        if (bal <= 1) return;
        _act(ACT_DUST, i, 1);
        dusts++;
        _redeem(i, 1);
    }

    function _redeemFull(uint256 i) internal {
        uint256 bal = manager.balanceOf(entries[i].owner, entries[i].id);
        if (bal == 0) return;
        _act(ACT_REDEEM, i, bal);
        _redeem(i, bal);
    }

    function _redeem(uint256 i, uint256 amt) internal {
        _observe(winning);
        uint256 fl = _floor(winning);
        uint256 residual = manager.residual(entries[i].id, winning);
        vm.prank(entries[i].owner);
        uint256 wad = amm.redeemLPPosition(market, entries[i].id, amt);
        entries[i].redeemed += wad;
        redeems++;
        assertLe(wad, fl, "redeem exceeded the pre-call floor");
        assertLe(entries[i].redeemed, residual, "credited above residual");
        _observe(winning);
    }

    function _pickLast(uint256 seed) internal view returns (uint256 last) {
        if ((seed >> 3) & 1 == 1) return entries.length - 1;
        uint256 best;
        uint256 n = entries.length;
        for (uint256 i; i < n; ++i) {
            uint256 bal = manager.balanceOf(entries[i].owner, entries[i].id);
            if (bal >= best) {
                best = bal;
                last = i;
            }
        }
    }

    function _recordLastSlack(uint256 last) internal {
        (uint256 sum,) = _residualSum(winning);
        int256 slack = _signedSlack(_floor(winning), sum);
        if (slack < minLastLpSlack) {
            minLastLpSlack = slack;
            lastOutcome = winning;
            lastTrace = trace;
            _copyInto(lastActions);
        }
        assertLt(last, entries.length, "last LP index");
        _observe(winning);
    }

    function _claimFloors() internal {
        uint256 unit = 10 ** (18 - dec);
        bool[8] memory seen;
        for (uint256 i; i < entries.length; ++i) {
            uint256 a = _actorIndex(entries[i].owner);
            if (seen[a]) continue;
            seen[a] = true;
            uint256 ent = amm.floorEntitlementOf(market, entries[i].owner);
            if (DecimalMath.fromWad(ent, dec) == 0) {
                assertLt(ent, unit, "unstaked native dust");
                continue;
            }
            vm.prank(entries[i].owner);
            amm.claimFloor(market);
            assertLt(
                amm.floorEntitlementOf(market, entries[i].owner),
                unit,
                "claim left a native unit behind"
            );
        }
    }

    function _assertClear() internal view {
        for (uint256 i; i < entries.length; ++i) {
            assertEq(
                manager.balanceOf(entries[i].owner, entries[i].id),
                0,
                "LP still holds a receipt"
            );
        }
        _assertSolvent();
        assertGe(minSlack, 0, "negative floor slack");
        assertGe(minSharedSlack, 0, "negative shared floor slack");
        assertGe(minLastLpSlack, 0, "negative last-LP slack");
        assertLt(minSharedSlack, type(int256).max, "shared slack was never measured");
        assertLt(minLastLpSlack, type(int256).max, "last-LP slack was never measured");
    }

    function _observeAll() internal {
        if (!marketSettled) {
            for (uint8 outcome; outcome < 3; ++outcome) {
                _observe(outcome);
            }
            return;
        }
        _observe(winning);
    }

    function _observe(uint8 outcome) internal {
        (uint256 sum, uint256 active) = _residualSum(outcome);
        int256 slack = _signedSlack(_floor(outcome), sum);
        if (slack < 0) {
            emit log_named_int("slack", slack);
            emit log_named_uint("residualSum", sum);
            emit log_named_uint("floor", _floor(outcome));
            emit log_named_uint("outcome", outcome);
            emit log_named_uint("decimals", dec);
            emit log_named_uint("fee", feeBps);
            emit log_named_bytes32("trace", trace);
        }
        if (slack < minSlack) {
            minSlack = slack;
            minOutcome = outcome;
            minTrace = trace;
            _copyInto(minActions);
        }
        if (active >= 2 && slack < minSharedSlack) {
            minSharedSlack = slack;
            sharedOutcome = outcome;
            sharedActive = active;
            sharedTrace = trace;
            _copyInto(sharedActions);
        }
        assertGe(slack, 0, "LP residuals exceed pooled floor");
    }

    function _residualSum(uint8 outcome)
        internal
        view
        returns (uint256 sum, uint256 active)
    {
        uint256 n = entries.length;
        for (uint256 i; i < n; ++i) {
            uint256 residual = manager.residual(entries[i].id, outcome);
            uint256 unpaid = residual;
            if (marketSettled && outcome == winning) {
                uint256 paid = entries[i].redeemed;
                unpaid = residual > paid ? residual - paid : 0;
            }
            if (unpaid > 0) {
                sum += unpaid;
                active++;
            }
        }
    }

    function _floor(uint8 outcome) internal view returns (uint256) {
        (uint256 qYes, uint256 qNo,) = amm.getMarketState(market);
        uint256 seedYes = _word(SLOT_SEED_YES);
        uint256 seedNo = _word(SLOT_SEED_NO);
        uint256 claimableYes = qYes > seedYes ? qYes - seedYes : 0;
        uint256 claimableNo = qNo > seedNo ? qNo - seedNo : 0;
        uint256 liability = outcome == 1
            ? claimableYes
            : outcome == 0 ? claimableNo : (claimableYes + claimableNo) / 2;
        uint256 settled = _word(SLOT_SETTLED);
        uint256 remaining = liability > settled ? liability - settled : 0;
        uint256 collateral = amm.getMarketCollateral(market);
        if (collateral >= remaining) return collateral - remaining;
        return 0;
    }

    function _signedSlack(uint256 fl, uint256 sum) internal pure returns (int256) {
        if (fl >= sum) {
            uint256 delta = fl - sum;
            if (delta > uint256(type(int256).max)) revert("pos slack");
            return int256(delta);
        }
        uint256 short = sum - fl;
        if (short > uint256(type(int256).max)) revert("neg slack");
        return -int256(short);
    }

    function _assertShares() internal view {
        (uint256 qYes, uint256 qNo,) = amm.getMarketState(market);
        uint256 yes;
        uint256 no;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 y, uint256 n) = amm.getPosition(market, actors[i]);
            yes += y;
            no += n;
        }
        uint256 claimableYes = qYes - _word(SLOT_SEED_YES);
        uint256 claimableNo = qNo - _word(SLOT_SEED_NO);
        if (!marketSettled) {
            assertEq(yes, claimableYes, "YES shares left the seed ledger");
            assertEq(no, claimableNo, "NO shares left the seed ledger");
            return;
        }
        uint256 settled = _word(SLOT_SETTLED);
        if (winning == 1) {
            assertEq(yes + settled, claimableYes, "YES settlement ledger");
        } else if (winning == 0) {
            assertEq(no + settled, claimableNo, "NO settlement ledger");
        }
    }

    function _assertSolvent() internal view {
        uint256 native = cash.balanceOf(address(amm));
        uint256 owed = DecimalMath.fromWadCeil(amm.totalLiabilitiesOf(address(cash)), dec);
        assertGe(native, owed, "engine token balance below liabilities");
    }

    function _word(uint256 slot) internal view returns (uint256) {
        return uint256(vm.load(address(amm), keccak256(abi.encode(market, slot))));
    }

    /// @dev `addmod` so a fuzz seed near `type(uint256).max` does not overflow the index.
    function _actorAt(uint256 seed, uint256 salt) internal view returns (address) {
        return actors[addmod(seed, salt, actors.length)];
    }

    function _actorIndex(address owner) internal view returns (uint256) {
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == owner) return i;
        }
        revert("owner");
    }

    function _trading() internal view returns (bool) {
        return market != address(0) && ITruthMarket(market).isTradingOpen();
    }

    function _liquidityOpen() internal view returns (bool) {
        return market != address(0) && ITruthMarket(market).isLiquidityOpen();
    }

    function _act(uint8 kind, uint256 a, uint256 b) internal {
        trace =
            keccak256(abi.encode(trace, kind, a, b, buys, sells, adds, redeems, dusts));
        if (actions.length >= MAX_ACTS) return;
        actions.push(
            (uint256(kind) << 248) | ((a & ((1 << 120) - 1)) << 120)
                | (b & ((1 << 120) - 1))
        );
    }

    function _copyInto(uint256[] storage dest) internal {
        while (dest.length != 0) dest.pop();
        uint256 n = actions.length;
        for (uint256 i; i < n; ++i) {
            dest.push(actions[i]);
        }
    }

    function _writeCsv() internal {
        if (vm.envOr("L2_RECORD_SLACK", uint256(0)) == 0) return;
        string memory line = string.concat(_csvIdentity(), _csvSlack(), _csvCounts());
        vm.writeLine("/tmp/l2-floor-slack.csv", line);
    }

    function _csvIdentity() internal view returns (string memory) {
        return string.concat(
            vm.toString(campaignKind),
            ",",
            vm.toString(dec),
            ",",
            vm.toString(feeBps),
            ",",
            vm.toString(campaignSeed),
            ",",
            vm.toString(notedSteps),
            ",",
            vm.toString(winning),
            ","
        );
    }

    function _csvSlack() internal view returns (string memory) {
        return string.concat(
            vm.toString(bootstrapSlack),
            ",",
            vm.toString(minSlack),
            ",",
            vm.toString(minTrace),
            ",",
            vm.toString(minSharedSlack),
            ",",
            vm.toString(sharedOutcome),
            ",",
            vm.toString(sharedActive),
            ",",
            vm.toString(sharedTrace),
            ","
        );
    }

    function _csvCounts() internal view returns (string memory) {
        return string.concat(
            vm.toString(minLastLpSlack),
            ",",
            vm.toString(lastOutcome),
            ",",
            vm.toString(lastTrace),
            ",",
            vm.toString(buys),
            ",",
            vm.toString(sells),
            ",",
            vm.toString(adds),
            ",",
            vm.toString(redeems),
            ",",
            vm.toString(dusts),
            ",",
            _join(sharedActions),
            ",",
            _join(lastActions)
        );
    }

    function _join(uint256[] storage xs) internal view returns (string memory out) {
        uint256 n = xs.length;
        if (n > 16) n = 16;
        out = "";
        for (uint256 i; i < n; ++i) {
            out = string.concat(out, vm.toString(xs[i]));
            if (i + 1 < n) out = string.concat(out, "-");
        }
    }
}

/// @notice Fixed campaigns at 0, 6 and 18 decimals and at fees 0 and 1.
contract L2LastLpFloorExitTest is Test {
    int256 internal worstShared = type(int256).max;
    int256 internal worstLast = type(int256).max;
    bytes32 internal worstSharedTrace;
    bytes32 internal worstLastTrace;
    uint256 internal worstSharedKey;
    uint256 internal worstLastKey;

    function test_concrete_exit_matrix() public {
        uint8[3] memory decs = [uint8(0), 6, 18];
        uint16[2] memory fees = [uint16(0), 1];
        for (uint256 d; d < decs.length; ++d) {
            for (uint256 f; f < fees.length; ++f) {
                for (uint8 outcome; outcome < 3; ++outcome) {
                    _runCase(decs[d], fees[f], outcome, d, f);
                }
            }
        }
        emit log_named_int("concreteMinShared", worstShared);
        emit log_named_uint("concreteSharedKey", worstSharedKey);
        emit log_named_bytes32("concreteSharedTrace", worstSharedTrace);
        emit log_named_int("concreteMinLast", worstLast);
        emit log_named_uint("concreteLastKey", worstLastKey);
        emit log_named_bytes32("concreteLastTrace", worstLastTrace);
    }

    function _runCase(uint8 precision, uint16 fee, uint8 outcome, uint256 d, uint256 f)
        internal
    {
        uint256 seed = uint256(outcome) | (d << 8) | (f << 16) | (1 << 2);
        LpFloorHandler handler = new LpFloorHandler(precision, fee);
        handler.setUp();
        handler.label(0, 0);
        handler.exitAdversarial(outcome, seed);
        int256 shared = handler.minSharedSlack();
        int256 lastSlack = handler.minLastLpSlack();
        if (shared < worstShared) {
            worstShared = shared;
            worstSharedTrace = handler.sharedTrace();
            worstSharedKey = seed;
        }
        if (lastSlack < worstLast) {
            worstLast = lastSlack;
            worstLastTrace = handler.lastTrace();
            worstLastKey = seed;
        }
        assertGe(handler.bootstrapSlack(), 0, "bootstrap");
        assertGe(shared, 0, "shared slack");
        assertGe(lastSlack, 0, "last slack");
        assertGt(handler.redeems(), 0, "nobody redeemed");
        assertGt(handler.dusts(), 0, "no 1-wei burn");
        emit log_named_uint("decimals", precision);
        emit log_named_uint("fee", fee);
        emit log_named_uint("outcome", outcome);
        emit log_named_int("bootstrap", handler.bootstrapSlack());
        emit log_named_int("shared", shared);
        emit log_named_int("last", lastSlack);
        emit log_named_uint("dusts", handler.dusts());
        emit log_named_bytes32("sharedTrace", handler.sharedTrace());
        emit log_named_bytes32("lastTrace", handler.lastTrace());
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: l2heavy.fuzz.runs = 10000
    function testFuzz_campaignThenFullExit(uint256 seed, uint8 steps) public {
        uint256 bucket = seed % 6;
        uint8 precision = bucket < 2 ? 0 : bucket < 4 ? 6 : 18;
        uint16 fee = bucket % 2 == 0 ? 0 : 1;
        LpFloorHandler handler = new LpFloorHandler(precision, fee);
        handler.setUp();
        uint256 n = bound(uint256(steps), 12, 40);
        uint256 settleAt = seed % 5 == 0 ? n / 2 : n + 1;
        for (uint256 i; i < n; ++i) {
            if (i == settleAt) handler.settleMarket(uint8(seed % 3));
            uint256 roll = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = roll % 6;
            if (op == 0) handler.addLiquidity(roll, roll >> 8);
            else if (op == 1) handler.buy(roll, roll >> 3, roll >> 8);
            else if (op == 2) handler.sell(roll, roll >> 3, roll >> 8);
            else if (op == 3) handler.partialRedeem(roll, roll >> 8);
            else if (op == 4) handler.dustBurn(roll);
            else handler.settleTrader(roll);
        }
        handler.label(n, 1);
        handler.exitAdversarial(uint8(seed % 3), seed);
        assertGe(handler.minSharedSlack(), 0, "negative shared floor slack");
        assertGe(handler.minLastLpSlack(), 0, "negative last-LP slack");
        assertGt(handler.dusts(), 0, "adversarial exit burned no dust");
    }

    /// @dev The fuzzer shrunk an overflow to this input. `seed + round` must not wrap.
    function test_regression_max_seed_exit() public {
        testFuzz_campaignThenFullExit(type(uint256).max - 1, 17);
    }
}

abstract contract L2FloorInvariant is Test {
    LpFloorHandler internal handler;

    function precision() internal pure virtual returns (uint8);

    function fee() internal pure virtual returns (uint16);

    function setUp() public {
        handler = new LpFloorHandler(precision(), fee());
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.addLiquidity.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.sell.selector;
        selectors[3] = handler.settleTrader.selector;
        selectors[4] = handler.partialRedeem.selector;
        selectors[5] = handler.dustBurn.selector;
        selectors[6] = handler.settleMarket.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev `afterInvariant` runs once per suite. Each run is exited here, at the
    ///      light depth and again at the heavy depth, then restored so the campaign
    ///      continues. A reverting exit fails this invariant and shrinks.
    function invariant_residualsFitFloor() public {
        handler.assertFits();
        uint256 c = handler.calls();
        if (c == 20 || c == 50) _exitAndRestore(c);
    }

    function afterInvariant() public {
        if (!handler.cleared()) {
            handler.label(handler.calls(), 2);
            handler.exitAdversarial(
                uint8(handler.buys() % 3), uint256(keccak256(abi.encode(handler.trace())))
            );
        }
        assertGe(handler.minSharedSlack(), 0, "negative shared floor slack");
        assertGe(handler.minLastLpSlack(), 0, "negative last-LP slack");
    }

    function _exitAndRestore(uint256 c) internal {
        uint256 snap = vm.snapshotState();
        handler.label(c, 2);
        handler.exitAdversarial(
            uint8(c % 3), uint256(keccak256(abi.encode(handler.trace(), c)))
        );
        assertGe(handler.minSharedSlack(), 0, "negative shared floor slack");
        assertGe(handler.minLastLpSlack(), 0, "negative last-LP slack");
        assertTrue(vm.revertToState(snap), "restore campaign");
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 20
/// forge-config: l2heavy.invariant.fail-on-revert = true
/// forge-config: l2heavy.invariant.runs = 1000
/// forge-config: l2heavy.invariant.depth = 50
contract L2FloorInvariant0 is L2FloorInvariant {
    function precision() internal pure override returns (uint8) {
        return 0;
    }

    function fee() internal pure override returns (uint16) {
        return 0;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 20
/// forge-config: l2heavy.invariant.fail-on-revert = true
/// forge-config: l2heavy.invariant.runs = 1000
/// forge-config: l2heavy.invariant.depth = 50
contract L2FloorInvariant6 is L2FloorInvariant {
    function precision() internal pure override returns (uint8) {
        return 6;
    }

    function fee() internal pure override returns (uint16) {
        return 1;
    }
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 20
/// forge-config: l2heavy.invariant.fail-on-revert = true
/// forge-config: l2heavy.invariant.runs = 1000
/// forge-config: l2heavy.invariant.depth = 50
contract L2FloorInvariant18 is L2FloorInvariant {
    function precision() internal pure override returns (uint8) {
        return 18;
    }

    function fee() internal pure override returns (uint16) {
        return 1;
    }
}

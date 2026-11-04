// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {
    DualTokenBase,
    IAmmFeeVault,
    IBookFeeVault,
    IMarketFactory
} from "../base/DualTokenBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

contract CampaignToken is ERC20 {
    uint8 private immutable precision;
    address public blockedRecipient;

    function blockRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blockedRecipient, "recipient blocked");
        return super.transfer(to, amount);
    }

    constructor(uint8 decimals_) ERC20("Local campaign token", "LOCAL") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Four simultaneously funded markets, two sharing each Token A. All funding
/// is minted to actors then transferred through production entrypoints. No deals,
/// storage writes, top-ups, RPC, forks or FFI. Preconditions skip unavailable ops;
/// unexpected execution reverts are never caught. The campaign explicitly enables
/// fail_on_revert so an unexpected handler failure cannot disappear from coverage.
contract MultiMarketHandler is DualTokenBase {
    CampaignToken[3] public tokens;
    address[4] public markets;
    address[3] public actors = [address(0xAA01), address(0xAA02), address(0xAA03)];
    uint256[4] public resolvedAt;
    bool[4] public attempted;
    bool[4] public terminal;
    uint8[4] public finalOutcome;
    ITruthMarket.SettlementKind[4] public finalKind;
    uint64[4] public resting;
    // One covered offer per actor and outcome; IDs remain observable after expiry.
    uint64[6][4] public inventoryOrders;
    // Every entry receipt per market, position zero first.
    uint256[][4] internal receipts;
    // Once any entry of a market is burned its residual is partially paid out and
    // the aggregate LP promise is no longer directly observable.
    bool[4] public burnedAny;
    LPPositionManager internal manager;
    // buys, sells, fills, rests, cancels, time, resolve, veto,
    // adjudicated NO/YES/INVALID, timeout INVALID, burns, claims,
    // liquidity adds, entry burns.
    uint256[16] public successes;
    uint256[7] public claimSuccess;
    // split, merge, covered quote, inventory take, covered cancel, expiry, cleanup.
    uint256[7] public bookSuccess;
    uint256 public skipped;
    uint256 public deferralCount;
    uint256 public deferredClaimCount;
    uint8 private immutable bookDecimals;

    constructor(uint8 decimals_) {
        bookDecimals = decimals_;
    }

    function setUp() public override {
        tokens[0] = new CampaignToken(6);
        tokens[1] = new CampaignToken(18);
        tokens[2] = new CampaignToken(bookDecimals);
        _deployStack(address(tokens[2]));
        for (uint256 t; t < 3; ++t) {
            tokens[t].mint(creator, 1_000_000 * 10 ** tokens[t].decimals());
            vm.prank(creator);
            tokens[t].approve(address(marketFactory), type(uint256).max);
            for (uint256 a; a < 3; ++a) {
                tokens[t].mint(actors[a], 100_000_000 * 10 ** tokens[t].decimals());
                vm.startPrank(actors[a]);
                tokens[t].approve(address(amm), type(uint256).max);
                tokens[t].approve(address(orderEngine), type(uint256).max);
                vm.stopPrank();
            }
        }
        adjudicator.approveGuardian(address(this));
        for (uint256 i; i < 4; ++i) {
            uint64 dl = uint64(block.timestamp + (2 + i) * 1 days);
            IMarketFactory.MarketParams memory params = _marketParams(
                string(abi.encodePacked("Local solvency ", bytes1(uint8(i)))),
                uint64(block.timestamp + 1 hours),
                dl,
                address(tokens[i / 2]),
                1000e18,
                0.5e18
            );
            vm.prank(creator);
            (markets[i],) = marketFactory.createMarket(params);
            receipts[i].push(marketFactory.getLPToken(markets[i]));
        }
        manager = LPPositionManager(amm.positionManager());
        checkAll(); // pre-start liquidity/trading distinction
        for (uint256 i; i < 4; ++i) {
            addLiquidity(i, i, 5e18); // pre-start public entry
        }
        vm.warp(block.timestamp + 1 hours);
        // Non-vacuous baseline with real exposure in every market, both outcomes,
        // immediate sale payouts, book backing and cancellable resting deposits.
        for (uint256 i; i < 4; ++i) {
            buy(i, 0, 20e18, true);
            buy(i, 1, 20e18, false);
            sell(i, 0, 5e18, true);
            fill(i, 10e18);
            place(i);
            deferCancel(i);
            if (i == 0) claimDeferred();
            place(i);
            addLiquidity(i, i + 1, 3e18); // mid-trading entry at skewed odds
            splitInventory(i, 2, 10e18 + 3 * orderEngine.shareUnit());
            quoteInventory(i, 2, 1, 4e18);
            quoteInventory(i, 2, 0, 4e18);
            takeInventory(i, 0, 1, 1e18);
            cancelInventory(i, 2, 1);
            mergeInventory(i, 2, 1e18);
            expireInventory(i, 2, 0);
            cleanupInventory(i);
            // Keep both reserved and available inventory through terminal claims.
            quoteInventory(i, 2, 1, 3e18 + orderEngine.shareUnit());
            quoteInventory(i, 2, 0, 3e18);
        }
        // A real proposal/veto seeds sticky-resolution coverage without ending
        // trading. The other markets retain permissionless liquidity growth.
        resolve(0, 1);
        veto(0);
    }

    function receiptCount(uint256 m) external view returns (uint256) {
        return receipts[m % 4].length;
    }

    function bookInvalidRemainder(uint256 m, uint256 a) external view returns (uint8) {
        return orderEngine.invalidRemainderOf(markets[m % 4], actors[a % 3]);
    }

    /// @dev Public separate-entry add with exact funding, receipt, odds and state bounds.
    function addLiquidity(uint256 m, uint256 a, uint256 db) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isLiquidityOpen()) {
            ++skipped;
            return;
        }
        db = bound(db, 1e17, 50e18);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(markets[m], db);
        uint256 units = limits.minLpOut;
        vm.prank(actors[a % 3]);
        (uint256 receipt, uint256 deposit) = amm.increaseLiquidity(markets[m], db, limits);
        assertEq(deposit, units, "exact receipt");
        assertEq(manager.balanceOf(actors[a % 3], receipt), units);
        receipts[m].push(receipt);
        ++successes[14];
    }

    /// @dev Burn part of an actor-owned entry after settlement.
    function burnEntry(uint256 m, uint256 idx, uint256 a) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isSettled() || receipts[m].length < 2) {
            ++skipped;
            return;
        }
        uint256 receipt = receipts[m][1 + idx % (receipts[m].length - 1)];
        address actor = actors[a % 3];
        uint256 balance = manager.balanceOf(actor, receipt);
        if (balance == 0) {
            ++skipped;
            return;
        }
        uint256 beforeBook = tokens[2].balanceOf(actor);
        vm.prank(actor);
        amm.redeemLPPosition(
            markets[m], receipt, balance / 2 == 0 ? balance : balance / 2
        );
        assertEq(tokens[2].balanceOf(actor), beforeBook, "entry burn cannot pay USDG");
        burnedAny[m] = true;
        ++successes[15];
    }

    modifier checked() {
        _;
        checkAll();
    }

    function buy(uint256 m, uint256 a, uint256 amount, bool yes) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isTradingOpen()) {
            ++skipped;
            return;
        }
        // Small relative to bootstrap b; bounded depth cannot exhaust actor funds.
        amount = bound(amount, 1e15, 20e18);
        vm.prank(actors[a % 3]);
        amm.tradePositions(markets[m], yes ? 1 : 0, int256(amount), type(uint256).max);
        ++successes[0];
    }

    function sell(uint256 m, uint256 a, uint256 amount, bool yes) public checked {
        m %= 4;
        address actor = actors[a % 3];
        (uint256 y, uint256 n) = amm.getPosition(markets[m], actor);
        uint256 held = yes ? y : n;
        if (!TruthMarket(markets[m]).isTradingOpen() || held < 1e15) {
            ++skipped;
            return;
        }
        amount = bound(amount, 1e15, held);
        IERC20 token = IERC20(amm.tokenAOf(markets[m]));
        uint256 before = token.balanceOf(actor);
        vm.prank(actor);
        uint256 proceeds = amm.tradePositions(markets[m], yes ? 1 : 0, -int256(amount), 0);
        assertEq(
            token.balanceOf(actor) - before,
            proceeds / 10 ** (18 - amm.tokenADecimalsOf(markets[m])),
            "every successful sell pays immediately"
        );
        ++successes[1];
    }

    function fill(uint256 m, uint256 amount) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isTradingOpen()) {
            ++skipped;
            return;
        }
        uint256 unit = orderEngine.shareUnit();
        amount = bound(amount, 1e18, 20e18) / unit * unit;
        (, uint256 beforeNo) = orderEngine.getPosition(markets[m], actors[1]);
        vm.prank(actors[1]);
        orderEngine.placeOrder(
            markets[m], BookTestOrders.buy(0, 500, uint128(amount), 256)
        );
        vm.prank(actors[0]);
        orderEngine.placeOrder(markets[m], BookTestOrders.buy(1, 500, uint128(amount), 1));
        (, uint256 afterNo) = orderEngine.getPosition(markets[m], actors[1]);
        assertEq(afterNo - beforeNo, amount, "fill must execute fully");
        ++successes[2];
    }

    function place(uint256 m) public checked {
        m %= 4;
        if (
            !TruthMarket(markets[m]).isTradingOpen()
                || orderEngine.getOrder(resting[m]).amount != 0
        ) {
            ++skipped;
            return;
        }
        vm.prank(actors[2]);
        IOrderEngine.OrderResult memory result =
            orderEngine.placeOrder(markets[m], BookTestOrders.buy(0, 100, 10e18, 256));
        resting[m] = result.orderId;
        assertGt(resting[m], 0, "cash quote rests");
        ++successes[3];
    }

    function cancel(uint256 m) public checked {
        m %= 4;
        if (orderEngine.getOrder(resting[m]).amount == 0) {
            ++skipped;
            return;
        }
        uint256 beforeBalance = tokens[2].balanceOf(actors[2]);
        vm.prank(actors[2]);
        // `place` bought NO at 100: on the single YES axis (ADR-0008) that rests as
        // an ASK (side 1) at YES tick 900.
        orderEngine.cancelById(resting[m]);
        assertGt(tokens[2].balanceOf(actors[2]), beforeBalance);
        resting[m] = 0;
        ++successes[4];
    }

    /// @dev Exercise a real refused transfer, leaving backing in other markets live.
    function deferCancel(uint256 m) public checked {
        m %= 4;
        if (orderEngine.getOrder(resting[m]).amount == 0) {
            ++skipped;
            return;
        }
        uint256 beforeCredit = orderEngine.deferredOf(actors[2]);
        uint256 beforeCash = tokens[2].balanceOf(actors[2]);
        tokens[2].blockRecipient(actors[2]);
        vm.prank(actors[2]);
        orderEngine.cancelById(resting[m]);
        tokens[2].blockRecipient(address(0));
        resting[m] = 0;
        assertEq(tokens[2].balanceOf(actors[2]), beforeCash);
        assertGt(orderEngine.deferredOf(actors[2]), beforeCredit);
        ++deferralCount;
    }

    function claimDeferred() public checked {
        uint256 credit = orderEngine.deferredOf(actors[2]);
        if (credit == 0) {
            ++skipped;
            return;
        }
        uint256 beforeCash = tokens[2].balanceOf(actors[2]);
        vm.prank(actors[2]);
        assertEq(orderEngine.claimDeferred(), credit);
        assertEq(tokens[2].balanceOf(actors[2]) - beforeCash, credit);
        ++deferredClaimCount;
    }

    function splitInventory(uint256 m, uint256 a, uint256 amount) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isTradingOpen()) {
            ++skipped;
            return;
        }
        uint256 unit = orderEngine.shareUnit();
        amount = bound(amount, unit, 20e18) / unit * unit;
        vm.prank(actors[a % 3]);
        assertEq(
            orderEngine.split(
                markets[m], amount, amount / unit, uint64(block.timestamp + 1 hours)
            ),
            amount / unit,
            "split exact complete-set funding"
        );
        ++bookSuccess[0];
    }

    function mergeInventory(uint256 m, uint256 a, uint256 amount) public checked {
        m %= 4;
        address actor = actors[a % 3];
        (uint256 y, uint256 n, uint256 yr, uint256 nr,) =
            orderEngine.getInventory(markets[m], actor);
        uint256 available = y - yr < n - nr ? y - yr : n - nr;
        if (available == 0) {
            ++skipped;
            return;
        }
        uint256 unit = orderEngine.shareUnit();
        amount = bound(amount, unit, available) / unit * unit;
        vm.prank(actor);
        assertEq(
            orderEngine.merge(
                markets[m], amount, amount / unit, uint64(block.timestamp + 1 hours)
            ),
            amount / unit,
            "merge exact complete-set proceeds"
        );
        ++bookSuccess[1];
    }

    function quoteInventory(uint256 m, uint256 a, uint256 outcome, uint256 amount)
        public
        checked
    {
        m %= 4;
        a %= 3;
        outcome %= 2;
        uint256 slot = a * 2 + outcome;
        if (
            !TruthMarket(markets[m]).isTradingOpen()
                || orderEngine.getOrder(inventoryOrders[m][slot]).amount != 0
        ) {
            ++skipped;
            return;
        }
        uint256 available = _availableInventory(m, a, outcome);
        uint256 minimum = orderEngine.getMinRestingOrder(700);
        if (available < minimum) {
            ++skipped;
            return;
        }
        uint256 unit = orderEngine.shareUnit();
        amount =
            bound(amount, minimum, available < 20e18 ? available : 20e18) / unit * unit;
        IOrderEngine.OrderParams memory p =
            BookTestOrders.sell(uint8(outcome), 700, uint128(amount), 256);
        p.postOnly = true;
        {
            uint256 expiry = block.timestamp + 1 hours;
            uint256 deadline = TruthMarket(markets[m]).deadline();
            p.expiry = uint64(expiry < deadline ? expiry : deadline);
        }
        uint256 beforeCash = tokens[2].balanceOf(actors[a]);
        vm.prank(actors[a]);
        IOrderEngine.OrderResult memory result = orderEngine.placeOrder(markets[m], p);
        inventoryOrders[m][slot] = result.orderId;
        assertGt(result.orderId, 0, "covered quote rests");
        assertEq(result.tokenIn, 0, "covered quote needs no additional cash");
        assertEq(tokens[2].balanceOf(actors[a]), beforeCash, "inventory-only quote");
        ++bookSuccess[2];
    }

    function _availableInventory(uint256 m, uint256 a, uint256 outcome)
        internal
        view
        returns (uint256)
    {
        (uint256 y, uint256 n, uint256 yr, uint256 nr,) =
            orderEngine.getInventory(markets[m], actors[a]);
        return outcome == 1 ? y - yr : n - nr;
    }

    function takeInventory(uint256 m, uint256 a, uint256 outcome, uint256 amount)
        public
        checked
    {
        m %= 4;
        a %= 3;
        outcome %= 2;
        if (!TruthMarket(markets[m]).isTradingOpen()) {
            ++skipped;
            return;
        }
        // Choose the first executable offer and a distinct taker. This bounds the
        // fill to one maker even after extensive cancel/requote tombstone churn.
        uint64 first;
        for (uint256 maker; maker < 3; ++maker) {
            uint64 id = inventoryOrders[m][maker * 2 + outcome];
            IOrderEngine.OrderView memory candidate = orderEngine.getOrder(id);
            if (
                candidate.amount > 0 && candidate.expiry > block.timestamp
                    && (first == 0 || id < first)
            ) first = id;
        }
        if (first == 0) {
            ++skipped;
            return;
        }
        IOrderEngine.OrderView memory offer = orderEngine.getOrder(first);
        if (offer.maker == actors[a]) a = (a + 1) % 3;
        orderEngine.advanceHead(
            markets[m], outcome == 1 ? 1 : 0, outcome == 1 ? 700 : 300, 1024
        );
        uint256 unit = orderEngine.shareUnit();
        amount = bound(amount, unit, offer.amount) / unit * unit;
        IOrderEngine.OrderParams memory p =
            BookTestOrders.buy(uint8(outcome), 700, uint128(amount), 256);
        p.rest = false;
        p.maxTokenIn = amount / unit + 2;
        vm.prank(actors[a]);
        IOrderEngine.OrderResult memory result = orderEngine.placeOrder(markets[m], p);
        assertEq(result.filled, amount, "covered inventory transfer fills fully");
        assertEq(result.orderId, 0, "IOC does not add a cash order");
        ++bookSuccess[3];
    }

    function cancelInventory(uint256 m, uint256 a, uint256 outcome) public checked {
        m %= 4;
        a %= 3;
        uint256 slot = a * 2 + outcome % 2;
        uint64 id = inventoryOrders[m][slot];
        if (orderEngine.getOrder(id).amount == 0) {
            ++skipped;
            return;
        }
        uint256 beforeCash = tokens[2].balanceOf(actors[a]);
        vm.prank(actors[a]);
        orderEngine.cancelById(id);
        inventoryOrders[m][slot] = 0;
        assertEq(
            tokens[2].balanceOf(actors[a]), beforeCash, "covered cancel releases shares"
        );
        ++bookSuccess[4];
    }

    function expireInventory(uint256 m, uint256 a, uint256 outcome) public checked {
        m %= 4;
        IOrderEngine.OrderView memory order =
            orderEngine.getOrder(inventoryOrders[m][(a % 3) * 2 + outcome % 2]);
        if (order.amount == 0 || order.expiry <= block.timestamp) {
            ++skipped;
            return;
        }
        vm.warp(order.expiry);
        ++successes[5];
        ++bookSuccess[5];
    }

    function cleanupInventory(uint256 m) public checked {
        m %= 4;
        uint256 beforeReserved;
        for (uint256 slot; slot < 6; ++slot) {
            beforeReserved += orderEngine.getOrder(inventoryOrders[m][slot]).amount;
        }
        orderEngine.advanceHead(markets[m], 1, 700, 1024);
        orderEngine.advanceHead(markets[m], 0, 300, 1024);
        uint256 afterReserved;
        for (uint256 slot; slot < 6; ++slot) {
            afterReserved += orderEngine.getOrder(inventoryOrders[m][slot]).amount;
        }
        if (afterReserved < beforeReserved) ++bookSuccess[6];
        else ++skipped;
    }

    function advance(uint256 seconds_) public checked {
        vm.warp(block.timestamp + bound(seconds_, 1, 6 hours));
        ++successes[5];
    }

    function resolve(uint256 m, uint256 outcome) public checked {
        m %= 4;
        TruthMarket tm = TruthMarket(markets[m]);
        if (
            tm.state() != TruthMarket.MarketState.LIVE || block.timestamp < tm.startTime()
                || adjudicator.resolutionLocked(markets[m])
                || block.timestamp + adjudicator.vetoPeriod()
                    >= uint256(tm.deadline()) + tm.invalidationBuffer()
        ) {
            ++skipped;
            return;
        }
        vm.prank(resolver);
        adjudicator.resolve(markets[m], uint8(outcome % 3), keccak256("local evidence"));
        resolvedAt[m] = block.timestamp;
        attempted[m] = true;
        ++successes[6];
    }

    function veto(uint256 m) public checked {
        m %= 4;
        if (
            TruthMarket(markets[m]).state() != TruthMarket.MarketState.RESOLVING
                || block.timestamp >= resolvedAt[m] + 1 hours
        ) {
            ++skipped;
            return;
        }
        if (
            adjudicator.guardianVetoCount(markets[m], address(this))
                >= adjudicator.GUARDIAN_VETO_CAP()
        ) {
            ++skipped;
            return;
        }
        adjudicator.dispute(markets[m]);
        ++successes[7];
    }

    function finish(uint256 m) public checked {
        m %= 4;
        TruthMarket tm = TruthMarket(markets[m]);
        if (tm.isSettled()) {
            ++skipped;
            return;
        }
        if (block.timestamp >= uint256(tm.deadline()) + tm.invalidationBuffer()) {
            tm.invalidate();
            ++successes[11];
        } else if (adjudicator.canSettle(markets[m])) {
            adjudicator.settle(markets[m]);
            ++successes[8 + tm.winningOutcome()];
        } else {
            ++skipped;
            return;
        }
        terminal[m] = true;
        finalOutcome[m] = tm.winningOutcome();
        finalKind[m] = tm.settlementKind();
    }

    function burn(uint256 m, uint256 fraction) public checked {
        m %= 4;
        if (!TruthMarket(markets[m]).isSettled()) {
            ++skipped;
            return;
        }
        uint256 bootstrapId = marketFactory.getLPToken(markets[m]);
        uint256 balance = manager.balanceOf(creator, bootstrapId);
        if (balance == 0) {
            ++skipped;
            return;
        }
        uint256 amount = balance / bound(fraction, 1, 4);
        if (amount == 0) amount = balance;
        uint256 beforeBook = tokens[2].balanceOf(creator);
        vm.prank(creator);
        amm.redeemLP(markets[m], amount);
        assertEq(tokens[2].balanceOf(creator), beforeBook, "LP burn cannot pay USDG");
        burnedAny[m] = true;
        ++successes[12];
    }

    /// @dev Claim classes are independently selected, not bundled with settlement
    /// or burns. Positions, floor and dividends therefore remain outstanding
    /// while other markets and custodians mutate.
    function claim(uint256 m, uint256 a, uint256 kind) public checked {
        m %= 4;
        address mk = markets[m];
        address actor = actors[a % 3];
        kind %= 7;
        if (kind == 0 || kind == 1) {
            if (!TruthMarket(mk).isSettled()) {
                ++skipped;
                return;
            }
            uint256 y;
            uint256 n;
            if (kind == 0) {
                (y, n) = amm.getPosition(mk, actor);
            } else {
                uint256 yr;
                uint256 nr;
                (y, n, yr, nr,) = orderEngine.getInventory(mk, actor);
                y -= yr;
                n -= nr;
            }
            if (y + n == 0) {
                ++skipped;
                return;
            }
            vm.prank(actor);
            if (kind == 0) amm.settlePosition(mk);
            else orderEngine.settlePosition(mk);
        } else if (kind == 2) {
            if (
                amm.floorEntitlementOf(mk, creator)
                    < 10 ** (18 - amm.tokenADecimalsOf(mk))
            ) {
                ++skipped;
                return;
            }
            vm.prank(creator);
            amm.claimFloor(mk);
        } else if (kind == 3) {
            if (
                !TruthMarket(mk).isSettled()
                    || vault.lpEntitlementOf(mk, creator, address(tokens[m / 2])) == 0
            ) {
                ++skipped;
                return;
            }
            uint256 beforeBook = tokens[2].balanceOf(creator);
            vm.prank(creator);
            vault.claimLPDividend(mk);
            assertEq(
                tokens[2].balanceOf(creator), beforeBook, "LP dividend cannot pay USDG"
            );
        } else if (kind == 6) {
            if (
                !TruthMarket(mk).isSettled()
                    || TruthMarket(mk).settlementKind()
                        != ITruthMarket.SettlementKind.INVALIDATED
                    || bookVault.refundableResolutionOf(mk, actor) == 0
            ) {
                ++skipped;
                return;
            }
            bookVault.claimTimeoutRefund(mk, actor);
        } else {
            bool bookFee = a % 2 != 0;
            address token = address(tokens[bookFee ? 2 : m / 2]);
            uint256 available = bookFee
                ? bookVault.accountOf(
                    mk,
                    kind == 4
                        ? IBookFeeVault.Bucket.PROTOCOL
                        : IBookFeeVault.Bucket.RESOLUTION,
                    token
                )
                : vault.accountOf(
                    mk,
                    kind == 4
                        ? IAmmFeeVault.Bucket.OPERATOR
                        : IAmmFeeVault.Bucket.RESOLUTION,
                    token
                );
            if (available == 0) {
                ++skipped;
                return;
            }
            if (kind == 4) {
                if (bookFee) bookVault.claimProtocolFees(mk);
                else vault.claimOperatorFees(mk);
            } else {
                if (
                    !TruthMarket(mk).isSettled()
                        || TruthMarket(mk).settlementKind()
                            == ITruthMarket.SettlementKind.INVALIDATED
                ) {
                    ++skipped;
                    return;
                }
                if (bookFee) bookVault.claimResolutionFees(mk);
                else vault.claimResolutionFees(mk);
            }
        }
        ++claimSuccess[kind];
        ++successes[13];
    }

    function checkAll() public view {
        uint256 credits;
        for (uint256 a; a < 3; ++a) {
            credits += orderEngine.deferredOf(actors[a]);
        }
        assertEq(orderEngine.totalDeferred(), credits, "deferred aggregate reconciles");
        uint256[3] memory ammSum;
        uint256[3] memory vaultSum;
        uint256 bookVaultSum;
        uint256 backing;
        for (uint256 i; i < 4; ++i) {
            address mk = markets[i];
            if (mk == address(0)) continue;
            TruthMarket tm = TruthMarket(mk);
            assertEq(
                tm.resolutionAttempted(), attempted[i], "marker tracks the open proposal"
            );
            assertEq(tm.isSettled(), terminal[i], "terminal monotonicity");
            if (terminal[i]) {
                assertEq(tm.winningOutcome(), finalOutcome[i]);
                assertEq(uint8(tm.settlementKind()), uint8(finalKind[i]));
            }
            if (adjudicator.resolutionLocked(mk)) {
                if (tm.isSettled()) {
                    assertEq(tm.winningOutcome(), 2);
                    assertEq(
                        uint8(tm.settlementKind()),
                        uint8(ITruthMarket.SettlementKind.INVALIDATED)
                    );
                } else {
                    assertEq(
                        uint8(tm.settlementKind()),
                        uint8(ITruthMarket.SettlementKind.UNSET)
                    );
                }
            }
            bool live = tm.state() == TruthMarket.MarketState.LIVE;
            assertEq(
                tm.isTradingOpen(),
                live && !attempted[i] && block.timestamp >= tm.startTime()
                    && block.timestamp < tm.deadline()
            );
            assertEq(
                tm.isLiquidityOpen(),
                live && !attempted[i] && block.timestamp < tm.deadline()
            );
            assertTrue(orderEngine.isMarketRegistered(mk));
            assertEq(vault.configOf(mk).capitalBps, 5000, "pinned fixture growth policy");
            assertEq(amm.tokenAOf(mk), address(tokens[i / 2]));
            ammSum[i / 2] += amm.getMarketCollateral(mk) + amm.claimableFloorLiability(mk);
            backing += orderEngine.getCollateralBacking(mk); // native book units
            _checkBookInventory(i);
            for (uint256 t; t < 3; ++t) {
                vaultSum[t] += vault.marketLiabilitiesOf(mk, address(tokens[t]));
            }
            bookVaultSum += bookVault.marketLiabilitiesOf(mk, address(tokens[2]));
            assertEq(vault.accountOf(mk, IAmmFeeVault.Bucket.LP, address(tokens[2])), 0);
            assertEq(vault.lpEntitlementOf(mk, creator, address(tokens[2])), 0);
            _checkPositionPromises(i);
        }
        for (uint256 t; t < 3; ++t) {
            assertEq(
                amm.totalLiabilitiesOf(address(tokens[t])),
                ammSum[t],
                "AMM aggregate is market sum"
            );
            uint256 scale = 10 ** (18 - tokens[t].decimals());
            assertGe(
                tokens[t].balanceOf(address(amm)),
                (ammSum[t] + scale - 1) / scale,
                "native AMM custody covers ceil WAD"
            );
            assertEq(
                vault.totalLiabilitiesOf(address(tokens[t])),
                vaultSum[t],
                "vault aggregate is market sum"
            );
            assertGe(
                tokens[t].balanceOf(address(vault)), vaultSum[t], "native vault custody"
            );
        }
        assertEq(
            bookVault.totalLiabilitiesOf(address(tokens[2])),
            bookVaultSum,
            "book vault aggregate is market sum"
        );
        assertGe(
            tokens[2].balanceOf(address(bookVault)),
            bookVaultSum,
            "book vault custody covers its own liabilities"
        );
        assertEq(
            tokens[2].balanceOf(address(orderEngine)),
            backing + orderEngine.totalDeferred(),
            "summed book backing plus deferred claims"
        );
    }

    /// @dev Every owner and outstanding order is enumerated independently. Gross
    /// reserves still belong to the maker after expiry/settlement until cleanup.
    /// INVALID obligations are counted in half-native units, including prior carry.
    function _checkBookInventory(uint256 m) internal view {
        address mk = markets[m];
        uint256 unit = orderEngine.shareUnit();
        uint256[4] memory sums; // YES, NO, cash reservation, INVALID carry
        for (uint256 a; a < 3; ++a) {
            (uint256 y, uint256 n, uint256 yr, uint256 nr, uint256 cash) =
                orderEngine.getInventory(mk, actors[a]);
            assertLe(yr, y, "YES reservation is owned");
            assertLe(nr, n, "NO reservation is owned");
            assertEq(orderEngine.getNet(mk, actors[a]), int256(y) - int256(n));
            assertEq(y % unit, 0, "YES native alignment");
            assertEq(n % unit, 0, "NO native alignment");
            assertEq(
                yr,
                orderEngine.getOrder(inventoryOrders[m][a * 2 + 1]).amount,
                "YES reserved equals outstanding covered offer"
            );
            assertEq(
                nr,
                orderEngine.getOrder(inventoryOrders[m][a * 2]).amount,
                "NO reserved equals outstanding covered offer"
            );
            uint256 orderCash = a == 2 ? orderEngine.getOrder(resting[m]).cashReserved : 0;
            assertEq(cash, orderCash, "cash reserved equals outstanding BUY escrow");
            uint256 carry = orderEngine.invalidRemainderOf(mk, actors[a]);
            assertLe(carry, 1, "INVALID half-native carry bound");
            sums[0] += y;
            sums[1] += n;
            sums[2] += cash;
            sums[3] += carry;
        }
        (uint256 yesSupply, uint256 noSupply) = orderEngine.getSupplies(mk);
        assertEq(yesSupply, sums[0], "YES supply equals total actor ownership");
        assertEq(noSupply, sums[1], "NO supply equals total actor ownership");
        assertEq(
            orderEngine.getOrderCash(mk), sums[2], "market cash equals actor reservations"
        );
        uint256 shareBacking = orderEngine.getShareBacking(mk);
        assertEq(orderEngine.getCollateralBacking(mk), shareBacking + sums[2]);
        if (!terminal[m]) {
            assertEq(yesSupply, noSupply, "unsettled complete-set supplies match");
            assertEq(shareBacking, yesSupply / unit, "exact complete-set backing");
            assertEq(sums[3], 0, "no INVALID carry before settlement");
        } else if (finalOutcome[m] == 2) {
            assertEq(
                2 * shareBacking,
                (yesSupply + noSupply) / unit + sums[3],
                "INVALID backing includes every reserved share and half-native carry"
            );
        } else {
            assertEq(
                shareBacking,
                (finalOutcome[m] == 1 ? yesSupply : noSupply) / unit,
                "terminal backing equals all winning inventory"
            );
        }
    }

    function _checkPositionPromises(uint256 m) internal view {
        address mk = markets[m];
        uint256[3] memory sums; // AMM YES/NO, final AMM native
        uint256 ammScale = 10 ** (18 - tokens[m / 2].decimals());
        for (uint256 a; a < 3; ++a) {
            (uint256 y, uint256 n) = amm.getPosition(mk, actors[a]);
            sums[0] += y;
            sums[1] += n;
            sums[2] += _payout(y, n, finalOutcome[m]) / ammScale;
        }
        uint256 ammPromise =
            terminal[m] ? sums[2] * ammScale : (sums[0] > sums[1] ? sums[0] : sums[1]);
        assertGe(
            amm.getMarketCollateral(mk),
            ammPromise,
            "market collateral covers actual position promises"
        );
        // Aggregate LP promise: every entry's lower-bound residual plus the trader
        // promise for the same outcome never exceeds market collateral, before any
        // entry has been paid out. Checked for all three outcomes while live and
        // for the final outcome once settled (payouts and collateral move together).
        if (!burnedAny[m]) {
            for (uint8 o; o < 3; ++o) {
                if (terminal[m] && o != finalOutcome[m]) continue;
                uint256 lpSum;
                for (uint256 r; r < receipts[m].length; ++r) {
                    lpSum += manager.residual(receipts[m][r], o);
                }
                uint256 traderPromise = terminal[m]
                    ? sums[2] * ammScale
                    : (o == 2 ? (sums[0] + sums[1]) / 2 : (o == 1 ? sums[0] : sums[1]));
                assertGe(
                    amm.getMarketCollateral(mk),
                    lpSum + traderPromise,
                    "collateral covers LP residuals plus trader promise"
                );
            }
        }
    }

    function _payout(uint256 y, uint256 n, uint8 outcome)
        internal
        pure
        returns (uint256)
    {
        return outcome == 2 ? (y + n) / 2 : outcome == 1 ? y : n;
    }
}

abstract contract MultiMarketCampaign is Test {
    MultiMarketHandler internal handler;

    function setUp() public {
        handler = new MultiMarketHandler(precision());
        handler.setUp();
        bytes4[] memory selectors = new bytes4[](23);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.sell.selector;
        selectors[2] = handler.fill.selector;
        selectors[3] = handler.place.selector;
        selectors[4] = handler.cancel.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.veto.selector;
        selectors[8] = handler.finish.selector;
        selectors[9] = handler.burn.selector;
        selectors[10] = handler.claim.selector;
        selectors[11] = handler.claim.selector; // give independent pulls more weight
        selectors[12] = handler.addLiquidity.selector;
        selectors[13] = handler.burnEntry.selector;
        selectors[14] = handler.deferCancel.selector;
        selectors[15] = handler.claimDeferred.selector;
        selectors[16] = handler.splitInventory.selector;
        selectors[17] = handler.mergeInventory.selector;
        selectors[18] = handler.quoteInventory.selector;
        selectors[19] = handler.takeInventory.selector;
        selectors[20] = handler.cancelInventory.selector;
        selectors[21] = handler.expireInventory.selector;
        selectors[22] = handler.cleanupInventory.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_MultiMarketSolvencyAndLifecycle() public view {
        handler.checkAll();
    }

    function afterInvariant() public {
        // Exercise terminal exits after arbitrary campaign histories, even when
        // random scheduling did not happen to select finish/burn in that order.
        // Entry burns remain partial; this does not assert zero AMM/LP liabilities.
        uint256 end = block.timestamp;
        for (uint256 m; m < 4; ++m) {
            TruthMarket tm = TruthMarket(handler.markets(m));
            uint256 timeout = uint256(tm.deadline()) + tm.invalidationBuffer();
            if (timeout > end) end = timeout;
        }
        vm.warp(end);
        for (uint256 m; m < 4; ++m) {
            handler.finish(m);
            handler.cancel(m);
            handler.cleanupInventory(m);
            handler.burn(m, 1);
            for (uint256 k; k < 7; ++k) {
                for (uint256 a; a < 3; ++a) {
                    handler.claim(m, a, k);
                }
            }
            for (uint256 a; a < 3; ++a) {
                for (uint256 r; r + 1 < handler.receiptCount(m); ++r) {
                    handler.burnEntry(m, r, a);
                }
            }
        }
        handler.claimDeferred();
        handler.checkAll();
        assertGt(handler.deferralCount(), 0, "real deferrals reached");
        assertGt(handler.deferredClaimCount(), 0, "real deferred claims reached");
        assertGt(handler.successes(5), 0, "campaign must move time");
        assertGt(handler.successes(6), 0, "campaign must resolve");
        assertGt(handler.successes(12), 0, "campaign must burn LP");
        assertGt(handler.successes(13), 0, "campaign must execute claims");
        assertGt(handler.successes(14), 0, "campaign must add liquidity");
        for (uint256 k; k < 7; ++k) {
            assertGt(handler.bookSuccess(k), 0, "gross inventory operation reached");
        }
    }

    function test_ReachEveryOutcomeAndClaimClass() public {
        _reachEveryOutcome(0);
    }

    function test_ReachEveryOutcomeAndClaimClass_RotatedTokenA() public {
        _reachEveryOutcome(2);
    }

    function _reachEveryOutcome(uint256 offset) internal {
        // Veto and retry on a shared-token market while the others keep trading.
        handler.resolve(offset, 0);
        handler.veto(offset);
        handler.buy((1 + offset) % 4, 2, 3e18, true);
        handler.addLiquidity((1 + offset) % 4, 2, 7e18);
        handler.addLiquidity((3 + offset) % 4, 0, 2e18);
        handler.resolve(offset, 1);
        handler.resolve((1 + offset) % 4, 0);
        handler.resolve((2 + offset) % 4, 2);
        handler.advance(1 hours);
        for (uint256 i; i < 3; ++i) {
            handler.finish((i + offset) % 4);
        }
        // Leave the fourth market LIVE until permissionless timeout INVALID.
        TruthMarket fourth = TruthMarket(handler.markets((3 + offset) % 4));
        vm.warp(uint256(fourth.deadline()) + fourth.invalidationBuffer());
        handler.finish((3 + offset) % 4);
        for (uint256 i; i < 4; ++i) {
            handler.burn(i, 2);
            handler.cancel(i); // cancellation remains reachable after settlement
            // Deliberately different pull ordering across markets.
            for (uint256 k; k < 7; ++k) {
                for (uint256 a; a < 3; ++a) {
                    handler.claim(i, a, (k + i) % 7);
                }
            }
            // Free balances were claimed above while covered offers stayed locked.
            // Cancellation remains possible, followed by a second terminal claim.
            if (handler.finalOutcome(i) == 2) {
                assertEq(
                    handler.bookInvalidRemainder(i, 2),
                    1,
                    "asymmetric reserved INVALID inventory produces half-native carry"
                );
            }
            for (uint256 a; a < 3; ++a) {
                handler.cancelInventory(i, a, 0);
                handler.cancelInventory(i, a, 1);
                handler.claim(i, a, 1);
            }
            assertEq(
                handler.bookInvalidRemainder(i, 2),
                0,
                "released complementary inventory clears INVALID carry"
            );
            handler.burn(i, 1);
            handler.claim(i, 0, 3);
            handler.claim(i, 0, 2);
            for (uint256 a; a < 3; ++a) {
                for (uint256 r; r + 1 < handler.receiptCount(i); ++r) {
                    handler.burnEntry(i, r, a);
                }
            }
        }
        for (uint256 k; k < 16; ++k) {
            assertGt(handler.successes(k), 0, "unreached operation");
            emit log_named_uint(
                string.concat("operation ", vm.toString(k)), handler.successes(k)
            );
        }
        for (uint256 k; k < 7; ++k) {
            assertGt(handler.claimSuccess(k), 0, "unreached claim class");
            emit log_named_uint(
                string.concat("claim class ", vm.toString(k)), handler.claimSuccess(k)
            );
        }
        for (uint256 k; k < 7; ++k) {
            assertGt(handler.bookSuccess(k), 0, "unreached gross inventory operation");
            emit log_named_uint(
                string.concat("gross inventory operation ", vm.toString(k)),
                handler.bookSuccess(k)
            );
        }
        handler.checkAll();
    }
    function precision() internal pure virtual returns (uint8);
}

contract MultiMarketBook6Invariant is MultiMarketCampaign {
    function precision() internal pure override returns (uint8) {
        return 6;
    }
}

contract MultiMarketBook18Invariant is MultiMarketCampaign {
    function precision() internal pure override returns (uint8) {
        return 18;
    }
}

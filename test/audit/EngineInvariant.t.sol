// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {TruthMarket} from "src/TruthMarket.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {OrderEngine} from "src/OrderEngine.sol";

contract AuditCash is ERC20 {
    constructor() ERC20("Audit cash", "CASH") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Handler over one real node: 6-decimal AMM, 6-decimal book, both vaults.
/// @dev Preconditions return. Unexpected engine failures are bubbled so
///      `fail_on_revert` keeps them. Fee and rounding checks run on every
///      successful action; the invariant functions re-read the ledgers.
contract AuditHandler is DualTokenBase {
    uint8 internal constant DEC = 6;
    address internal constant GUARDIAN = address(0x6A12D);

    AuditCash public cash;
    address[3] public actors;
    uint64[16] internal restingIds;
    uint256 public restingCount;
    uint256 public proposedAt;

    uint256 public ammFunded;
    uint256 public ammClaimed;
    uint256 public bookFunded;
    uint256 public bookClaimed;
    uint256 public skipped;

    uint256 public lastBuyQuoted;
    uint256 public lastBuyNative;
    bool public lastBuySet;
    uint256 public lastSellQuoted;
    uint256 public lastSellNative;
    bool public lastSellSet;
    mapping(address => uint256) public yesPos;
    mapping(address => uint256) public noPos;

    function setUp() public override {
        super.setUp();
        cash = new AuditCash();
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = trader;
        cash.mint(creator, 1_000_000e6);
        vm.prank(creator);
        cash.approve(address(marketFactory), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            cash.mint(actors[i], 1_000_000e6);
            usdc.mint(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            cash.approve(address(amm), type(uint256).max);
            usdc.approve(address(orderEngine), type(uint256).max);
            vm.stopPrank();
        }
        adjudicator.approveGuardian(GUARDIAN);
        IMarketFactory.MarketParams memory p = _marketParams(
            "audit invariant",
            0,
            uint64(block.timestamp + 20 days),
            address(cash),
            25e18,
            0.5e18
        );
        vm.prank(creator);
        (market,) = marketFactory.createMarket(p);
        buy(0, 1, 1e18);
        splitShares(1, 20e18);
    }

    function _actor(uint8 who) internal view returns (address) {
        return actors[who % 3];
    }

    function _until() internal view returns (uint64) {
        return uint64(block.timestamp + 1 hours);
    }

    function _shares(uint256 raw) internal view returns (uint256 amount) {
        uint256 unit = orderEngine.shareUnit();
        amount = bound(raw, unit * 2, 50e18);
        amount = amount / unit * unit;
    }

    function _knownOrderRevert(bytes memory data) internal pure returns (bool) {
        if (data.length < 4) return false;
        bytes4 sel = bytes4(data);
        return sel == OrderEngine.NothingFilled.selector
            || sel == OrderEngine.InsufficientInventory.selector
            || sel == OrderEngine.CashLimit.selector
            || sel == OrderEngine.InvalidExpiry.selector
            || sel == OrderEngine.MarketNotLive.selector
            || sel == OrderEngine.InvalidOrderTerms.selector;
    }

    function _bubble(bytes memory data) internal pure {
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    function _ammBuckets()
        internal
        view
        returns (uint256 lp, uint256 resolution, uint256 operator)
    {
        lp = vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(cash));
        resolution =
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(cash));
        operator = vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(cash));
    }

    function _quotePosition(uint8 outcome, int256 shares)
        internal
        view
        returns (bool ok, uint256 net)
    {
        try amm.getPositionQuote(market, outcome, shares) returns (
            uint256 base, uint256 fee, uint256 quoted, uint256 price
        ) {
            _checkQuotedFee(base, fee);
            assertLe(price, 1e18, "quoted probability");
            return (true, quoted);
        } catch {
            return (false, 0);
        }
    }

    function _quoteLiquidity(uint256 db)
        internal
        view
        returns (bool ok, uint256 input, uint256 units, uint256 price, bytes32 stateHash)
    {
        try amm.quoteLiquidityWithState(market, db) returns (
            uint256 quotedIn, uint256 quotedUnits, uint256 quotedPrice, bytes32 hash
        ) {
            return (true, quotedIn, quotedUnits, quotedPrice, hash);
        } catch {
            return (false, 0, 0, 0, bytes32(0));
        }
    }

    function _trade(address actor, uint8 outcome, int256 shares, uint256 limit)
        internal
        returns (uint256 paid)
    {
        vm.prank(actor);
        paid = amm.tradePositions(market, outcome, shares, limit);
    }

    function _executeBuy(address actor, uint8 outcome, uint256 shares, uint256 net)
        internal
    {
        uint256 native = DecimalMath.fromWadCeil(net, DEC);
        (uint256 lp0, uint256 res0, uint256 op0) = _ammBuckets();
        uint256 liab0 = vault.marketLiabilitiesOf(market, address(cash));
        uint256 before = cash.balanceOf(actor);
        uint256 paid = _trade(actor, outcome, int256(shares), type(uint256).max);
        assertEq(paid, net, "buy quote drifted");
        uint256 spent = before - cash.balanceOf(actor);
        assertEq(spent, native, "buy did not collect the ceil");
        assertGe(DecimalMath.toWad(spent, DEC), net, "buy under-collected");
        _noteAmmDeposit(lp0, res0, op0, liab0);
        if (outcome == 1) yesPos[actor] += shares;
        else noPos[actor] += shares;
        lastBuyQuoted = net;
        lastBuyNative = spent;
        lastBuySet = true;
    }

    function _executeSell(address actor, uint8 outcome, uint256 shares, uint256 net)
        internal
    {
        (uint256 lp0, uint256 res0, uint256 op0) = _ammBuckets();
        uint256 liab0 = vault.marketLiabilitiesOf(market, address(cash));
        uint256 before = cash.balanceOf(actor);
        uint256 proceeds = _trade(actor, outcome, -int256(shares), net);
        assertEq(proceeds, net, "sell quote drifted");
        uint256 got = cash.balanceOf(actor) - before;
        assertEq(got, DecimalMath.fromWad(net, DEC), "sell did not floor");
        assertLe(DecimalMath.toWad(got, DEC), net, "sell overpaid");
        _noteAmmDeposit(lp0, res0, op0, liab0);
        if (outcome == 1) yesPos[actor] -= shares;
        else noPos[actor] -= shares;
        lastSellQuoted = net;
        lastSellNative = got;
        lastSellSet = true;
    }

    function _executeLiquidity(
        address actor,
        uint256 db,
        uint256 input,
        uint256 units,
        uint256 price,
        bytes32 stateHash
    ) internal {
        uint256 col0 = amm.getMarketCollateral(market);
        uint256 before = cash.balanceOf(actor);
        // Read the deadline before prank. An external call in the argument
        // list would consume the prank and pull from this contract.
        uint64 deadline = TruthMarket(market).deadline();
        vm.prank(actor);
        (, uint256 depositWad) = amm.increaseLiquidity(
            market,
            db,
            IAMMEngine.LiquidityLimits(input, units, price, price, deadline, stateHash)
        );
        uint256 spent = before - cash.balanceOf(actor);
        assertEq(spent, input, "liquidity collected a different amount");
        assertEq(DecimalMath.toWad(spent, DEC), depositWad, "receipt is not the payment");
        assertEq(amm.getMarketCollateral(market) - col0, depositWad, "collateral");
    }

    function buy(uint8 who, uint8 outcome, uint96 raw) public {
        if (!_trading()) return;
        address actor = _actor(who);
        outcome %= 2;
        uint256 shares = bound(uint256(raw), 1e15, 2e18);
        (bool quoted, uint256 net) = _quotePosition(outcome, int256(shares));
        if (!quoted) {
            ++skipped;
            return;
        }
        if (cash.balanceOf(actor) < DecimalMath.fromWadCeil(net, DEC)) {
            ++skipped;
            return;
        }
        _executeBuy(actor, outcome, shares, net);
    }

    function sell(uint8 who, uint8 outcome, uint96 raw) external {
        if (!_trading()) return;
        address actor = _actor(who);
        outcome %= 2;
        uint256 shares = bound(uint256(raw), 1e15, 2e18);
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        if ((outcome == 1 ? yes : no) < shares) {
            ++skipped;
            return;
        }
        (bool quoted, uint256 net) = _quotePosition(outcome, -int256(shares));
        if (!quoted || net == 0) {
            ++skipped;
            return;
        }
        _executeSell(actor, outcome, shares, net);
    }

    function addLiquidity(uint8 who, uint96 raw) external {
        if (!TruthMarket(market).isLiquidityOpen()) {
            ++skipped;
            return;
        }
        address actor = _actor(who);
        uint256 db = bound(uint256(raw), 1e17, 2e18);
        (bool quoted, uint256 input, uint256 units, uint256 price, bytes32 stateHash) =
            _quoteLiquidity(db);
        if (
            !quoted || input == 0 || units == 0 || price == 0 || price >= 1e18
                || cash.balanceOf(actor) < input
        ) {
            ++skipped;
            return;
        }
        _executeLiquidity(actor, db, input, units, price, stateHash);
    }

    function splitShares(uint8 who, uint96 raw) public {
        if (!_trading()) return;
        address actor = _actor(who);
        uint256 amount = _shares(raw);
        uint256 unit = orderEngine.shareUnit();
        uint256 col = amount / unit;
        if (usdc.balanceOf(actor) < col) {
            ++skipped;
            return;
        }
        uint256 before = usdc.balanceOf(actor);
        vm.prank(actor);
        uint256 got = orderEngine.split(market, amount, type(uint256).max - 1, _until());
        assertEq(before - usdc.balanceOf(actor), got, "split pull");
        assertEq(got, col, "split is one token per pair");
    }

    function mergeShares(uint8 who, uint96 raw) external {
        address actor = _actor(who);
        (uint256 yes, uint256 no, uint256 yesR, uint256 noR,) =
            orderEngine.getInventory(market, actor);
        uint256 cap = yes - yesR < no - noR ? yes - yesR : no - noR;
        uint256 unit = orderEngine.shareUnit();
        if (cap < unit) {
            ++skipped;
            return;
        }
        uint256 amount = _shares(raw);
        if (amount > cap) amount = cap / unit * unit;
        if (amount == 0) return;
        uint256 before = usdc.balanceOf(actor);
        vm.prank(actor);
        uint256 got = orderEngine.merge(market, amount, 0, _until());
        assertEq(usdc.balanceOf(actor) - before, got, "merge payout");
        assertEq(got, amount / unit, "merge is exact");
    }

    function restOrder(uint8 who, uint8 action, uint16 tickSeed, uint96 raw) external {
        if (!_trading()) return;
        address actor = _actor(who);
        action %= 2;
        uint16 tick = uint16(bound(tickSeed, 1, 999));
        uint256 amount = _shares(raw);
        uint256 minRest = orderEngine.getMinRestingOrder(tick);
        if (amount < minRest) amount = minRest;
        (uint256 yes, uint256 no, uint256 yesR, uint256 noR,) =
            orderEngine.getInventory(market, actor);
        uint8 outcome = uint8(tickSeed % 2);
        if (action == 1) {
            uint256 avail = outcome == 1 ? yes - yesR : no - noR;
            if (avail < amount) {
                ++skipped;
                return;
            }
            _place(actor, action, outcome, tick, amount);
        } else {
            if (usdc.balanceOf(actor) == 0) {
                ++skipped;
                return;
            }
            _place(actor, action, outcome, tick, amount);
        }
    }

    function cancelOrder(uint256 index) external {
        if (restingCount == 0) return;
        uint256 n = restingCount < 16 ? restingCount : 16;
        uint64 id = restingIds[index % n];
        if (id == 0) return;
        IOrderEngine.OrderView memory order = orderEngine.getOrder(id);
        if (order.amount == 0 || order.maker == address(0)) return;
        vm.prank(order.maker);
        orderEngine.cancelById(id);
    }

    function claimOperator() external {
        _claimAmm(treasury, true);
    }

    function claimProtocol() external {
        uint256 before = usdc.balanceOf(treasury);
        uint256 liab = bookVault.marketLiabilitiesOf(market, address(usdc));
        uint256 paid = bookVault.claimProtocolFees(market);
        assertEq(usdc.balanceOf(treasury) - before, paid, "protocol claim");
        assertLe(paid, liab, "protocol claim above liabilities");
        assertEq(bookVault.marketLiabilitiesOf(market, address(usdc)), liab - paid);
        bookClaimed += paid;
    }

    function claimResolution(bool bookVenue) external {
        if (!TruthMarket(market).isSettled()) {
            ++skipped;
            return;
        }
        if (
            TruthMarket(market).settlementKind()
                == ITruthMarket.SettlementKind.INVALIDATED
        ) {
            ++skipped;
            return;
        }
        if (bookVenue) {
            uint256 before = usdc.balanceOf(address(this));
            uint256 liab = bookVault.marketLiabilitiesOf(market, address(usdc));
            uint256 paid = bookVault.claimResolutionFees(market);
            assertEq(usdc.balanceOf(address(this)) - before, paid, "book resolution");
            assertLe(paid, liab);
            bookClaimed += paid;
        } else {
            uint256 before = cash.balanceOf(address(this));
            uint256 liab = vault.marketLiabilitiesOf(market, address(cash));
            uint256 paid = vault.claimResolutionFees(market);
            assertEq(cash.balanceOf(address(this)) - before, paid, "amm resolution");
            assertLe(paid, liab);
            ammClaimed += paid;
        }
    }

    function propose(uint8 outcome) external {
        TruthMarket truth = TruthMarket(market);
        if (
            truth.state() != TruthMarket.MarketState.LIVE
                || adjudicator.resolutionLocked(market)
        ) {
            ++skipped;
            return;
        }
        if (truth.deadline() == type(uint64).max) return;
        uint256 cutoff = uint256(truth.deadline()) + truth.invalidationBuffer();
        if (block.timestamp + adjudicator.vetoPeriod() >= cutoff) {
            ++skipped;
            return;
        }
        vm.prank(resolver);
        adjudicator.resolve(market, outcome % 3, keccak256("audit-invariant"));
        proposedAt = block.timestamp;
    }

    function dispute() external {
        TruthMarket truth = TruthMarket(market);
        if (!truth.isResolving() && !truth.isAttested()) {
            ++skipped;
            return;
        }
        if (block.timestamp >= proposedAt + adjudicator.vetoPeriod()) {
            ++skipped;
            return;
        }
        if (
            adjudicator.guardianVetoCount(market, GUARDIAN)
                >= adjudicator.GUARDIAN_VETO_CAP()
        ) {
            ++skipped;
            return;
        }
        vm.prank(GUARDIAN);
        adjudicator.dispute(market);
    }

    function settleMarket() external {
        TruthMarket truth = TruthMarket(market);
        if (!truth.isResolving() && !truth.isAttested()) {
            ++skipped;
            return;
        }
        uint256 target = block.timestamp + adjudicator.vetoPeriod();
        uint256 cutoff = uint256(truth.deadline()) + truth.invalidationBuffer();
        if (target >= cutoff) {
            ++skipped;
            return;
        }
        vm.warp(target);
        adjudicator.settle(market);
    }

    function settleAmm(uint8 who) external {
        if (!TruthMarket(market).isSettled()) {
            ++skipped;
            return;
        }
        address actor = _actor(who);
        (uint256 yes, uint256 no) = amm.getPosition(market, actor);
        if (yes == 0 && no == 0) return;
        uint256 before = cash.balanceOf(actor);
        vm.prank(actor);
        uint256 payout = amm.settlePosition(market);
        uint256 got = cash.balanceOf(actor) - before;
        assertEq(got, DecimalMath.fromWad(payout, DEC), "AMM payout was not floored");
        assertLe(DecimalMath.toWad(got, DEC), payout, "AMM payout overpaid");
        uint8 winner = TruthMarket(market).winningOutcome();
        if (winner == 1) assertEq(payout, yes, "YES entitlement");
        else if (winner == 0) assertEq(payout, no, "NO entitlement");
        else assertEq(payout, (yes + no) / 2, "INVALID entitlement");
        yesPos[actor] = 0;
        noPos[actor] = 0;
    }

    function settleBook(uint8 who) external {
        if (!TruthMarket(market).isSettled()) {
            ++skipped;
            return;
        }
        address actor = _actor(who);
        (uint256 yes, uint256 no, uint256 yesR, uint256 noR,) =
            orderEngine.getInventory(market, actor);
        if (yes == yesR && no == noR) return;
        uint256 before = usdc.balanceOf(actor);
        vm.prank(actor);
        uint256 payout = orderEngine.settlePosition(market);
        assertEq(usdc.balanceOf(actor) - before, payout, "book payout");
        uint8 winner = TruthMarket(market).winningOutcome();
        uint256 unit = orderEngine.shareUnit();
        if (winner == 1) assertEq(payout, (yes - yesR) / unit, "book YES");
        else if (winner == 0) assertEq(payout, (no - noR) / unit, "book NO");
        else assertLe(payout, (yes - yesR + no - noR) / unit, "book INVALID");
    }

    function warpSmall(uint32 seconds_) external {
        uint256 dt = bound(uint256(seconds_), 1, 30 minutes);
        if (block.timestamp + dt >= TruthMarket(market).deadline()) {
            ++skipped;
            return;
        }
        vm.warp(block.timestamp + dt);
    }

    function assertAmmSolvent() external view {
        uint256 liabilities = amm.totalLiabilitiesOf(address(cash));
        uint256 widened =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertGe(
            cash.balanceOf(address(amm)),
            DecimalMath.fromWadCeil(liabilities, DEC),
            "AMM balance below liabilities"
        );
        assertGe(
            cash.balanceOf(address(amm)),
            DecimalMath.fromWadCeil(widened, DEC),
            "AMM balance below collateral and floor"
        );
        assertEq(liabilities, widened, "token liabilities are collateral plus floor");
    }

    function assertBookBacking() external view {
        uint256 backing =
            orderEngine.getShareBacking(market) + orderEngine.getOrderCash(market);
        assertEq(backing, orderEngine.getCollateralBacking(market), "backing parts");
        assertGe(
            usdc.balanceOf(address(orderEngine)),
            backing + orderEngine.totalDeferred(),
            "book balance below backing and deferrals"
        );
    }

    function assertVaultsSolvent() external view {
        assertGe(
            cash.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(cash)),
            "AMM vault"
        );
        assertGe(
            usdc.balanceOf(address(bookVault)),
            bookVault.totalLiabilitiesOf(address(usdc)),
            "book vault"
        );
    }

    function assertFeeSplits() external view {
        (uint256 lp, uint256 resolution, uint256 operator) = _ammBuckets();
        assertEq(
            lp + resolution + operator,
            vault.marketLiabilitiesOf(market, address(cash)),
            "AMM buckets"
        );
        uint256 bookRes =
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 bookPro =
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        assertEq(
            bookRes + bookPro,
            bookVault.marketLiabilitiesOf(market, address(usdc)),
            "book buckets"
        );
    }

    function assertPayoutsWithinFunding() external view {
        assertLe(ammClaimed, ammFunded, "AMM claims above deposits");
        assertLe(bookClaimed, bookFunded, "book claims above deposits");
        assertEq(
            vault.marketLiabilitiesOf(market, address(cash)),
            ammFunded - ammClaimed,
            "AMM liability drift"
        );
        assertEq(
            bookVault.marketLiabilitiesOf(market, address(usdc)),
            bookFunded - bookClaimed,
            "book liability drift"
        );
    }

    function assertRounding() external view {
        if (lastBuySet) {
            assertGe(DecimalMath.toWad(lastBuyNative, DEC), lastBuyQuoted, "buy sample");
        }
        if (lastSellSet) {
            assertLe(
                DecimalMath.toWad(lastSellNative, DEC), lastSellQuoted, "sell sample"
            );
        }
    }

    function assertPositions() external view {
        (uint256 yesSupply, uint256 noSupply) = orderEngine.getSupplies(market);
        // Settlement burns whatever free inventory a holder has. A one-sided
        // fill, or a resting order that keeps the other side reserved, leaves
        // the two supplies unequal after that burn. Until then every split and
        // merge moves them together.
        if (!TruthMarket(market).isSettled()) {
            assertEq(yesSupply, noSupply, "complete-set supply");
        }
        uint256 yesSum;
        uint256 noSum;
        uint256 cashSum;
        for (uint256 i; i < 3; ++i) {
            (uint256 yes, uint256 no, uint256 yesR, uint256 noR, uint256 reserved) =
                orderEngine.getInventory(market, actors[i]);
            assertGe(yes, yesR, "YES reserved");
            assertGe(no, noR, "NO reserved");
            yesSum += yes;
            noSum += no;
            cashSum += reserved;
            (uint256 py, uint256 pn) = amm.getPosition(market, actors[i]);
            assertEq(py, yesPos[actors[i]], "AMM YES");
            assertEq(pn, noPos[actors[i]], "AMM NO");
        }
        assertEq(yesSum, yesSupply, "YES inventory");
        assertEq(noSum, noSupply, "NO inventory");
        assertEq(cashSum, orderEngine.getOrderCash(market), "reserved cash");
    }

    function _trading() internal view returns (bool) {
        if (TruthMarket(market).isTradingOpen()) return true;
        return false;
    }

    function _checkQuotedFee(uint256 base, uint256 fee) internal view {
        uint16 bps = vault.feeBpsOf(market);
        assertEq(fee, base * bps / 10_000, "fee is not the floored bps");
        assertLe(fee * 10_000, base * uint256(bps), "fee above the exact product");
        IAmmFeeVault.AmmConfig memory cfg = vault.configOf(market);
        uint256 capital = fee * cfg.capitalBps / 10_000;
        assertEq(capital + (fee - capital), fee, "capital split");
    }

    function _noteAmmDeposit(uint256 lp0, uint256 res0, uint256 op0, uint256 liab0)
        internal
    {
        (uint256 lp1, uint256 res1, uint256 op1) = _ammBuckets();
        uint256 credited = (lp1 - lp0) + (res1 - res0) + (op1 - op0);
        uint256 liab1 = vault.marketLiabilitiesOf(market, address(cash));
        assertEq(liab1 - liab0, credited, "AMM deposit was not fully split");
        ammFunded += credited;
    }

    function _place(
        address actor,
        uint8 action,
        uint8 outcome,
        uint16 tick,
        uint256 amount
    ) internal {
        IOrderEngine.OrderParams memory p;
        p.outcome = outcome;
        p.action = action;
        p.priceTick = tick;
        p.amount = uint128(amount);
        p.matchLimit = 8;
        p.validUntil = _until();
        p.rest = true;
        p.maxTokenIn = usdc.balanceOf(actor);
        if (p.maxTokenIn == type(uint256).max) p.maxTokenIn = type(uint256).max - 1;
        uint256 res0 =
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 pro0 =
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        uint256 liab0 = bookVault.marketLiabilitiesOf(market, address(usdc));
        vm.prank(actor);
        (bool ok, bytes memory data) =
            address(orderEngine).call(abi.encodeCall(orderEngine.placeOrder, (market, p)));
        if (!ok) {
            if (_knownOrderRevert(data)) {
                ++skipped;
                return;
            }
            _bubble(data);
        }
        IOrderEngine.OrderResult memory result =
            abi.decode(data, (IOrderEngine.OrderResult));
        uint256 res1 =
            bookVault.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, address(usdc));
        uint256 pro1 =
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(usdc));
        uint256 credited = (res1 - res0) + (pro1 - pro0);
        assertEq(credited, result.fee, "book fee was not fully split");
        assertEq(bookVault.marketLiabilitiesOf(market, address(usdc)) - liab0, credited);
        IBookFeeVault.BookConfig memory cfg = bookVault.configOf(market);
        uint256 resolution = result.fee * cfg.resolutionBps / 10_000;
        assertEq(res1 - res0, resolution, "book resolution bucket");
        assertEq(pro1 - pro0, result.fee - resolution, "book protocol remainder");
        bookFunded += credited;
        if (result.orderId != 0) {
            restingIds[restingCount % 16] = result.orderId;
            ++restingCount;
        }
    }

    function _claimAmm(address recipient, bool operatorBucket) internal {
        uint256 before = cash.balanceOf(recipient);
        uint256 liab = vault.marketLiabilitiesOf(market, address(cash));
        uint256 paid = operatorBucket
            ? vault.claimOperatorFees(market)
            : vault.claimResolutionFees(market);
        assertEq(cash.balanceOf(recipient) - before, paid, "AMM claim");
        assertLe(paid, liab, "AMM claim above liabilities");
        assertEq(vault.marketLiabilitiesOf(market, address(cash)), liab - paid);
        ammClaimed += paid;
    }
}

contract EngineAuditInvariantTest is Test {
    AuditHandler internal h;

    function setUp() public {
        h = new AuditHandler();
        h.setUp();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = h.buy.selector;
        selectors[1] = h.sell.selector;
        selectors[2] = h.addLiquidity.selector;
        selectors[3] = h.splitShares.selector;
        selectors[4] = h.mergeShares.selector;
        selectors[5] = h.restOrder.selector;
        selectors[6] = h.cancelOrder.selector;
        selectors[7] = h.claimOperator.selector;
        selectors[8] = h.claimProtocol.selector;
        selectors[9] = h.claimResolution.selector;
        selectors[10] = h.propose.selector;
        selectors[11] = h.dispute.selector;
        selectors[12] = h.settleMarket.selector;
        selectors[13] = h.settleAmm.selector;
        selectors[14] = h.settleBook.selector;
        selectors[15] = h.warpSmall.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_ammSolvency() public view {
        h.assertAmmSolvent();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_bookBacking() public view {
        h.assertBookBacking();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_vaultSolvency() public view {
        h.assertVaultsSolvent();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_feeSplitsSumExactly() public view {
        h.assertFeeSplits();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_payoutsWithinFunding() public view {
        h.assertPayoutsWithinFunding();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_roundingFavorsProtocol() public view {
        h.assertRounding();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail_on_revert = true
    function invariant_shareAndPositionAccounting() public view {
        h.assertPositions();
    }
}

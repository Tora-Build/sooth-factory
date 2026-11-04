// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IHookProbe {
    function onTransfer(address from, address to, uint256 amount) external;
}

/// @notice Exact-receipt token that reports every non-mint transfer.
/// @dev Balances move before the probe, matching an ERC-777 tokensReceived hook.
contract HookToken is ERC20 {
    uint8 private immutable _precision;
    address public probe;
    bool public callbacks;
    uint256 public hooks;

    constructor(uint8 precision_) ERC20("Hook stable", "HOOK") {
        _precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setProbe(address probe_, bool enabled) external {
        probe = probe_;
        callbacks = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (!callbacks || from == address(0) || to == address(0)) return;
        hooks++;
        callbacks = false;
        if (probe != address(0)) IHookProbe(probe).onTransfer(from, to, value);
        callbacks = true;
    }
}

/// @notice L-1: OrderEngine payout hooks vs view consistency and MarketFactory admission.
/// @dev The book token is immutable at OrderEngine construction. These tests install a
///      hook token there only to observe the window the lead describes, then show what
///      MarketFactory.setTokenAllowed actually admits.
contract L1OrderEngineReadOnlyReentrancyTest is DualTokenBase, IHookProbe {
    uint256 internal constant UNIT = 1e12;
    uint256 internal constant SET = 1000e18;
    bytes4 internal constant REENTRANT =
        bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    HookToken internal book;
    address internal carol = address(0xCA401);

    struct Snap {
        address from;
        address to;
        uint256 amount;
        uint256 engineBalance;
        uint256 backing;
        uint256 shareBacking;
        uint256 orderCash;
        uint256 deferred;
        uint256 vaultBalance;
        uint256 vaultLiabilities;
        uint256 yesSupply;
        uint256 noSupply;
        uint256 sumYes;
        uint256 sumNo;
        uint256 sumReserved;
        uint256 takerYes;
        bool guardHeld;
        bool extracted;
    }

    Snap[] internal snaps;
    bool internal inProbe;

    function setUp() public override {
        east = new East18E();
        book = new HookToken(6);
        _deployStack(address(book));
        east.mint(creator, 1000e18);
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        _createMarket();
        book.mint(alice, 1_000_000e6);
        book.mint(bob, 1_000_000e6);
        book.mint(carol, 1_000_000e6);
        vm.prank(alice);
        book.approve(address(orderEngine), type(uint256).max);
        vm.prank(bob);
        book.approve(address(orderEngine), type(uint256).max);
        vm.prank(carol);
        book.approve(address(orderEngine), type(uint256).max);
        book.setProbe(address(this), false);
    }

    /// @dev Two resting YES asks. The taker pays for both before either maker is paid.
    function test_midFillHooks_viewsStayConsistentAndGapIsNotWithdrawable() public {
        _split(bob);
        _split(carol);
        vm.prank(bob);
        orderEngine.placeOrder(market, _sell(1, 400, uint128(SET), true));
        vm.prank(carol);
        orderEngine.placeOrder(market, _sell(1, 600, uint128(SET), true));

        uint256 engineBefore = book.balanceOf(address(orderEngine));
        book.setProbe(address(this), true);
        vm.prank(alice);
        IOrderEngine.OrderResult memory result =
            orderEngine.placeOrder(market, _buy(1, 600, uint128(SET * 2), false));
        book.setProbe(address(this), false);

        assertEq(result.filled, SET * 2, "both asks fill");
        assertEq(result.tokenIn, 1008e6, "400 + 600 notional plus 8 fee");
        assertEq(result.tokenOut, 0, "buy does not pay the taker");
        assertEq(result.fee, 8e6, "fee basis uses min(tick, 1000-tick)");
        assertEq(snaps.length, 4, "collect, two maker pays, fee deposit");

        _expectCustody(0, alice, address(orderEngine), 1008e6, 1008e6, 0);
        _expectCustody(1, address(orderEngine), bob, 400e6, 608e6, 0);
        _expectCustody(2, address(orderEngine), carol, 600e6, 8e6, 0);
        _expectCustody(3, address(orderEngine), address(bookVault), 8e6, 0, 8e6);

        assertEq(
            snaps[0].takerYes, 0, "taker not yet credited for a payment already taken"
        );
        assertEq(snaps[1].takerYes, SET, "only the first fill is visible mid loop");
        assertEq(snaps[2].takerYes, SET * 2, "both fills applied before the fee moves");
        assertEq(snaps[3].takerYes, SET * 2, "fee deposit does not change inventory");

        (uint256 yesAfter, uint256 noAfter,,,) = orderEngine.getInventory(market, alice);
        assertEq(yesAfter, SET * 2, "final taker inventory matches both fills");
        assertEq(noAfter, 0, "taker did not buy NO");
        assertEq(
            book.balanceOf(address(orderEngine)),
            engineBefore,
            "maker cash and the fee both left; complete-set backing remains"
        );
        assertEq(book.balanceOf(address(bookVault)), 8e6, "fee is a vault liability");
        _assertFinalCustody();
    }

    /// @dev Taker sell is paid at the end of placeOrder, before BookFeeVault.depositRevenue.
    function test_takerPayoutHook_feeRemainsInFlightUntilDeposit() public {
        _split(alice);
        vm.prank(bob);
        orderEngine.placeOrder(market, _buy(1, 500, uint128(SET), true));

        book.setProbe(address(this), true);
        vm.prank(alice);
        IOrderEngine.OrderResult memory result =
            orderEngine.placeOrder(market, _sell(1, 500, uint128(SET), false));
        book.setProbe(address(this), false);

        assertEq(result.tokenIn, 0, "fee is netted from sale proceeds");
        assertEq(result.tokenOut, 495e6, "500 escrow minus 5 fee");
        assertEq(result.fee, 5e6, "1% of the 500 tick notional");
        assertEq(snaps.length, 2, "taker pay, then fee deposit");

        _expectCustody(0, address(orderEngine), alice, 495e6, 5e6, 0);
        _expectCustody(1, address(orderEngine), address(bookVault), 5e6, 0, 5e6);
        assertEq(snaps[0].vaultLiabilities, 0, "vault has not credited the fee yet");
        assertEq(snaps[0].orderCash, 0, "maker escrow was released before the payout");
        assertEq(snaps[0].takerYes, 0, "sold inventory is already debited");
        (uint256 bobYes,,,,) = orderEngine.getInventory(market, bob);
        assertEq(bobYes, SET, "maker inventory was credited before the taker hook");
        _assertFinalCustody();
    }

    function onTransfer(address from, address to, uint256 amount) external {
        require(msg.sender == address(book), "probe caller");
        require(!inProbe, "probe reentered itself");
        inProbe = true;
        Snap memory s = _capture(from, to, amount);
        _assertLedgers(s);
        s.guardHeld = _reenterReverts();
        s.extracted = _tryExtract(s.engineBalance - s.backing - s.deferred);
        assertTrue(s.guardHeld, "state-changing book entry was not guarded");
        assertFalse(s.extracted, "hook withdrew in-flight cash");
        _assertSweep(to);
        snaps.push(s);
        inProbe = false;
    }

    function _capture(address from, address to, uint256 amount)
        internal
        view
        returns (Snap memory s)
    {
        s.from = from;
        s.to = to;
        s.amount = amount;
        s.backing = orderEngine.getCollateralBacking(market);
        s.shareBacking = orderEngine.getShareBacking(market);
        s.orderCash = orderEngine.getOrderCash(market);
        s.deferred = orderEngine.totalDeferred();
        (s.yesSupply, s.noSupply) = orderEngine.getSupplies(market);
        (s.sumYes, s.sumNo, s.sumReserved) = _sumInventory();
        s.engineBalance = book.balanceOf(address(orderEngine));
        s.vaultBalance = book.balanceOf(address(bookVault));
        s.vaultLiabilities = bookVault.totalLiabilitiesOf(address(book));
        (s.takerYes,,,,) = orderEngine.getInventory(market, alice);
    }

    function _assertLedgers(Snap memory s) internal {
        assertEq(s.backing, s.shareBacking + s.orderCash, "backing identity");
        assertEq(s.sumYes, s.yesSupply, "YES supply");
        assertEq(s.sumNo, s.noSupply, "NO supply");
        assertEq(s.sumReserved, s.orderCash, "reserved cash");
        assertEq(s.yesSupply, s.noSupply, "complete-set supply");
        assertEq(s.shareBacking, s.yesSupply / UNIT, "share backing");
        assertGe(s.engineBalance, s.backing + s.deferred, "engine under-accounted");
        assertGe(s.vaultBalance, s.vaultLiabilities, "vault under-accounted");
    }

    function _expectCustody(
        uint256 index,
        address from,
        address to,
        uint256 amount,
        uint256 engineGap,
        uint256 vaultGap
    ) internal view {
        Snap memory s = snaps[index];
        assertEq(s.from, from, "transfer sender");
        assertEq(s.to, to, "transfer recipient");
        assertEq(s.amount, amount, "transfer amount");
        assertEq(s.engineBalance - s.backing - s.deferred, engineGap, "engine gap");
        assertEq(s.vaultBalance - s.vaultLiabilities, vaultGap, "vault gap");
        assertFalse(s.extracted, "extraction flag");
        assertTrue(s.guardHeld, "guard flag");
    }

    function _assertFinalCustody() internal view {
        assertEq(
            book.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market) + orderEngine.totalDeferred(),
            "final engine custody"
        );
        assertEq(
            book.balanceOf(address(bookVault)),
            bookVault.totalLiabilitiesOf(address(book)),
            "final vault custody"
        );
        assertEq(orderEngine.totalDeferred(), 0, "nothing deferred");
    }

    function _reenterReverts() internal returns (bool) {
        try orderEngine.placeOrder(
            market, _buy(1, 500, uint128(UNIT * 3), false)
        ) returns (
            IOrderEngine.OrderResult memory
        ) {
            return false;
        } catch (bytes memory data) {
            if (bytes4(data) != REENTRANT) return false;
        }
        try orderEngine.claimDeferred() returns (uint256) {
            return false;
        } catch (bytes memory data) {
            return bytes4(data) == REENTRANT;
        }
    }

    /// @dev A third party that treats balance - backing as surplus cannot pull it.
    function _tryExtract(uint256 gap) internal returns (bool extracted) {
        if (gap == 0) return false;
        uint256 before = book.balanceOf(address(this));
        try book.transferFrom(address(orderEngine), address(this), gap) {
            return book.balanceOf(address(this)) != before;
        } catch {
            return book.balanceOf(address(this)) != before;
        }
    }

    function _assertSweep(address to) internal {
        if (to == address(bookVault)) {
            try bookVault.sweepUnattributedSurplus(address(book)) returns (uint256) {
                revert("sweep saw the in-flight fee");
            } catch (bytes memory data) {
                assertEq(bytes4(data), REENTRANT, "vault guard during deposit");
            }
            return;
        }
        uint256 swept = bookVault.sweepUnattributedSurplus(address(book));
        assertEq(swept, 0, "no vault surplus before the fee arrives");
    }

    function _sumInventory()
        internal
        view
        returns (uint256 yes, uint256 no, uint256 reserved)
    {
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) {
            (uint256 y, uint256 n,,, uint256 cash) =
                orderEngine.getInventory(market, who[i]);
            yes += y;
            no += n;
            reserved += cash;
        }
    }

    function _split(address who) internal {
        book.setProbe(address(this), false);
        vm.prank(who);
        orderEngine.split(market, SET, 1000e6, uint64(block.timestamp + 1 days));
    }

    function _buy(uint8 outcome, uint16 tick, uint128 amount, bool rest)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p.outcome = outcome;
        p.priceTick = tick;
        p.amount = amount;
        p.matchLimit = 16;
        p.validUntil = uint64(block.timestamp + 1 days);
        p.rest = rest;
        p.maxTokenIn = 10_000e6;
    }

    function _sell(uint8 outcome, uint16 tick, uint128 amount, bool rest)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p = _buy(outcome, tick, amount, rest);
        p.action = 1;
        p.maxTokenIn = 0;
    }
}

/// @notice MarketFactory admission does not install a book token and does not reject hooks.
contract L1FactoryAdmissionTest is DualTokenBase, IHookProbe {
    HookToken internal hook;
    uint256 internal probes;

    function test_marketFactoryAdmitsHookTokenAsTokenAOnly() public {
        hook = new HookToken(18);
        hook.setProbe(address(this), true);
        uint256 hooksBefore = hook.hooks();

        // Node admin is this test. Probes do not see this custom hook.
        marketFactory.setTokenAllowed(
            address(hook), true, marketFactory.TOKEN_RISK_ACKNOWLEDGEMENT()
        );
        assertEq(hook.hooks(), hooksBefore, "admission does not transfer");
        assertTrue(marketFactory.allowedTokens(address(hook)), "hook token allowed");
        assertEq(address(orderEngine.baseToken()), address(usdc), "book token unchanged");

        (bool lockedOk,) =
            address(orderEngine).staticcall(abi.encodeWithSignature("accountingLocked()"));
        assertFalse(lockedOk, "OrderEngine exposes no accountingLocked view");
        assertFalse(amm.accountingLocked(), "AMM lock is a different contract");

        hook.mint(creator, 1000e18);
        vm.prank(creator);
        hook.approve(address(marketFactory), type(uint256).max);
        IMarketFactory.MarketParams memory p = _marketParams(
            "hook token admission",
            0,
            uint64(block.timestamp + 20 days),
            address(hook),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (address created,) = marketFactory.createMarket(p);

        assertGt(hook.hooks(), hooksBefore, "Token A funding does transfer");
        assertEq(
            address(orderEngine.baseToken()),
            address(usdc),
            "createMarket keeps the book token"
        );
        assertTrue(
            orderEngine.isMarketRegistered(created), "book registered the new market"
        );
        assertEq(amm.tokenAOf(created), address(hook), "hook token is AMM collateral");

        uint256 hooksAfterCreate = hook.hooks();
        vm.prank(alice);
        orderEngine.split(created, 1e18, 10e6, uint64(block.timestamp + 1 days));
        assertEq(hook.hooks(), hooksAfterCreate, "book split does not touch Token A");
        assertEq(probes, hook.hooks() - hooksBefore, "probe saw only Token A transfers");
    }

    function onTransfer(address, address, uint256) external {
        require(msg.sender == address(hook), "probe caller");
        probes++;
        // Factory funding is not an OrderEngine payout. The book still refuses a
        // base token other than the one pinned in its constructor.
        orderEngine.getCollateralBacking(address(0));
        vm.expectRevert(OrderEngine.NotAuthorized.selector);
        orderEngine.registerMarket(address(0xBEEF), address(hook), 0);
    }
}

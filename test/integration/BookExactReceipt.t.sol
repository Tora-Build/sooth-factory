// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DualTokenBase, IBookFeeVault, East18E} from "../base/DualTokenBase.sol";
import {OrderEngine} from "src/OrderEngine.sol";

/// @dev Test-only token. No admission policy or live token compatibility is implied.
contract ReceiptBookToken is ERC20 {
    enum Mode {
        Exact,
        Short,
        Bonus,
        Drain,
        FalseReturn,
        NoReturn,
        Blocked,
        CallbackMask,
        CallbackExact
    }
    uint8 private immutable _decimals;
    Mode public mode;
    address public affectedFrom;
    address public callbackTarget;
    bytes public callbackData;
    uint256 public affectedTransfers;
    uint256 public selectedTransfer;

    error TransferBlocked();

    constructor(uint8 decimals_) ERC20("Receipt fixture", "RCPT") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(Mode nextMode, address from) external {
        mode = nextMode;
        affectedFrom = from;
        affectedTransfers = 0;
        selectedTransfer = 0;
    }

    function configureNth(Mode nextMode, address from, uint256 ordinal) external {
        mode = nextMode;
        affectedFrom = from;
        affectedTransfers = 0;
        selectedTransfer = ordinal;
    }

    function configureCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        super.transferFrom(from, to, amount);
        if (from != affectedFrom) return true;
        ++affectedTransfers;
        if (selectedTransfer != 0 && selectedTransfer != affectedTransfers) return true;
        Mode active = mode;
        if (active == Mode.Short) _burn(to, 1);
        if (active == Mode.Bonus) _mint(to, 1);
        if (active == Mode.Drain) _burn(to, amount + 1);
        if (active == Mode.FalseReturn) return false;
        if (active == Mode.Blocked) revert TransferBlocked();
        if (active == Mode.NoReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (active == Mode.CallbackMask || active == Mode.CallbackExact) {
            // The outer transfer is one native unit short. A nested exact mint
            // could hide that shortfall while creating a second liability.
            if (active == Mode.CallbackMask) _burn(to, 1);
            _approve(address(this), msg.sender, type(uint256).max);
            // Ignore failure deliberately: the outer exact-receipt check must
            // reject the remaining shortfall after the engine blocks reentry.
            (bool success,) = callbackTarget.call(callbackData);
            if (success) return true;
        }
        return true;
    }
}

abstract contract BookExactReceiptBase is DualTokenBase {
    /// Resting BUYs, crossing BUYs and native complete-set splits pull collateral.
    /// Inventory-backed SELLs deduct the taker fee from proceeds without a pull.
    enum Path {
        RestingDeposit,
        BookTaker,
        Split,
        ClosingTaker
    }
    uint256 constant PULL_PATHS = 3;

    ReceiptBookToken bookToken;
    address secondMarket;
    uint256 nativeUnit;
    uint256 wadPerNative;
    uint256 constant ALICE_KEY = 0xA11CE;
    uint256 constant BOB_KEY = 0xB0B;
    uint128 constant SHARES = 100e18;

    function bookDecimals() internal pure virtual returns (uint8);

    function setUp() public override {
        east = new East18E();
        bookToken = new ReceiptBookToken(bookDecimals());
        nativeUnit = 10 ** bookDecimals();
        wadPerNative = 10 ** (18 - bookDecimals());
        _deployStack(address(bookToken));

        alice = vm.addr(ALICE_KEY);
        bob = vm.addr(BOB_KEY);
        east.mint(creator, 1000e18);
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        _fund(alice);
        _fund(bob);
        _fund(address(bookToken));

        _createMarket();
        secondMarket = market;
        _createMarket();
        // Existing backing and a prior donation must never satisfy a new receipt.
        // A resting NO at 400 posts 0.40 a share: 57.5 shares is 23 units of backing
        // in the other market, with no fill and so no fee in the vault.
        vm.prank(bob);
        orderEngine.placeOrder(secondMarket, BookTestOrders.buy(0, 400, 57.5e18, 256));
        bookToken.mint(address(orderEngine), 7 * nativeUnit);
    }

    function _fund(address user) internal {
        bookToken.mint(user, 1_000_000 * nativeUnit);
        vm.prank(user);
        bookToken.approve(address(orderEngine), 1_000_000 * nativeUnit);
    }

    function test_RestingDeposit_RejectsBadReceipts() public {
        _rejectModes(Path.RestingDeposit);
    }

    function test_BookTaker_RejectsBadReceipts() public {
        _rejectModes(Path.BookTaker);
    }

    function test_Split_RejectsBadReceipts() public {
        _rejectModes(Path.Split);
    }

    /// A closing taker nets the round trip, so every hostile INBOUND mode is inert
    /// on this path: there is no transferFrom for it to corrupt. What must hold is
    /// that alice receives exactly what she is owed, nothing is pulled from her, and
    /// custody is solvent — under every mode the pull paths reject.
    function test_ClosingTaker_PullsNothingSoNoReceiptCanBeShort() public {
        ReceiptBookToken.Mode[5] memory modes = [
            ReceiptBookToken.Mode.Short,
            ReceiptBookToken.Mode.Bonus,
            ReceiptBookToken.Mode.Drain,
            ReceiptBookToken.Mode.FalseReturn,
            ReceiptBookToken.Mode.Blocked
        ];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            _prepare(Path.ClosingTaker);
            bookToken.configure(modes[i], alice);
            uint256 aliceBefore = bookToken.balanceOf(alice);
            uint256 vaultBefore = bookToken.balanceOf(address(bookVault));

            _execute(Path.ClosingTaker, "");

            uint256 fee = bookToken.balanceOf(address(bookVault)) - vaultBefore;
            assertEq(bookToken.affectedTransfers(), 0, "nothing was pulled from her");
            // Sold 100 YES at 0.60 into Bob's complementary SELL NO: she receives
            // 0.60 per share less the fee on min(0.6, 0.4) x 100.
            assertEq(fee, 40 * nativeUnit / 100, "1% of the 40.00 fee basis");
            assertEq(
                bookToken.balanceOf(alice) - aliceBefore,
                60 * nativeUnit - fee,
                "one exact net payout"
            );
            assertEq(orderEngine.getNet(market, alice), 0, "flat");
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function _prepare(Path path) internal {
        bookToken.configure(ReceiptBookToken.Mode.Exact, address(0));
        if (path == Path.BookTaker || path == Path.ClosingTaker) {
            vm.prank(bob);
            orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, SHARES, 256)); // ASK at YES 600
        }
        if (path == Path.ClosingTaker) {
            // Alice owns YES and Bob owns NO. Bob offers his NO at 0.40;
            // Alice's later SELL YES merges the complementary inventories.
            vm.prank(alice);
            orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, SHARES, 256));
            vm.prank(bob);
            orderEngine.placeOrder(market, BookTestOrders.sell(0, 400, SHARES, 256));
        }
    }

    /// Aggregate custody includes resting BUY cash and complete-set backing.
    function _backingAfter(Path path, uint256 before) internal view returns (uint256) {
        if (path == Path.RestingDeposit) return before + 40 * nativeUnit;
        if (path == Path.BookTaker) return before + 60 * nativeUnit;
        if (path == Path.Split) return before + 100 * nativeUnit;
        return before - 100 * nativeUnit;
    }

    function _rejectModes(Path path) internal {
        _prepare(path);
        ReceiptBookToken.Mode[5] memory modes = [
            ReceiptBookToken.Mode.Short,
            ReceiptBookToken.Mode.Bonus,
            ReceiptBookToken.Mode.Drain,
            ReceiptBookToken.Mode.FalseReturn,
            ReceiptBookToken.Mode.Blocked
        ];
        for (uint256 i; i < modes.length; ++i) {
            bookToken.configure(modes[i], alice);
            bytes32 beforeState = _stateDigest();
            bytes memory expected =
                abi.encodeWithSelector(OrderEngine.TransferAmountMismatch.selector);
            if (modes[i] == ReceiptBookToken.Mode.FalseReturn) {
                expected = abi.encodeWithSelector(
                    SafeERC20.SafeERC20FailedOperation.selector, address(bookToken)
                );
            }
            if (modes[i] == ReceiptBookToken.Mode.Blocked) {
                expected =
                    abi.encodeWithSelector(ReceiptBookToken.TransferBlocked.selector);
            }
            _execute(path, expected);
            assertEq(
                _stateDigest(),
                beforeState,
                "all custody, fees, shares and book state roll back"
            );
            _assertSolvent();
        }
    }

    // An empty expected error means success. Arm the expectation immediately
    // before the entry call, after signing/query helpers have finished.
    function _execute(Path path, bytes memory expected) internal {
        if (expected.length != 0) vm.expectRevert(expected);
        vm.prank(alice);
        if (path == Path.RestingDeposit) {
            orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, SHARES, 256));
        } else if (path == Path.BookTaker) {
            orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, SHARES, 256));
        } else if (path == Path.Split) {
            orderEngine.split(
                market, SHARES, 100 * nativeUnit, uint64(block.timestamp + 1 days)
            );
        } else {
            orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, SHARES, 256));
        }
    }

    function test_NoReturnExactReceipt_AllInboundPaths() public {
        for (uint256 i; i < PULL_PATHS; ++i) {
            uint256 snap = vm.snapshotState();
            Path path = Path(i);
            _prepare(path);
            bookToken.configure(ReceiptBookToken.Mode.NoReturn, alice);
            uint256 beforeBacking = orderEngine.getCollateralBacking(market);
            _execute(path, "");
            assertEq(
                orderEngine.getCollateralBacking(market),
                _backingAfter(path, beforeBacking)
            );
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function test_CallbackCannotMaskShortfall_SameMarket() public {
        _callbackMatrix(market);
    }

    function test_CallbackCannotMaskShortfall_OtherMarket() public {
        _callbackMatrix(secondMarket);
    }

    function _callbackMatrix(address targetMarket) internal {
        bytes memory nested = _nestedDeposit(targetMarket);
        bookToken.configureCallback(address(orderEngine), nested);
        for (uint256 i; i < PULL_PATHS; ++i) {
            uint256 snap = vm.snapshotState();
            Path path = Path(i);
            _prepare(path);
            bookToken.configure(ReceiptBookToken.Mode.CallbackMask, alice);
            bytes32 beforeState = _stateDigest();
            vm.expectCall(address(orderEngine), nested);
            _execute(
                path, abi.encodeWithSelector(OrderEngine.TransferAmountMismatch.selector)
            );
            assertEq(
                _stateDigest(), beforeState, "nested collateral cannot be double counted"
            );
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    /// One native unit of complete-set collateral attempted during a transfer.
    function _nestedDeposit(address target) internal view returns (bytes memory) {
        return abi.encodeCall(
            OrderEngine.split, (target, wadPerNative, 1, uint64(block.timestamp + 1 days))
        );
    }

    /// No entry point is reachable from inside a transfer the engine is waiting on.
    function test_CallbackCannotReenterAnyEntryPoint() public {
        _prepare(Path.BookTaker);
        bytes[3] memory calls = [
            _nestedDeposit(market),
            abi.encodeCall(
                OrderEngine.placeOrder,
                (market, BookTestOrders.buy(1, 600, uint128(wadPerNative), 256))
            ),
            abi.encodeCall(OrderEngine.cancelById, (uint64(1)))
        ];
        for (uint256 i; i < calls.length; ++i) {
            bookToken.configureCallback(address(orderEngine), calls[i]);
            bookToken.configure(ReceiptBookToken.Mode.CallbackMask, alice);
            bytes32 beforeState = _stateDigest();
            vm.expectCall(address(orderEngine), calls[i]);
            _execute(
                Path.RestingDeposit,
                abi.encodeWithSelector(OrderEngine.TransferAmountMismatch.selector)
            );
            assertEq(_stateDigest(), beforeState);
            _assertSolvent();
        }
    }

    function test_SwallowedCallback_ExactOuterReceiptCreditsOnlyOuter() public {
        bytes memory nested = _nestedDeposit(secondMarket);
        bookToken.configureCallback(address(orderEngine), nested);
        for (uint256 i; i < PULL_PATHS; ++i) {
            uint256 snap = vm.snapshotState();
            Path path = Path(i);
            _prepare(path);
            bookToken.configure(ReceiptBookToken.Mode.CallbackExact, alice);
            uint256 beforeBacking = orderEngine.getCollateralBacking(market);
            vm.expectCall(address(orderEngine), nested);
            _execute(path, "");
            assertEq(
                orderEngine.getCollateralBacking(market),
                _backingAfter(path, beforeBacking)
            );
            assertEq(orderEngine.getCollateralBacking(secondMarket), 23 * nativeUnit);
            (uint256 yesShares, uint256 noShares) =
                orderEngine.getPosition(secondMarket, address(bookToken));
            assertEq(yesShares + noShares, 0);
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    /// An order that fills and then rests used to make two pulls — the fill's leg and
    /// fee, then the resting deposit — and this test corrupted the second. It now
    /// makes ONE, for everything: corrupting a second transfer does nothing, and
    /// corrupting the first rolls back the fill, the fee and the rest together.
    function test_LateRestingDepositFailureRollsBackEarlierFillAndFees() public {
        _prepare(Path.BookTaker);
        uint256 snap = vm.snapshotState();
        bookToken.configureNth(ReceiptBookToken.Mode.Short, alice, 2);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 150e18, 256));
        assertEq(bookToken.affectedTransfers(), 1, "fill, fee and rest in one pull");
        vm.revertToState(snap);

        bookToken.configureNth(ReceiptBookToken.Mode.Short, alice, 1);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 150e18, 256));
        assertEq(
            _stateDigest(),
            beforeState,
            "earlier fill, fees and queue mutations roll back"
        );
        assertEq(bookToken.affectedTransfers(), 0);

        bookToken.configure(ReceiptBookToken.Mode.Exact, address(0));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 150e18, 256));
        assertEq(orderEngine.fillCount(), 1);
        assertEq(orderEngine.getCollateralBacking(market), 130 * nativeUnit);
        assertEq(bookVault.totalLiabilitiesOf(address(bookToken)), 40 * nativeUnit / 100);
        vm.prank(alice);
        orderEngine.cancel(market, 0, 600); // her resting YES remainder: a BID at 600
        assertEq(orderEngine.getCollateralBacking(market), 100 * nativeUnit);
        _assertSolvent();
    }

    /// A held-YES sell reserves inventory. Failed taker collection must leave the
    /// reservation, ownership and existing backing intact and cancellable.
    function test_ClosingMaker_RemainsCancelableAfterFailedTaker() public {
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, SHARES, 256));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, SHARES, 256)); // bob +100, alice -100
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, SHARES, 256));
        uint256 restingBacking = orderEngine.getCollateralBacking(market);

        // An explicit BUY pulls collateral, regardless of other owned outcomes.
        // A fresh buyer makes the corrupted receipt and rollback especially clear.
        address opener = address(0x0BE7E2);
        _fund(opener);
        bookToken.configure(ReceiptBookToken.Mode.Short, opener);
        bytes32 beforeState = _stateDigest();
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        vm.prank(opener);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, SHARES, 256));
        assertEq(_stateDigest(), beforeState);

        vm.prank(bob);
        orderEngine.cancel(market, 1, 600);
        assertEq(orderEngine.getNet(market, bob), int256(uint256(SHARES)), "still long");
        assertEq(
            orderEngine.getCollateralBacking(market),
            restingBacking,
            "sell cancellation releases inventory without removing backing"
        );
        _assertSolvent();
    }

    function test_ExactReceipt_BookFillFeesAndCancel() public {
        _prepare(Path.BookTaker);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 40e18, 256));
        assertEq(orderEngine.getCollateralBacking(market), 64 * nativeUnit);
        // 1% of min(0.6, 0.4) x 40 = 1% of 16.00 (ADR-0008 amendment).
        assertEq(bookToken.balanceOf(address(bookVault)), 16 * nativeUnit / 100);
        assertEq(bookVault.totalLiabilitiesOf(address(bookToken)), 16 * nativeUnit / 100);
        assertEq(vault.totalLiabilitiesOf(address(bookToken)), 0);
        vm.prank(bob);
        orderEngine.cancel(market, 1, 600); // his NO at 400: an ASK at YES 600
        assertEq(orderEngine.getCollateralBacking(market), 40 * nativeUnit);
        _assertSolvent();
    }

    function test_ExactReceipt_FinalYes() public {
        _settlement(1);
    }

    function test_ExactReceipt_FinalNo() public {
        _settlement(0);
    }

    function test_ExactReceipt_FinalInvalid() public {
        _settlement(2);
    }

    function _settlement(uint8 outcome) internal {
        // Was set up through the signed-order path. Same crossing pair on the on-chain
        // book: bob rests NO at 400, alice takes YES at 600, and 400 + 600 = 1000.
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, SHARES, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, SHARES, 100));
        _resolveAndSettle(outcome);
        uint256 expectedAlice =
            outcome == 1 ? 100 * nativeUnit : outcome == 2 ? 50 * nativeUnit : 0;
        uint256 expectedBob = 100 * nativeUnit - expectedAlice;
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), expectedAlice);
        _assertSolvent();
        vm.prank(bob);
        assertEq(orderEngine.settlePosition(market), expectedBob);
        assertEq(orderEngine.getCollateralBacking(market), 0);
        _assertSolvent();
    }

    function _stateDigest() internal view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                bookToken.balanceOf(address(orderEngine)),
                bookToken.balanceOf(address(bookVault)),
                bookToken.totalSupply(),
                orderEngine.fillCount(),
                bookVault.totalLiabilitiesOf(address(bookToken)),
                east.balanceOf(address(amm)),
                east.balanceOf(address(vault)),
                lp.totalSupply()
            )
        );
        address[3] memory users = [alice, bob, address(bookToken)];
        address[2] memory markets = [market, secondMarket];
        for (uint256 i; i < users.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    bookToken.balanceOf(users[i]),
                    bookToken.allowance(users[i], address(orderEngine))
                )
            );
            for (uint256 j; j < markets.length; ++j) {
                digest =
                    keccak256(abi.encode(digest, _inventoryDigest(markets[j], users[i])));
            }
        }
        for (uint256 j; j < markets.length; ++j) {
            address target = markets[j];
            digest = keccak256(
                abi.encode(
                    digest,
                    orderEngine.getCollateralBacking(target),
                    bookVault.marketLiabilitiesOf(target, address(bookToken)),
                    bookVault.refundableResolutionOf(target, alice)
                )
            );
            for (uint256 b; b < 2; ++b) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        bookVault.accountOf(
                            target, IBookFeeVault.Bucket(b), address(bookToken)
                        )
                    )
                );
            }
        }
        // The two ticks every path rests at: asks (NO buys at 400) and bids (YES
        // buys at 600), both at YES tick 600 on the single axis.
        (uint256 amount, uint256 count) = orderEngine.getOrdersAtTick(market, 1, 600);
        (uint256 yesAmount, uint256 yesCount) =
            orderEngine.getOrdersAtTick(market, 0, 600);
        digest = keccak256(
            abi.encode(
                digest,
                amount,
                count,
                yesAmount,
                yesCount,
                orderEngine.getBestTick(market, 0),
                orderEngine.getBestTick(market, 1),
                _supplyDigest(market),
                _supplyDigest(secondMarket)
            )
        );
    }

    function _inventoryDigest(address target, address user)
        private
        view
        returns (bytes32)
    {
        (uint256 yes, uint256 no, uint256 reservedYes, uint256 reservedNo, uint256 cash) =
            orderEngine.getInventory(target, user);
        return keccak256(
            abi.encode(
                yes, no, reservedYes, reservedNo, cash, orderEngine.deferredOf(user)
            )
        );
    }

    function _supplyDigest(address target) private view returns (bytes32) {
        (uint256 yes, uint256 no) = orderEngine.getSupplies(target);
        return keccak256(abi.encode(yes, no));
    }

    function _assertSolvent() internal view {
        assertGe(
            bookToken.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(market)
                + orderEngine.getCollateralBacking(secondMarket)
                + orderEngine.totalDeferred()
        );
        assertGe(
            bookToken.balanceOf(address(bookVault)),
            bookVault.totalLiabilitiesOf(address(bookToken))
        );
        assertGe(east.balanceOf(address(amm)), amm.totalLiabilitiesOf(address(east)));
        assertGe(east.balanceOf(address(vault)), vault.totalLiabilitiesOf(address(east)));
    }
}

contract BookExactReceipt6DecTest is BookExactReceiptBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract BookExactReceipt18DecTest is BookExactReceiptBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 18;
    }
}

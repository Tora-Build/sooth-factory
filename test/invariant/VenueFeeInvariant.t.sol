// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AmmFeeVault} from "src/AmmFeeVault.sol";
import {BookFeeVault} from "src/BookFeeVault.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {NodeRoles} from "src/policy/NodeRoles.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {FeeTestToken, FeeTestMarket, FeeTestEngine} from "../unit/VenueFeeVaults.t.sol";

/// @dev Three markets share one token, but have two physically separate vaults.
/// Ghost funding/payout totals independently reconcile with each venue's ledgers.
contract VenueFeeHandler is Test {
    FeeTestToken public token;
    AmmFeeVault public amm;
    BookFeeVault public book;
    FeeTestEngine public ammEngine;
    FeeTestEngine public bookEngine;
    LPPositionManager public manager;
    FeeTestMarket[3] public markets;
    uint256[3] public positions;
    uint256[3][2] public received;
    uint256[3][2] public paid;
    uint256[2] public donated;
    uint256[2] public swept;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    constructor(uint8 decimals) {
        token = new FeeTestToken(decimals);
        NodeRoles roles = new NodeRoles(address(this), address(this), address(0));
        ammEngine = new FeeTestEngine();
        bookEngine = new FeeTestEngine();
        amm = new AmmFeeVault(
            IAmmFeeVault.Init(
                address(ammEngine),
                address(this),
                address(roles),
                address(0xA001),
                IAmmFeeVault.AmmConfig(100, 5000, 3000, 1000, 1000, address(0xA002))
            )
        );
        book = new BookFeeVault(
            IBookFeeVault.Init(
                address(bookEngine),
                address(this),
                address(roles),
                address(token),
                address(0xB001),
                500,
                IBookFeeVault.BookConfig(100, 1000, 9000, address(0xB002))
            )
        );
        ammEngine.connect(amm);
        manager = ammEngine.manager();
        for (uint256 i; i < 3; ++i) {
            FeeTestMarket market = new FeeTestMarket(address(this));
            markets[i] = market;
            amm.registerMarket(
                address(market), address(token), decimals, 1, address(0xCAFE)
            );
            book.registerMarket(
                address(market), address(token), decimals, 1, address(0xCAFE)
            );
            positions[i] = ammEngine.seed(address(market), ALICE);
        }
    }

    function deposit(uint8 venueSeed, uint8 marketSeed, uint128 amountSeed, bool payerBob)
        external
    {
        uint256 v = venueSeed % 2;
        uint256 i = marketSeed % 3;
        if (markets[i].isSettled()) return;
        uint256 amount = bound(uint256(amountSeed), 0, 1e24);
        FeeTestEngine source = v == 0 ? ammEngine : bookEngine;
        address vault = v == 0 ? address(amm) : address(book);
        token.mint(address(source), amount);
        source.deposit(vault, address(markets[i]), token, amount, payerBob ? BOB : ALICE);
        received[v][i] += amount;
    }

    function donate(uint8 venueSeed, uint128 amountSeed) external {
        uint256 v = venueSeed % 2;
        uint256 amount = bound(uint256(amountSeed), 0, 1e24);
        token.mint(v == 0 ? address(amm) : address(book), amount);
        donated[v] += amount;
    }

    function sweep(bool bookVenue) external {
        if (bookVenue) swept[1] += book.sweepUnattributedSurplus(address(token));
        else swept[0] += amm.sweepUnattributedSurplus(address(token));
    }

    function stream(uint8 marketSeed, bool bookVenue) external {
        uint256 i = marketSeed % 3;
        if (bookVenue) paid[1][i] += book.claimProtocolFees(address(markets[i]));
        else paid[0][i] += amm.claimOperatorFees(address(markets[i]));
    }

    function transferLP(uint8 marketSeed, uint96 amountSeed, bool fromBob) external {
        uint256 i = marketSeed % 3;
        if (markets[i].isSettled()) return;
        address from = fromBob ? BOB : ALICE;
        uint256 balance = manager.balanceOf(from, positions[i]);
        uint256 amount = bound(uint256(amountSeed), 0, balance);
        vm.prank(from);
        manager.transfer(fromBob ? ALICE : BOB, positions[i], amount);
    }

    function settle(uint8 marketSeed, uint8 outcomeSeed, bool timeout, bool bookFirst)
        external
    {
        uint256 i = marketSeed % 3;
        if (markets[i].isSettled()) return;
        if (timeout) {
            vm.warp(uint256(markets[i].deadline()) + markets[i].invalidationBuffer());
            if (bookFirst) book.finalize(address(markets[i]));
            else amm.finalize(address(markets[i]));
        } else {
            markets[i].settle(outcomeSeed % 3);
        }
    }

    function claimLP(uint8 marketSeed, bool holderBob) external {
        uint256 i = marketSeed % 3;
        if (!markets[i].isSettled()) return;
        vm.prank(holderBob ? BOB : ALICE);
        paid[0][i] += amm.claimLPDividendForPosition(address(markets[i]), positions[i]);
    }

    function claimResolution(uint8 marketSeed, bool bookVenue, bool payerBob) external {
        uint256 i = marketSeed % 3;
        if (!markets[i].isSettled()) return;
        bool timeout =
            markets[i].settlementKind() == ITruthMarket.SettlementKind.INVALIDATED;
        if (bookVenue) {
            paid[
                1
            ][
                i
            ] += timeout
                ? book.claimTimeoutRefund(address(markets[i]), payerBob ? BOB : ALICE)
                : book.claimResolutionFees(address(markets[i]));
        } else if (!timeout) {
            paid[0][i] += amm.claimResolutionFees(address(markets[i]));
        }
    }
}

abstract contract VenueFeeInvariantBase is StdInvariant, Test {
    VenueFeeHandler internal handler;

    function _setup(uint8 decimals) internal {
        handler = new VenueFeeHandler(decimals);
        targetContract(address(handler));
    }

    function invariant_AllMarketBucketsAndGhostReceiptsReconcile() public view {
        AmmFeeVault amm = handler.amm();
        BookFeeVault book = handler.book();
        address token = address(handler.token());
        uint256 ammSum;
        uint256 bookSum;
        for (uint256 i; i < 3; ++i) {
            (uint256 a, uint256 b) = _checkMarket(i);
            ammSum += a;
            bookSum += b;
        }
        assertEq(amm.totalLiabilitiesOf(token), ammSum);
        assertEq(book.totalLiabilitiesOf(token), bookSum);
        assertGe(handler.token().balanceOf(address(amm)), ammSum);
        assertGe(handler.token().balanceOf(address(book)), bookSum);
        assertEq(
            handler.token().balanceOf(address(amm)),
            ammSum + handler.donated(0) - handler.swept(0)
        );
        assertEq(
            handler.token().balanceOf(address(book)),
            bookSum + handler.donated(1) - handler.swept(1)
        );
    }

    function _checkMarket(uint256 i) private view returns (uint256 a, uint256 b) {
        AmmFeeVault amm = handler.amm();
        BookFeeVault book = handler.book();
        address token = address(handler.token());
        address market = address(handler.markets(i));
        a = amm.marketLiabilitiesOf(market, token);
        b = book.marketLiabilitiesOf(market, token);
        assertEq(
            a,
            amm.accountOf(market, IAmmFeeVault.Bucket.LP, token)
                + amm.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, token)
                + amm.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, token)
        );
        assertEq(
            b,
            book.accountOf(market, IBookFeeVault.Bucket.RESOLUTION, token)
                + book.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, token)
        );
        assertEq(a, handler.received(0, i) - handler.paid(0, i));
        assertEq(b, handler.received(1, i) - handler.paid(1, i));
    }
}

contract VenueFeeInvariant6 is VenueFeeInvariantBase {
    function setUp() public {
        _setup(6);
    }
}

contract VenueFeeInvariant18 is VenueFeeInvariantBase {
    function setUp() public {
        _setup(18);
    }
}

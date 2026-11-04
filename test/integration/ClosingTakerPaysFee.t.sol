// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";

contract BookToken is ERC20 {
    uint8 private immutable precision;

    constructor(uint8 decimals_) ERC20("Book token", "BOOK") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Every taker BUY and SELL pays the same complementary fee basis.
abstract contract ClosingTakerPaysFee is DualTokenBase {
    BookToken internal book;

    function bookDecimals() internal pure virtual returns (uint8);

    function setUp() public virtual override {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        book = new BookToken(bookDecimals());
        _deployStack(address(book));
        _fundAndApprove();

        uint256 unit = 10 ** bookDecimals();
        address[3] memory holders = [alice, bob, trader];
        for (uint256 i; i < holders.length; ++i) {
            book.mint(holders[i], 1_000_000 * unit);
            vm.prank(holders[i]);
            book.approve(address(orderEngine), type(uint256).max);
        }
        _createMarket();
    }

    function _unit() internal pure returns (uint256) {
        return 10 ** bookDecimals();
    }

    /// Alice takes 10 YES from bob at 0.60 and is left long.
    function _aliceOpensLong() internal {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        assertEq(orderEngine.getNet(market, alice), 10e18);
    }

    /// An opening taker pays 1% of its leg; the resting maker pays nothing.
    function test_openingTakerPaysTheFee() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        assertEq(book.balanceOf(address(bookVault)), 0, "resting is free");

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));

        // 1% of min(0.6, 0.4) x 10 = 1% of 4.00. The taker still pays its own 0.60
        // leg as principal; only the FEE is complement-invariant.
        assertEq(book.balanceOf(address(bookVault)), 4 * _unit() / 100);
    }

    /// An inventory-selling taker pays the complementary taker fee.
    function test_closingTakerPaysTheFee() public {
        _aliceOpensLong();

        // Trader bids 0.60 for YES; Alice sells her existing YES inventory.
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        uint256 vaultBefore = book.balanceOf(address(bookVault));
        uint256 aliceBefore = book.balanceOf(alice);

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 10e18, 256));

        uint256 fee = book.balanceOf(address(bookVault)) - vaultBefore;
        assertEq(fee, 4 * _unit() / 100, "1% of min(0.6, 0.4) x 10");
        // The buyer funds 6.00 of sale proceeds; the seller receives those less fee.
        assertEq(book.balanceOf(alice) - aliceBefore, 6 * _unit() - fee);
        assertEq(orderEngine.getNet(market, alice), 0, "flat");
    }

    /// A closing MAKER still pays nothing: the fee is a taker fee, not a buy fee.
    function test_closingMakerPaysNoFee() public {
        _aliceOpensLong();

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 10e18, 256)); // rests: ASK at YES 600
        uint256 vaultBefore = book.balanceOf(address(bookVault));
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));

        uint256 fee = book.balanceOf(address(bookVault)) - vaultBefore;
        assertEq(fee, 4 * _unit() / 100, "the taker alone pays, on the min basis");
        assertEq(orderEngine.getNet(market, alice), 0);
    }

    /// The edge the min basis exists for. Selling a long at YES 0.005 returns 0.005
    /// a share and is charged 1% of 0.005 — never 1% of the 0.995 leg paid in. On the
    /// leg basis this test asserted the opposite: that closing there cost money.
    function test_feeNeverExceedsWhatClosingReturns() public {
        _aliceOpensLong();

        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 5, 10e18, 256)); // a 0.005 bid for YES
        uint256 vaultBefore = book.balanceOf(address(bookVault));
        uint256 aliceBefore = book.balanceOf(alice);

        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 5, 10e18, 256)); // sell 10 YES at 0.005

        uint256 fee = book.balanceOf(address(bookVault)) - vaultBefore;
        uint256 proceeds = 5 * _unit() / 100; // 10 x 0.005
        assertEq(fee, proceeds / 100, "1% of min(0.005, 0.995) x 10");
        assertLt(fee, proceeds, "the fee cannot exceed what the sale returns");
        assertEq(book.balanceOf(alice) - aliceBefore, proceeds - fee, "she nets the rest");
        assertEq(orderEngine.getNet(market, alice), 0);
    }

    /// Complement invariance, the other reason for the basis: taking the bid side and
    /// taking the ask side at the SAME price owe the same fee, so a taker cannot pick
    /// a side to be taxed less. On the leg basis these differed, 0.60 against 0.40.
    function test_bothSidesOfAFillOweTheSameFee() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        uint256 v0 = book.balanceOf(address(bookVault));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256)); // takes the ask: pays the 0.60 leg
        uint256 bidTakerFee = book.balanceOf(address(bookVault)) - v0;

        _createMarket(); // a fresh market, so the second fill stands alone
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        uint256 v1 = book.balanceOf(address(bookVault));
        vm.prank(trader);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256)); // takes the bid: pays the 0.40 leg
        uint256 askTakerFee = book.balanceOf(address(bookVault)) - v1;

        assertEq(bidTakerFee, askTakerFee, "the side taken cannot change the fee");
        assertEq(bidTakerFee, 4 * _unit() / 100);
    }
}

contract ClosingTakerPaysFeeBook6 is ClosingTakerPaysFee {
    function bookDecimals() internal pure override returns (uint8) {
        return 6;
    }
}

contract ClosingTakerPaysFeeBook18 is ClosingTakerPaysFee {
    function bookDecimals() internal pure override returns (uint8) {
        return 18;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {Test} from "forge-std/Test.sol";
import {OrderEngine} from "../../src/OrderEngine.sol";
import {IOrderEngine} from "../../src/interfaces/IOrderEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract MarketStub {
    address public immutable marketFactory;
    uint64 public deadline = uint64(block.timestamp + 30 days);

    constructor(address marketFactory_) {
        marketFactory = marketFactory_;
    }

    function isTradingOpen() external pure returns (bool) {
        return true;
    }

    function isSettled() external pure returns (bool) {
        return false;
    }
}

contract VaultStub {
    function feeBpsOf(address) external pure returns (uint16) {
        return 0;
    }

    function depositRevenue(address, uint256 e, address) external pure returns (uint256) {
        return e;
    }
}

contract OrderEngineQuotesTest is Test {
    OrderEngine engine;
    MockUSDC token;
    address market;
    address marketFactory = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint8 constant SIDE_BID = 0;
    uint8 constant SIDE_ASK = 1;

    function setUp() public {
        token = new MockUSDC("USD Coin", "USDC");
        VaultStub vault = new VaultStub();
        engine = new OrderEngine(address(token), marketFactory, address(vault));
        market = address(new MarketStub(marketFactory));
        vm.prank(marketFactory);
        engine.registerMarket(market, address(token), 0.5e18);
        for (uint256 i = 0; i < 2; i++) {
            address a = i == 0 ? alice : bob;
            token.mint(a, 1_000_000e6);
            vm.prank(a);
            token.approve(address(engine), type(uint256).max);
        }
    }

    /// Asks (NO buys) resting at YES ticks 700, 400, 500. Best ask is 400.
    function test_bestAskIsLowest() public {
        // buyNo(tick=p) rests an ASK at YES tick 1000-p.
        vm.prank(alice); // ASK @ yes 700
        engine.placeOrder(market, BookTestOrders.buy(0, 300, 10e18, 256));
        vm.prank(alice); // ASK @ yes 400
        engine.placeOrder(market, BookTestOrders.buy(0, 600, 10e18, 256));
        vm.prank(alice); // ASK @ yes 500
        engine.placeOrder(market, BookTestOrders.buy(0, 500, 10e18, 256));

        assertEq(engine.getBestTick(market, SIDE_ASK), 400, "best ask must be the lowest");
        (uint256 yesPrice,) = engine.getImpliedPrice(market);
        assertEq(yesPrice, 0.4e18, "yes price is the cheapest ask");
    }

    function test_bestBidIsHighest() public {
        vm.prank(alice);
        engine.placeOrder(market, BookTestOrders.buy(1, 100, 10e18, 256));
        vm.prank(alice);
        engine.placeOrder(market, BookTestOrders.buy(1, 200, 10e18, 256));
        vm.prank(alice);
        engine.placeOrder(market, BookTestOrders.buy(1, 150, 10e18, 256));

        assertEq(
            engine.getBestTick(market, SIDE_BID), 200, "best bid must be the highest"
        );
        (, uint256 noPrice) = engine.getImpliedPrice(market);
        assertEq(noPrice, 0.8e18, "no price is 1 - best bid");
    }

    /// The quoted ask must be what a taker actually pays.
    function test_quotedAskMatchesWhatTakerPays() public {
        vm.prank(alice); // ASK @ yes 700
        engine.placeOrder(market, BookTestOrders.buy(0, 300, 10e18, 256));
        vm.prank(alice); // ASK @ yes 400
        engine.placeOrder(market, BookTestOrders.buy(0, 600, 10e18, 256));

        uint16 quoted = engine.getBestTick(market, SIDE_ASK);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob); // one tick only
        engine.placeOrder(market, BookTestOrders.buy(1, 999, 1e18, 1));
        uint256 paid = before - token.balanceOf(bob);
        assertEq(paid, (uint256(quoted) * 1e6) / 1000, "taker pays the quoted tick");
    }

    function test_emptySidesQuoteZero() public view {
        assertEq(engine.getBestTick(market, SIDE_ASK), 1000);
        assertEq(engine.getBestTick(market, SIDE_BID), 1000);
        (uint256 y, uint256 n) = engine.getImpliedPrice(market);
        assertEq(y, 0);
        assertEq(n, 0);
    }

    /// Cancel the only order at the best ask; the quote must fall back, not stick.
    function test_bestAskSkipsEmptiedTick() public {
        vm.prank(alice); // ASK @ yes 400
        engine.placeOrder(market, BookTestOrders.buy(0, 600, 10e18, 256));
        vm.prank(alice); // ASK @ yes 700
        engine.placeOrder(market, BookTestOrders.buy(0, 300, 10e18, 256));
        vm.prank(alice);
        engine.cancel(market, SIDE_ASK, 400);
        assertEq(
            engine.getBestTick(market, SIDE_ASK), 700, "must walk past the emptied tick"
        );
    }

    /// Gross supplies and their complete-set backing are directly readable.
    function test_grossSuppliesReadable() public {
        vm.prank(alice); // ASK @ yes 600
        engine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(bob); // crosses, fills
        engine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 256));
        assertEq(engine.getNet(market, bob), 10e18);
        (uint256 yesSupply, uint256 noSupply) = engine.getSupplies(market);
        assertEq(yesSupply, 10e18);
        assertEq(noSupply, yesSupply);
        assertGe(engine.getCollateralBacking(market) * 1e12, yesSupply);
    }

    /// The fill event carries the YES price and authoritative order remainder.
    function test_fillEventCarriesPriceAndExactRemainingReservation() public {
        vm.prank(alice); // ASK @ yes 700
        engine.placeOrder(market, BookTestOrders.buy(0, 300, 10e18, 256));
        vm.expectEmit(true, true, true, true);
        emit IOrderEngine.OrderFilled(market, 1, bob, 1e18, 700, 2, 9e18, 27e5);
        vm.prank(bob);
        engine.placeOrder(market, BookTestOrders.buy(1, 700, 1e18, 256));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

contract NetPositionViewTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    function test_splitOwnsBothOutcomesWithZeroDerivedNet() public {
        vm.prank(alice);
        orderEngine.split(market, 10e18, 10e6, uint64(block.timestamp + 1));
        (uint256 yes, uint256 no) = orderEngine.getPosition(market, alice);
        assertEq(yes, 10e18);
        assertEq(no, 10e18);
        assertEq(orderEngine.getNet(market, alice), 0);
    }

    function test_reservationsDoNotChangeGrossOwnershipOrNet() public {
        vm.prank(alice);
        orderEngine.split(market, 10e18, 10e6, uint64(block.timestamp + 1));
        vm.prank(alice);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 10e18, 64));
        (uint256 y, uint256 n, uint256 yr,,) = orderEngine.getInventory(market, alice);
        assertEq(y, 10e18);
        assertEq(n, 10e18);
        assertEq(yr, 10e18);
        assertEq(orderEngine.getNet(market, alice), 0);
        vm.prank(alice);
        orderEngine.cancelById(r.orderId);
        assertEq(orderEngine.getNet(market, alice), 0);
    }

    function test_buyingOppositeOutcomeBuildsGrossInventoryWithoutAutoMerge() public {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 10e18, 64));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 64));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 4e18, 64));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 4e18, 64));
        (uint256 y, uint256 n) = orderEngine.getPosition(market, alice);
        assertEq(y, 10e18);
        assertEq(n, 4e18);
        assertEq(orderEngine.getNet(market, alice), 6e18);
        assertEq(orderEngine.getShareBacking(market), 14e6);
        vm.prank(alice);
        orderEngine.merge(market, 4e18, 4e6, uint64(block.timestamp + 1));
        (y, n) = orderEngine.getPosition(market, alice);
        assertEq(y, 6e18);
        assertEq(n, 0);
        assertEq(orderEngine.getNet(market, alice), 6e18);
    }

    function testFuzz_grossSupplyAndDerivedNetConserve(uint64 raw, uint16 tickRaw)
        public
    {
        uint128 q = uint128(bound(raw, 1000, 50_000_000)) * 1e12;
        uint16 tick = uint16(bound(tickRaw, 1, 999));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 1000 - tick, q, 64));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, tick, q, 64));
        assertEq(orderEngine.getNet(market, alice) + orderEngine.getNet(market, bob), 0);
        (uint256 y, uint256 n) = orderEngine.getSupplies(market);
        assertEq(y, n);
        assertEq(y, q);
        assertEq(orderEngine.getShareBacking(market), q / 1e12);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// Diagnostics for the current gross ledger; the old engine has different custody.
contract BookGasComparisonTest is DualTokenBase {
    function test_currentInventoryOrderGas() public {
        _createMarket();
        vm.prank(alice);
        orderEngine.split(market, 100e18, 100e6, uint64(block.timestamp + 1));
        uint256 start = gasleft();
        vm.prank(alice);
        IOrderEngine.OrderResult memory r =
            orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 100e18, 64));
        emit log_named_uint("rest inventory sell gas", start - gasleft());
        start = gasleft();
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 40e18, 64));
        emit log_named_uint("partial inventory transfer gas", start - gasleft());
        start = gasleft();
        vm.prank(alice);
        orderEngine.cancelById(r.orderId);
        emit log_named_uint("cancel inventory sell gas", start - gasleft());
        assertEq(orderEngine.getOrder(r.orderId).amount, 0);
    }
}

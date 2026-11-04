// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {
    DualTokenBase,
    East18E,
    IAmmFeeVault,
    IBookFeeVault
} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MarketFactory} from "src/MarketFactory.sol";

/**
 * @title Same-token venue separation
 * @notice Equal collateral addresses retain independent custody and recipients.
 */
contract SameTokenNodeTest is DualTokenBase {
    function setUp() public override {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC"); // unused on this node
        _deployStack(address(east));

        _fundAndApprove();
        // book actors trade EAST on this node
        east.mint(alice, 1_000_000e18);
        east.mint(bob, 1_000_000e18);
        vm.startPrank(alice);
        east.approve(address(orderEngine), type(uint256).max);
        east.approve(address(orderEngine), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        east.approve(address(orderEngine), type(uint256).max);
        east.approve(address(orderEngine), type(uint256).max);
        vm.stopPrank();
    }

    function test_SameTokenTradesAndKeepsVenueFeesSeparate() public {
        _createMarket();
        _seedAmmPosition();
        uint256 ammLiability = vault.totalLiabilitiesOf(address(east));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 100e18, 256));
        assertEq(vault.totalLiabilitiesOf(address(east)), ammLiability);
        assertEq(bookVault.totalLiabilitiesOf(address(east)), 0.4e18);
        assertGt(vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(east)), 0);
        assertEq(
            bookVault.accountOf(market, IBookFeeVault.Bucket.PROTOCOL, address(east)),
            0.36e18
        );
        assertEq(east.balanceOf(address(vault)), ammLiability);
        assertEq(east.balanceOf(address(bookVault)), 0.4e18);
        _resolveAndSettle(1);
        uint256 received = east.balanceOf(treasury);
        vault.claimOperatorFees(market);
        bookVault.claimProtocolFees(market);
        assertGt(east.balanceOf(treasury), received);
        assertEq(vault.claimOperatorFees(market), 0);
        assertEq(bookVault.claimProtocolFees(market), 0);
    }
}

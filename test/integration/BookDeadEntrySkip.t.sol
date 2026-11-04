// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

/// @notice Regressions for spent entries that used to sit behind a live head.
/// @dev Cancel and full fill unlink those entries, so matching does not walk
/// them and a run longer than `MAX_DEAD_SKIPS` cannot hide later liquidity.
/// The public head scan still stops at a live order.
contract BookDeadEntrySkipTest is DualTokenBase {
    uint16 constant TICK = 500;
    uint8 constant ASK = 1;
    address carol = address(0xCA201); // taker
    uint128 dust;

    function setUp() public virtual override {
        super.setUp();
        _createMarket();
        _prepare();
    }

    function _prepare() internal {
        dust = orderEngine.getMinRestingOrder(TICK);
        uint256 max = 2000e18 / orderEngine.shareUnit();
        usdc.mint(carol, max);
        vm.prank(carol);
        usdc.approve(address(orderEngine), type(uint256).max);
        vm.prank(bob);
        orderEngine.split(market, 2000e18, max, uint64(block.timestamp));
        vm.prank(alice);
        orderEngine.split(market, 2000e18, max, uint64(block.timestamp));
    }

    /// bob: a minimum-size live SELL YES at the head, then `pads` cancelled orders.
    /// alice: 1000 honest shares behind them.
    function _padBehindLiveHead(uint256 pads) internal {
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, dust, 8));
        for (uint256 i; i < pads; ++i) {
            vm.prank(bob);
            IOrderEngine.OrderResult memory pad =
                orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, dust, 8));
            vm.prank(bob);
            orderEngine.cancelById(pad.orderId);
        }
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, TICK, 1000e18, 8));
    }

    function _take(uint128 amount, uint32 matchLimit)
        internal
        returns (IOrderEngine.OrderResult memory r)
    {
        vm.prank(carol);
        r = orderEngine.placeOrder(
            market, BookTestOrders.buy(1, TICK, amount, matchLimit)
        );
    }

    function test_SpentEntriesBehindLiveHeadDoNotUseTheMatchBudget() public {
        _padBehindLiveHead(300);
        // Two live entries are read: the dust head and the honest order.
        IOrderEngine.OrderResult memory r = _take(dust + 1000e18, 2);
        assertEq(r.filled, dust + 1000e18);
        assertEq(r.orderId, 0);
        (uint256 total, uint256 count) = orderEngine.getOrdersAtTick(market, ASK, TICK);
        assertEq(total + count, 0, "tick reads empty");
        _assertSystemSolvent();
    }

    function test_BudgetStillCountsEveryLiveEntry() public {
        _padBehindLiveHead(300);
        // One live entry of budget fills the head only and cannot rest across
        // the honest order it did not read.
        IOrderEngine.OrderResult memory r = _take(dust + 1000e18, 1);
        assertEq(r.filled, dust);
        assertEq(r.orderId, 0);
        (uint256 total, uint256 count) = orderEngine.getOrdersAtTick(market, ASK, TICK);
        assertEq(total, 1000e18);
        assertEq(count, 1);
    }

    function test_SpentRunLongerThanTheSkipBoundStillReachesLiveLiquidity() public {
        assertEq(orderEngine.MAX_DEAD_SKIPS(), 512);
        _padBehindLiveHead(orderEngine.MAX_DEAD_SKIPS() + 1);
        IOrderEngine.OrderResult memory r = _take(dust + 1000e18, 256);
        assertEq(r.filled, dust + 1000e18, "cancelled entries are not on the match walk");
        assertEq(r.orderId, 0, "the crossing size fills completely");
        (uint256 total, uint256 count) = orderEngine.getOrdersAtTick(market, ASK, TICK);
        assertEq(total + count, 0, "both live orders filled");
        _assertSystemSolvent();
    }

    function test_ExactlyTheSkipBoundStillReachesLiveLiquidity() public {
        _padBehindLiveHead(orderEngine.MAX_DEAD_SKIPS());
        IOrderEngine.OrderResult memory r = _take(dust + 1000e18, 2);
        assertEq(r.filled, dust + 1000e18);
    }
}

contract DeadEntryBook18 is MockUSDC {
    constructor() MockUSDC("Dead entry fixture", "DE18") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// @notice Same regressions with an 18-decimal book token (share unit 1).
contract BookDeadEntrySkip18Test is BookDeadEntrySkipTest {
    function setUp() public override {
        east = new East18E();
        usdc = new DeadEntryBook18();
        _deployStack(address(usdc));
        _fundAndApprove();
        usdc.mint(alice, 1e30);
        usdc.mint(bob, 1e30);
        _createMarket();
        _prepare();
        assertEq(orderEngine.shareUnit(), 1);
    }
}

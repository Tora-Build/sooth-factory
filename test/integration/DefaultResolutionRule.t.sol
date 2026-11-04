// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AdjudicatorBase} from "src/adjudicators/AdjudicatorBase.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {ClaimAvailableTest} from "./ClaimAvailable.t.sol";
import {SeparateLPPositionsTest} from "./SeparateLPPositions.t.sol";
import {SameTokenNodeTest} from "./SameTokenNode.t.sol";
import {CloseOrdersTest} from "./CloseOrders.t.sol";
import {AmmExactTransfersTest} from "./AmmExactTransfers.t.sol";
import {BookExactTransfersTest} from "./BookExactTransfers.t.sol";
import {ClientReceiptReplayTest} from "./ClientReceiptReplay.t.sol";
import {PauseScopeTest} from "./PauseScope.t.sol";

/// @notice The shipped profile default: a proposal opens at the market deadline.
/// @dev Most suites allow early resolution so their timing stays simple. The
/// suites below run again under the default, with every helper resolution moved
/// to the deadline.
contract DefaultResolutionRuleTest is DualTokenBase {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }

    function test_BothVenuesTradeUntilTheDeadlineThenResolveAndPay() public {
        _createMarket();
        assertFalse(adjudicator.earlyResolution());
        _seedAmmPosition();
        uint256 native = 10e18 / orderEngine.shareUnit();
        vm.prank(bob);
        orderEngine.split(market, 10e18, native, uint64(block.timestamp));
        vm.prank(bob);
        orderEngine.placeOrder(market, BookTestOrders.sell(1, 600, 10e18, 8));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 600, 10e18, 8));

        uint64 deadline = ITruthMarket(market).deadline();
        vm.warp(deadline - 1);
        vm.prank(resolver);
        vm.expectRevert(AdjudicatorBase.ResolutionTooEarly.selector);
        adjudicator.resolve(market, 1, keccak256("data"));
        assertTrue(ITruthMarket(market).isTradingOpen());
        assertTrue(ITruthMarket(market).isLiquidityOpen());

        _resolveAndSettle(1);
        assertEq(block.timestamp, uint256(deadline) + 1 hours + 1);
        assertTrue(ITruthMarket(market).isSettled());
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        assertEq(usdc.balanceOf(alice) - before, native);
        _assertSystemSolvent();
    }
}

contract ClaimAvailableDefaultRuleTest is ClaimAvailableTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract SeparateLPPositionsDefaultRuleTest is SeparateLPPositionsTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract SameTokenNodeDefaultRuleTest is SameTokenNodeTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract CloseOrdersDefaultRuleTest is CloseOrdersTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract AmmExactTransfersDefaultRuleTest is AmmExactTransfersTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract BookExactTransfersDefaultRuleTest is BookExactTransfersTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract ClientReceiptReplayDefaultRuleTest is ClientReceiptReplayTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

contract PauseScopeDefaultRuleTest is PauseScopeTest {
    function _earlyResolution() internal pure override returns (bool) {
        return false;
    }
}

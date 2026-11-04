// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {TruthMarket} from "src/TruthMarket.sol";

/// @notice Successor policy: explicit finite limits AND the exact quoted state.
/// @dev Replaces an earlier policy that deliberately admitted unlimited odds.
contract LiquidityBandPolicyTest is DualTokenBase {
    function setUp() public override {
        super.setUp();
        _createMarket();
    }

    function _limits() internal view returns (IAMMEngine.LiquidityLimits memory limits) {
        (uint256 tokenIn, uint256 units, uint256 price, bytes32 stateHash) =
            amm.quoteLiquidityWithState(market, 10e18);
        limits = IAMMEngine.LiquidityLimits({
            maxTokenIn: tokenIn,
            minLpOut: units,
            minYesPrice: price,
            maxYesPrice: price,
            deadline: block.timestamp + 1 hours,
            expectedStateHash: stateHash
        });
    }

    function _reject(IAMMEngine.LiquidityLimits memory limits, bytes4 reason) internal {
        vm.prank(trader);
        vm.expectRevert(reason);
        amm.increaseLiquidity(market, 10e18, limits);
    }

    function test_exactQuoteCreatesReceiptAtQuotedCostAndOdds() public {
        IAMMEngine.LiquidityLimits memory limits = _limits();
        uint256 beforeBalance = east.balanceOf(trader);
        vm.prank(trader);
        (uint256 id, uint256 units) = amm.increaseLiquidity(market, 10e18, limits);
        assertGt(id, 0);
        assertEq(units, limits.minLpOut);
        assertEq(beforeBalance - east.balanceOf(trader), limits.maxTokenIn);
        (,, uint256 price) = amm.getMarketState(market);
        assertApproxEqAbs(price, limits.minYesPrice, 1);
    }

    function test_unboundedInputsAndMissingProtectionAreRejected() public {
        IAMMEngine.LiquidityLimits memory clean = _limits();
        IAMMEngine.LiquidityLimits memory limits = _limits();
        limits.maxTokenIn = type(uint256).max;
        _reject(limits, AMMEngine.UnboundedLiquidityLimits.selector);
        limits.maxTokenIn = 0;
        _reject(limits, AMMEngine.UnboundedLiquidityLimits.selector);
        limits = clean;
        limits.minLpOut = 0;
        _reject(limits, AMMEngine.UnboundedLiquidityLimits.selector);
        limits = _limits();
        limits.minYesPrice = 0;
        limits.maxYesPrice = 1e18;
        _reject(limits, AMMEngine.UnboundedLiquidityLimits.selector);
        limits = _limits();
        limits.deadline = type(uint256).max;
        _reject(limits, AMMEngine.UnboundedLiquidityLimits.selector);
        limits = _limits();
        limits.expectedStateHash = bytes32(0);
        _reject(limits, AMMEngine.StaleLiquidityQuote.selector);
    }

    function test_oddsAndFundingBoundsAreIndependentlyEnforced() public {
        IAMMEngine.LiquidityLimits memory limits = _limits();
        limits.minYesPrice += 1;
        limits.maxYesPrice += 2;
        _reject(limits, AMMEngine.SlippageExceeded.selector);
        limits = _limits();
        limits.maxTokenIn -= 1;
        _reject(limits, AMMEngine.SlippageExceeded.selector);
        limits = _limits();
        limits.minLpOut += 1;
        _reject(limits, AMMEngine.SlippageExceeded.selector);
    }

    function test_quoteExpiresEvenWithoutPriceMovement() public {
        IAMMEngine.LiquidityLimits memory limits = _limits();
        vm.warp(limits.deadline + 1);
        _reject(limits, AMMEngine.SlippageExceeded.selector);
    }

    function test_tradeInvalidatesQuoteEvenInsideFivePointBand() public {
        IAMMEngine.LiquidityLimits memory limits = _limits();
        limits.minYesPrice -= 0.05e18;
        limits.maxYesPrice += 0.05e18;
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        (,, uint256 price) = amm.getMarketState(market);
        assertGt(price, limits.minYesPrice);
        assertLt(price, limits.maxYesPrice);
        _reject(limits, AMMEngine.StaleLiquidityQuote.selector);
    }

    function test_competingAdditionInvalidatesQuoteAtUnchangedOdds() public {
        IAMMEngine.LiquidityLimits memory stale = _limits();
        vm.prank(trader);
        amm.increaseLiquidity(market, 10e18, stale);
        _reject(stale, AMMEngine.StaleLiquidityQuote.selector);
    }

    function test_quoteMustBeRefreshedAfterStateChange() public {
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        IAMMEngine.LiquidityLimits memory refreshed = _limits();
        vm.prank(trader);
        (uint256 id,) = amm.increaseLiquidity(market, 10e18, refreshed);
        assertGt(id, 0);
    }

    function test_creationPauseDoesNotBlockFundedMarketAdditionOrTrading() public {
        marketFactory.setCreationPaused(true);
        IAMMEngine.LiquidityLimits memory limits = _limits();
        vm.prank(trader);
        amm.increaseLiquidity(market, 10e18, limits);
        vm.prank(trader);
        amm.tradePositions(market, 1, 1e18, type(uint256).max);
        assertTrue(TruthMarket(market).isTradingOpen());
    }

    function test_deprecatedUnprotectedTopupCannotBypassChecks() public {
        vm.prank(creator);
        vm.expectRevert(AMMEngine.TopUpsDisabled.selector);
        amm.increaseLiquidityFromCreator(market, 10e18);
    }
}

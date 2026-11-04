// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";

/// @notice Extreme-rate evidence, not a recommendation to use a 100% trading fee.
contract MaximumAmmFeeTest is DualTokenBase {
    IERC20 private token;
    LPPositionManager private manager;
    uint256 private position;
    uint256 private unit;
    uint256 private cashBefore;
    bool private fullCapital;

    function _prepare(uint8 decimals, bool full) private {
        token = IERC20(decimals == 6 ? address(usdc) : address(east));
        unit = 10 ** (18 - decimals);
        fullCapital = full;
        if (decimals == 6) {
            usdc.mint(creator, 1000e6);
            usdc.mint(trader, 1000e6);
            vm.prank(creator);
            usdc.approve(address(marketFactory), type(uint256).max);
            vm.prank(trader);
            usdc.approve(address(amm), type(uint256).max);
        }
        cashBefore = _cash();
        IAmmFeeVault.AmmConfig memory cfg = full
            ? IAmmFeeVault.AmmConfig(10_000, 10_000, 0, 0, 0, treasury)
            : IAmmFeeVault.AmmConfig(10_000, 5000, 3000, 1000, 1000, treasury);
        vault.publishAmmConfig(cfg);
        IMarketFactory.MarketParams memory p = _marketParams(
            "Maximum AMM trading fee lifecycle",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (market, position) = marketFactory.createMarket(p);
        manager = LPPositionManager(amm.positionManager());
        assertEq(vault.configOf(market).feeBps, 10_000);
        _solvent();
    }

    function _cash() private view returns (uint256) {
        return token.balanceOf(creator) + token.balanceOf(trader)
            + token.balanceOf(treasury) + token.balanceOf(address(this))
            + token.balanceOf(address(amm)) + token.balanceOf(address(vault));
    }

    function _solvent() private view {
        uint256 engineLiabilities =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertEq(amm.totalLiabilitiesOf(address(token)), engineLiabilities);
        assertGe(token.balanceOf(address(amm)) * unit, engineLiabilities);
        uint256 buckets = vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(token))
            + vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(token))
            + vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(token));
        assertEq(vault.totalLiabilitiesOf(address(token)), buckets);
        assertEq(vault.marketLiabilitiesOf(market, address(token)), buckets);
        assertEq(token.balanceOf(address(vault)), buckets);
        if (fullCapital) assertEq(buckets, 0);
        assertEq(_cash(), cashBefore, "exact native cash conservation");
    }

    function _buy() private {
        (uint256 base, uint256 fee, uint256 quote,) =
            amm.getPositionQuote(market, 1, 20e18);
        assertGt(base, 0);
        assertEq(fee, base);
        assertEq(quote, 2 * base);
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        assertEq(amm.tradePositions(market, 1, 20e18, quote), quote);
        uint256 chargedNative = (quote + unit - 1) / unit;
        assertEq(before - token.balanceOf(trader), chargedNative);
        emit log_named_uint("buy 20 YES base WAD", base);
        emit log_named_uint("buy fee WAD", fee);
        emit log_named_uint("buy actual debit native", chargedNative);
        _solvent();
    }

    function _snapshot() private view returns (bytes32) {
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        (uint256 qYes, uint256 qNo, uint256 price) = amm.getMarketState(market);
        return keccak256(
            abi.encode(
                yes,
                no,
                qYes,
                qNo,
                price,
                amm.getLiquidity(market),
                amm.getMarketCollateral(market),
                amm.totalLiabilitiesOf(address(token)),
                vault.totalLiabilitiesOf(address(token)),
                token.balanceOf(trader),
                token.balanceOf(address(amm)),
                token.balanceOf(address(vault))
            )
        );
    }

    function _sell() private {
        (uint256 base, uint256 fee, uint256 quote,) =
            amm.getPositionQuote(market, 1, -5e18);
        assertGt(base, 0);
        assertEq(fee, base);
        assertEq(quote, 0);
        bytes32 beforeState = _snapshot();
        vm.prank(trader);
        vm.expectRevert(AMMEngine.SlippageExceeded.selector);
        amm.tradePositions(market, 1, -5e18, 1);
        assertEq(_snapshot(), beforeState, "positive minimum reverts all effects");
        uint256 beforeCash = token.balanceOf(trader);
        vm.prank(trader);
        assertEq(amm.tradePositions(market, 1, -5e18, 0), 0);
        assertEq(token.balanceOf(trader), beforeCash);
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        assertEq(yes, 15e18);
        assertEq(no, 0);
        emit log_named_uint("sell 5 YES base WAD", base);
        emit log_named_uint("sell fee WAD", fee);
        emit log_named_uint("sell actual payout native", 0);
        _solvent();
    }

    function _finish(uint8 outcome, bool timeout) private {
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("maximum fee evidence"));
        if (timeout) {
            ITruthMarket truth = ITruthMarket(market);
            vm.warp(uint256(truth.deadline()) + truth.invalidationBuffer());
            vault.finalize(market);
        } else {
            vm.warp(block.timestamp + 1 hours);
            adjudicator.settle(market);
        }
        _solvent();
    }

    function _claims(uint8 outcome, bool timeout, bool traderFirst) private {
        if (traderFirst) _claimTrader(outcome);
        uint256 lpUnits = manager.balanceOf(creator, position);
        _claimLpUnits(lpUnits / 2);
        _claimLpUnits(manager.balanceOf(creator, position));
        vm.startPrank(creator);
        assertEq(vault.claimLPDividendForPosition(market, position), 0);
        assertEq(vault.claimLPDividend(market), 0);
        vm.stopPrank();
        if (!traderFirst) _claimTrader(outcome);
        uint256 operatorAmount =
            vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(token));
        uint256 operatorBefore = token.balanceOf(treasury);
        assertEq(vault.claimOperatorFees(market), operatorAmount);
        assertEq(token.balanceOf(treasury) - operatorBefore, operatorAmount);
        if (timeout) {
            vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
            vault.claimResolutionFees(market);
        } else {
            uint256 resolverAmount =
                vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(token));
            uint256 resolverBefore = token.balanceOf(address(this));
            assertEq(vault.claimResolutionFees(market), resolverAmount);
            assertEq(token.balanceOf(address(this)) - resolverBefore, resolverAmount);
        }
        vm.prank(creator);
        vm.expectRevert(AMMEngine.NothingToClaim.selector);
        amm.claimFloor(market);
        assertEq(manager.totalSupply(position), 0);
        assertEq(amm.getMarketCollateral(market), 0);
        assertEq(amm.claimableFloorLiability(market), 0);
        assertEq(token.balanceOf(address(amm)), 0);
        assertEq(vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(token)), 0);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(token)), 0
        );
        assertEq(vault.lpEntitlementOf(market, creator, address(token)), 0);
        // Ordinary fees retain exactly one native unit in the LP accumulator's
        // reserved rounding bucket. It remains a vault liability, is not a
        // whole-native holder claim, and must not become sweepable surplus.
        // Full CAPITAL creates neither fee revenue nor this accumulator reserve.
        // Remeasured for v7: zero net sells create no conversion remainder, so
        // these exact zero/one native residuals are unchanged from v6.
        assertEq(token.balanceOf(address(vault)), fullCapital ? 0 : 1);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(token)),
            fullCapital ? 0 : 1
        );
        assertEq(vault.sweepUnattributedSurplus(address(token)), 0);
        emit log_named_uint("final AMM native custody", token.balanceOf(address(amm)));
        emit log_named_uint("final vault native custody", token.balanceOf(address(vault)));
        _solvent();
    }

    function _claimLpUnits(uint256 amount) private {
        uint256 before = token.balanceOf(creator);
        vm.prank(creator);
        (, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market, position, amount);
        assertEq(token.balanceOf(creator) - before, floorPaid / unit + feesPaid);
        if (fullCapital) assertEq(feesPaid, 0);
        _solvent();
    }

    function _claimTrader(uint8 outcome) private {
        uint256 before = token.balanceOf(trader);
        uint256 expected = outcome == 1 ? 15e18 : outcome == 0 ? 0 : 7.5e18;
        vm.prank(trader);
        assertEq(amm.settlePosition(market), expected);
        assertEq(token.balanceOf(trader) - before, expected / unit);
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        assertEq(yes + no, 0);
        _solvent();
    }

    function _run(uint8 decimals, bool full) private {
        _prepare(decimals, full);
        _buy();
        _sell();
        uint256 open = vm.snapshotState();
        for (uint8 terminal; terminal < 4; ++terminal) {
            if (terminal > 0) assertTrue(vm.revertToState(open));
            bool timeout = terminal == 3;
            uint8 outcome = timeout ? 2 : terminal;
            _finish(outcome, timeout);
            uint256 settled = vm.snapshotState();
            _claims(outcome, timeout, false);
            assertTrue(vm.revertToState(settled));
            _claims(outcome, timeout, true);
        }
    }

    function test_MaximumFeeSixDecimalsOrdinarySplit() public {
        _run(6, false);
    }

    function test_MaximumFeeSixDecimalsFullCapital() public {
        _run(6, true);
    }

    function test_MaximumFeeEighteenDecimalsOrdinarySplit() public {
        _run(18, false);
    }

    function test_MaximumFeeEighteenDecimalsFullCapital() public {
        _run(18, true);
    }
}

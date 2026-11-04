// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

/// @notice Full-CAPITAL lifecycle uses real market creation, pricing, custody,
/// LP accounting and terminal truth. Tokens and the manual resolver are fixtures.
contract FullCapitalLifecycleTest is DualTokenBase {
    IERC20 private token;
    LPPositionManager private manager;
    uint256 private position;
    uint256 private unit;
    uint256 private sellerRemainder;
    uint256 private initialActorCash;

    function _prepare(uint8 decimals) private {
        token = IERC20(decimals == 6 ? address(usdc) : address(east));
        unit = 10 ** (18 - decimals);
        if (decimals == 6) {
            usdc.mint(creator, 1000e6);
            usdc.mint(trader, 1000e6);
            vm.prank(creator);
            usdc.approve(address(marketFactory), type(uint256).max);
            vm.prank(trader);
            usdc.approve(address(amm), type(uint256).max);
        }
        initialActorCash = token.balanceOf(creator) + token.balanceOf(trader);
        vault.publishAmmConfig(IAmmFeeVault.AmmConfig(100, 10_000, 0, 0, 0, treasury));
        IMarketFactory.MarketParams memory p = _marketParams(
            "Full CAPITAL custody through terminal claims",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (market, position) = marketFactory.createMarket(p);
        manager = LPPositionManager(amm.positionManager());
        assertEq(vault.configOf(market).capitalBps, 10_000);
        _assertZeroRevenueAndSolvent();

        _trade(1, 20e18);
        _trade(0, 12e18);
        _trade(1, -5e18);
        _trade(0, -3e18);
    }

    function _trade(uint8 outcome, int256 shares) private returns (uint256 amount) {
        (, uint256 fee,,) = amm.getPositionQuote(market, outcome, shares);
        assertGt(fee, 0, "fixture must actually charge a fee");
        uint256 depth = amm.getLiquidity(market);
        uint256 sellerBefore = token.balanceOf(trader);
        vm.prank(trader);
        amount = amm.tradePositions(
            market, outcome, shares, shares > 0 ? type(uint256).max : 0
        );
        if (shares < 0) {
            assertEq(
                token.balanceOf(trader) - sellerBefore,
                amount / unit,
                "immediate sell payout"
            );
            sellerRemainder += amount % unit;
        }
        assertEq(amm.getLiquidity(market), depth + fee, "all fee retained as CAPITAL");
        assertEq(token.allowance(address(amm), address(vault)), 0);
        _assertZeroRevenueAndSolvent();
    }

    function _assertZeroRevenueAndSolvent() private view {
        assertEq(token.balanceOf(address(vault)), 0, "no AMM vault receipts");
        assertEq(vault.totalLiabilitiesOf(address(token)), 0);
        assertEq(vault.marketLiabilitiesOf(market, address(token)), 0);
        assertEq(vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(token)), 0);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(token)), 0
        );
        assertEq(vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(token)), 0);
        uint256 liabilities =
            amm.getMarketCollateral(market) + amm.claimableFloorLiability(market);
        assertEq(amm.totalLiabilitiesOf(address(token)), liabilities);
        assertGe(
            token.balanceOf(address(amm)) * unit,
            liabilities,
            "exact custody covers every ledger"
        );
        assertEq(token.balanceOf(address(bookVault)), 0);
        assertEq(token.balanceOf(address(orderEngine)), 0);
        assertEq(
            token.balanceOf(creator) + token.balanceOf(trader)
                + token.balanceOf(address(amm)),
            initialActorCash,
            "native cash conservation"
        );
    }

    function _finish(uint8 outcome, bool timeout) private {
        vm.prank(resolver);
        adjudicator.resolve(market, outcome, keccak256("full CAPITAL evidence"));
        if (timeout) {
            ITruthMarket truth = ITruthMarket(market);
            vm.warp(uint256(truth.deadline()) + truth.invalidationBuffer());
            vault.finalize(market);
        } else {
            vm.warp(block.timestamp + 1 hours);
            adjudicator.settle(market);
        }
        assertEq(ITruthMarket(market).winningOutcome(), timeout ? 2 : outcome);
        assertEq(
            uint8(ITruthMarket(market).settlementKind()),
            uint8(
                timeout
                    ? ITruthMarket.SettlementKind.INVALIDATED
                    : ITruthMarket.SettlementKind.ADJUDICATED
            )
        );
        _assertZeroRevenueAndSolvent();
    }

    function _claimTrader(uint8 outcome) private {
        uint256 before = token.balanceOf(trader);
        uint256 expected = outcome == 1 ? 15e18 : outcome == 0 ? 9e18 : 12e18;
        vm.prank(trader);
        assertEq(amm.settlePosition(market), expected);
        assertEq(token.balanceOf(trader) - before, expected / unit);
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        assertEq(yes + no, 0);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.NoPosition.selector);
        amm.settlePosition(market);
        _assertZeroRevenueAndSolvent();
    }

    function _claimLP(uint256 amount) private {
        uint256 before = token.balanceOf(creator);
        vm.prank(creator);
        (uint256 redeemed, uint256 floorPaid, uint256 feesPaid) =
            amm.claimAvailable(market, position, amount);
        if (amount > 0) assertGt(redeemed, 0);
        assertEq(feesPaid, 0);
        assertEq(token.balanceOf(creator) - before, floorPaid / unit);
        _assertZeroRevenueAndSolvent();
    }

    function _claimFees(bool timeout) private {
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 resolverBefore = token.balanceOf(address(this));
        assertEq(vault.claimOperatorFees(market), 0);
        if (timeout) {
            vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
            vault.claimResolutionFees(market);
        } else {
            assertEq(vault.claimResolutionFees(market), 0);
        }
        vm.startPrank(creator);
        assertEq(vault.claimLPDividendForPosition(market, position), 0);
        assertEq(vault.claimLPDividend(market), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(treasury), treasuryBefore);
        assertEq(token.balanceOf(address(this)), resolverBefore);
        _assertZeroRevenueAndSolvent();
    }

    function _exit(uint8 outcome, bool timeout, uint8 order) private {
        uint256 lpUnits = manager.balanceOf(creator, position);
        if (order == 1) _claimTrader(outcome);
        if (order == 2) _claimFees(timeout);
        _claimLP(lpUnits / 2);
        if (order == 0) _claimTrader(outcome);
        _claimLP(manager.balanceOf(creator, position));
        if (order == 2) _claimTrader(outcome);
        _claimFees(timeout);
        _claimLP(0);
        assertEq(manager.totalSupply(position), 0);
        assertEq(vault.lpEntitlementOf(market, creator, address(token)), 0);
        assertLt(
            amm.floorEntitlementOf(market, creator),
            unit,
            "no remaining claimable whole native floor"
        );

        emit log_named_uint("engine native residual", token.balanceOf(address(amm)));
        emit log_named_uint(
            "market collateral WAD residual", amm.getMarketCollateral(market)
        );
        emit log_named_uint("floor WAD residual", amm.claimableFloorLiability(market));
        emit log_named_uint(
            "token WAD liability residual", amm.totalLiabilitiesOf(address(token))
        );
        emit log_named_uint("seller conversion WAD remainder", sellerRemainder);
        // Each sell rounds down separately; every unsent fraction stays in market
        // principal and its existing LP accounting. At six decimals the two sells
        // retain 732177818915 WAD, which combines with the prior floor fraction
        // 267822181085 WAD to pay one more native unit to the LP than v6.
        // Both precisions now end with exactly zero custody and liability.
        uint256 floorRemainder = amm.floorEntitlementOf(market, creator);
        assertEq(amm.getMarketCollateral(market), 0);
        assertEq(amm.claimableFloorLiability(market), floorRemainder);
        assertEq(amm.totalLiabilitiesOf(address(token)), floorRemainder);
        assertEq(floorRemainder / unit, 0, "no stranded whole-native LP claim");
        assertEq(
            token.balanceOf(address(amm)) * unit,
            floorRemainder,
            "complete native custody attribution"
        );
        assertEq(floorRemainder, 0);
        assertEq(sellerRemainder, unit == 1 ? 0 : 732_177_818_915);
        assertEq(
            token.balanceOf(address(amm)), 0, "exact measured native rounding retention"
        );
        vm.prank(creator);
        vm.expectRevert(AMMEngine.NothingToClaim.selector);
        amm.claimFloor(market);
    }

    function _run(uint8 decimals, uint8 outcome, bool timeout) private {
        _prepare(decimals);
        _finish(outcome, timeout);
        uint256 checkpoint = vm.snapshotState();
        for (uint8 order; order < 3; ++order) {
            if (order > 0) assertTrue(vm.revertToState(checkpoint));
            _exit(timeout ? 2 : outcome, timeout, order);
        }
    }

    function test_FullCapitalSixDecimalsYes() public {
        _run(6, 1, false);
    }

    function test_FullCapitalSixDecimalsNo() public {
        _run(6, 0, false);
    }

    function test_FullCapitalSixDecimalsAdjudicatedInvalid() public {
        _run(6, 2, false);
    }

    function test_FullCapitalSixDecimalsTimeoutInvalid() public {
        _run(6, 1, true);
    }

    function test_FullCapitalEighteenDecimalsYes() public {
        _run(18, 1, false);
    }

    function test_FullCapitalEighteenDecimalsNo() public {
        _run(18, 0, false);
    }

    function test_FullCapitalEighteenDecimalsAdjudicatedInvalid() public {
        _run(18, 2, false);
    }

    function test_FullCapitalEighteenDecimalsTimeoutInvalid() public {
        _run(18, 1, true);
    }

    function test_FullCapitalRejectsNonzeroVaultDepositAndAcceptsZero() public {
        _prepare(6);
        vm.startPrank(address(amm));
        assertEq(vault.depositRevenue(market, 0, trader), 0);
        vm.expectRevert(VenueFeeVault.InvalidConfig.selector);
        vault.depositRevenue(market, 1, trader);
        vm.stopPrank();
        _assertZeroRevenueAndSolvent();
    }
}

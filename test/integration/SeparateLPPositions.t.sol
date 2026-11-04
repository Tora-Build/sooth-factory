// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {TruthMarket} from "src/TruthMarket.sol";

contract PositionCollateral is ERC20 {
    uint8 private immutable precision;
    uint8 public mode;
    address public engine;
    uint256 public callbackReceipt;

    constructor(uint8 decimals_) ERC20("Position collateral", "PCT") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint8 mode_, address engine_, uint256 receipt) external {
        mode = mode_;
        engine = engine_;
        callbackReceipt = receipt;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to == engine && value > 0) {
            if (mode == 1) super._update(to, address(0), 1);
            if (mode == 2) super._update(address(0), to, 1);
            if (mode == 3) {
                LPPositionManager(engine).transfer(address(0xBAD), callbackReceipt, 1);
            }
        }
    }
}

contract SeparateLPPositionsTest is DualTokenBase {
    PositionCollateral internal collateral;
    LPPositionManager internal manager;
    uint256 internal bootstrap;
    uint256 internal nativeScale;

    function _prepare(uint8 decimals_) internal {
        collateral = new PositionCollateral(decimals_);
        nativeScale = 10 ** (18 - decimals_);
        for (uint256 i; i < 4; i++) {
            address holder = i == 0 ? creator : i == 1 ? trader : i == 2 ? alice : bob;
            collateral.mint(holder, 1_000_000 * 10 ** decimals_);
            vm.startPrank(holder);
            collateral.approve(address(marketFactory), type(uint256).max);
            collateral.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        uint64 dl = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory params = _marketParams(
            "Separate positions", 0, dl, address(collateral), 100e18, 0.5e18
        );
        vm.prank(creator);
        (market, bootstrap) = marketFactory.createMarket(params);
        manager = LPPositionManager(amm.positionManager());
    }

    function _limits(uint256 depth)
        internal
        view
        returns (IAMMEngine.LiquidityLimits memory)
    {
        return _liquidityLimits(market, depth);
    }

    function _add(address owner, uint256 depth) internal returns (uint256 receipt) {
        (uint256 nativeIn, uint256 units,) = amm.quoteLiquidity(market, depth);
        uint256 beforeBalance = collateral.balanceOf(owner);
        IAMMEngine.LiquidityLimits memory limits = _limits(depth);
        vm.prank(owner);
        (receipt,) = amm.increaseLiquidity(market, depth, limits);
        assertEq(beforeBalance - collateral.balanceOf(owner), nativeIn);
        assertEq(manager.balanceOf(owner, receipt), units);
        assertEq(manager.positionMarket(receipt), market);
        _solvent();
    }

    function _solvent() internal view {
        uint256 liability = amm.totalLiabilitiesOf(address(collateral));
        assertGe(collateral.balanceOf(address(amm)) * nativeScale, liability);
        assertGe(
            collateral.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(collateral))
        );
        assertGe(usdc.balanceOf(address(vault)), vault.totalLiabilitiesOf(address(usdc)));
    }

    function _claim(uint256 receipt, address holder, bool splitClaim) internal {
        uint256 units = manager.balanceOf(holder, receipt);
        if (splitClaim) {
            vm.prank(holder);
            amm.redeemLPPosition(market, receipt, units / 2);
            _pull(holder);
            units -= units / 2;
        }
        vm.prank(holder);
        amm.redeemLPPosition(market, receipt, units);
        _pull(holder);
        assertEq(vault.lpEntitlementOf(market, holder, address(usdc)), 0);
        _solvent();
    }

    function _pull(address holder) internal {
        if (amm.floorEntitlementOf(market, holder) >= nativeScale) {
            vm.prank(holder);
            amm.claimFloor(market);
        }
        if (vault.lpEntitlementOf(market, holder, address(collateral)) > 0) {
            vm.prank(holder);
            vault.claimLPDividend(market);
        }
        _solvent();
    }

    function test_skewedAddPreservesOddsOldClaimsAndUserShares() public {
        _prepare(18);
        vm.prank(trader);
        amm.tradePositions(market, 1, 100e18, type(uint256).max);
        (,, uint256 priceBefore) = amm.getMarketState(market);
        assertGt(priceBefore, 0.7e18);
        uint256[3] memory old;
        for (uint8 i; i < 3; i++) {
            old[i] = manager.residual(bootstrap, i);
        }
        uint256 receipt = _add(alice, 100e18);
        (,, uint256 priceAfter) = amm.getMarketState(market);
        assertApproxEqAbs(priceBefore, priceAfter, 1);
        for (uint8 i; i < 3; i++) {
            assertEq(manager.residual(bootstrap, i), old[i]);
            assertEq(manager.residual(receipt, i), manager.totalSupply(receipt));
        }
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        assertEq(yes, 100e18);
        assertEq(no, 0);
        assertEq(manager.positionCount(market), 2);
    }

    function test_buyAddSellAttackBothPrecisionsAndAllOutcomes() public {
        for (uint8 precisionIndex; precisionIndex < 2; precisionIndex++) {
            uint256 root = vm.snapshotState();
            _prepare(precisionIndex == 0 ? 6 : 18);
            uint256 startBalance = collateral.balanceOf(trader);
            vm.prank(trader);
            amm.tradePositions(market, 1, 100e18, type(uint256).max);
            uint256 receipt = _add(trader, 100e18);
            vm.prank(trader);
            amm.tradePositions(market, 1, -100e18, 0);
            int256[3] memory profit;
            for (uint8 outcome; outcome < 3; outcome++) {
                uint256 checkpoint = vm.snapshotState();
                _resolveAndSettle(outcome);

                _claim(receipt, trader, true);
                _claim(bootstrap, creator, true);

                _solvent();
                profit[outcome] =
                    int256(collateral.balanceOf(trader)) - int256(startBalance);
                assertTrue(vm.revertToState(checkpoint));
            }
            assertFalse(
                profit[0] > 0 && profit[1] > 0, "self-funded all-outcome extraction"
            );
            assertLt(profit[0], 0, "NO retains directional LP risk");
            assertTrue(vm.revertToState(root));
        }
    }

    function test_timeoutFeesStayWithEarnerAfterEntryAndTransfer() public {
        _prepare(18);
        vm.prank(trader);
        amm.tradePositions(market, 1, 50e18, type(uint256).max);
        uint256 earned = vault.accountOf(
            market, IAmmFeeVault.Bucket.LP, address(collateral)
        ) + vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(collateral));
        uint256 receipt = _add(alice, 200e18);
        uint256 bootstrapBalance = manager.balanceOf(creator, bootstrap);
        vm.prank(creator);
        manager.transfer(bob, bootstrap, bootstrapBalance);
        vm.warp(
            uint256(TruthMarket(market).deadline())
                + TruthMarket(market).invalidationBuffer()
        );
        vault.finalize(market);
        manager.checkpointFees(receipt, alice);
        manager.checkpointFees(bootstrap, bob);
        uint256 creatorFees = vault.lpEntitlementOf(market, creator, address(collateral));
        assertLe(creatorFees, earned);
        assertLe(earned - creatorFees, 2);
        assertEq(vault.lpEntitlementOf(market, alice, address(collateral)), 0);
        assertEq(vault.lpEntitlementOf(market, bob, address(collateral)), 0);
        vm.prank(creator);
        vault.claimLPDividend(market);
        _claim(bootstrap, bob, true);
        _claim(receipt, alice, true);
        vm.prank(trader);
        amm.settlePosition(market);
        _solvent();
    }

    function test_limitsCreationPauseDeadlineAndUnauthorizedCalls() public {
        _prepare(18);
        IAMMEngine.LiquidityLimits memory limits = _limits(100e18);
        limits.maxTokenIn = 0;
        vm.prank(alice);
        vm.expectRevert(AMMEngine.UnboundedLiquidityLimits.selector);
        amm.increaseLiquidity(market, 100e18, limits);
        limits = _limits(100e18);
        limits.minYesPrice = 0.6e18;
        limits.maxYesPrice = 0.7e18;
        vm.prank(alice);
        vm.expectRevert(AMMEngine.SlippageExceeded.selector);
        amm.increaseLiquidity(market, 100e18, limits);
        marketFactory.setCreationPaused(true);
        limits = _limits(100e18);
        vm.prank(alice);
        amm.increaseLiquidity(market, 100e18, limits);
        marketFactory.setCreationPaused(false);
        vm.expectRevert(LPPositionManager.Unauthorized.selector);
        manager.recordTrade(market, 1, 1, 1);
        vm.expectRevert(LPPositionManager.Unauthorized.selector);
        manager.accrueFees(market, 100, 100);
        limits = _limits(100e18);
        vm.warp(TruthMarket(market).deadline());
        vm.prank(alice);
        vm.expectRevert(AMMEngine.MintingClosed.selector);
        amm.increaseLiquidity(market, 100e18, limits);
    }

    function test_adversarialReceiptsAndCallbackRollback() public {
        _prepare(6);
        uint256 receipt = _add(alice, 100e18);
        vm.prank(alice);
        manager.transfer(address(collateral), receipt, 100);
        uint256 depth = amm.getLiquidity(market);
        uint256 custody = collateral.balanceOf(address(amm));
        for (uint8 mode = 1; mode <= 3; mode++) {
            collateral.configure(mode, address(amm), receipt);
            IAMMEngine.LiquidityLimits memory limits = _limits(100e18);
            vm.prank(bob);
            vm.expectRevert();
            amm.increaseLiquidity(market, 100e18, limits);
            assertEq(amm.getLiquidity(market), depth);
            assertEq(collateral.balanceOf(address(amm)), custody);
            assertEq(manager.positionCount(market), 2);
            assertEq(manager.balanceOf(address(collateral), receipt), 100);
        }
    }

    function test_settledFeeClaimDoesNotRequireReceiptBurn() public {
        _prepare(18);
        vm.prank(trader);
        amm.tradePositions(market, 0, 40e18, type(uint256).max);
        uint256 adjFees =
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(collateral));
        uint256 units = manager.balanceOf(creator, bootstrap);
        _resolveAndSettle(2); // Formal INVALID does not forfeit adjudicator fees.
        vm.prank(creator);
        uint256 paid = vault.claimLPDividendForPosition(market, bootstrap);
        assertGt(paid, 0);
        assertEq(manager.balanceOf(creator, bootstrap), units);
        assertEq(
            vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(collateral)),
            adjFees
        );
        _claim(bootstrap, creator, true);
        _solvent();
    }

    function test_manyEntriesKeepSwapWorkBoundedAndOddsStable() public {
        _prepare(18);
        vm.prank(trader);
        amm.tradePositions(market, 1, 71e18 + 19, type(uint256).max);
        (,, uint256 originalPrice) = amm.getMarketState(market);
        uint256 originalNoResidual = manager.residual(bootstrap, 0);
        for (uint256 i; i < 48; i++) {
            _add(alice, 1e18 + i);
        }
        (,, uint256 finalPrice) = amm.getMarketState(market);
        assertApproxEqAbs(originalPrice, finalPrice, 1);
        assertEq(manager.residual(bootstrap, 0), originalNoResidual);
        assertEq(manager.positionCount(market), 49);
        vm.prank(trader);
        uint256 beforeGas = gasleft();
        amm.tradePositions(market, 0, 5e18, type(uint256).max);
        uint256 tradeGas = beforeGas - gasleft();
        emit log_named_uint("49-position trade gas", tradeGas);
        assertLt(tradeGas, 1_000_000, "swap must not iterate over position contracts");
        _solvent();
    }

    function testFuzz_mixedEntriesClaimsSolvent(
        uint64 seed,
        bool sixDecimals,
        uint8 outcomeSeed,
        bool reverse
    ) public {
        _prepare(sixDecimals ? 6 : 18);
        uint256[3] memory receipts;
        receipts[0] = bootstrap;
        for (uint256 i; i < 2; i++) {
            uint256 amount = (uint256(keccak256(abi.encode(seed, i))) % 300 + 1) * 1e18;
            vm.prank(trader);
            amm.tradePositions(market, uint8(i), int256(amount), type(uint256).max);
            receipts[i + 1] = _add(i == 0 ? alice : bob, (uint256(seed) % 99 + 1) * 1e18);
            vm.prank(trader);
            amm.tradePositions(market, uint8(i), -int256(amount / 2), 0);
        }
        _resolveAndSettle(outcomeSeed % 3);
        if (reverse) {
            vm.prank(trader);
            amm.settlePosition(market);
        }
        for (uint256 i; i < 3; i++) {
            uint256 index = reverse ? 2 - i : i;
            _claim(receipts[index], index == 0 ? creator : index == 1 ? alice : bob, true);
        }
        if (!reverse) {
            vm.prank(trader);
            amm.settlePosition(market);
        }

        _solvent();
    }

    function test_quotesRejectZeroAndImpossibleMarketSales() public {
        _prepare(18);
        vm.expectRevert(AMMEngine.ZeroDelta.selector);
        amm.getPositionQuote(market, 1, 0);
        vm.expectRevert(AMMEngine.InsufficientMarketYes.selector);
        amm.getPositionQuote(market, 1, -1);
        vm.expectRevert(AMMEngine.InsufficientMarketNo.selector);
        amm.getPositionQuote(market, 0, -1);
    }

    function testFuzz_longSequenceAllOutcomesAndClaimOrders(
        uint256 seed,
        bool sixDecimals
    ) public {
        _prepare(sixDecimals ? 6 : 18);
        uint256[7] memory receipts;
        receipts[0] = bootstrap;
        uint256 count = 1;
        for (uint256 step; step < 18; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint8 side = uint8(seed % 2);
            (uint256 yes, uint256 no) = amm.getPosition(market, trader);
            uint256 owned = side == 1 ? yes : no;
            int256 delta = int256((seed % 900 + 1) * 1e18 + seed % 997);
            if (seed % 3 == 0 && owned > 1) delta = -int256(owned / 2);
            vm.prank(trader);
            amm.tradePositions(market, side, delta, delta > 0 ? type(uint256).max : 0);
            if (step % 3 == 0) {
                receipts[count++] = _add(alice, (seed % 250 + 1) * 1e18 + seed % 991);
            }
            _assertAllResidualsBacked(receipts, count);
        }
        // Every contributed receipt has multiple terminal holders. Past fees must
        // remain with Alice while all holders retain their own terminal residual.
        for (uint256 i = 1; i < count; i++) {
            uint256 part = manager.balanceOf(alice, receipts[i]) / 3;
            vm.prank(alice);
            manager.transfer(bob, receipts[i], part);
        }
        for (uint8 result; result < 4; result++) {
            for (uint8 order; order < 2; order++) {
                uint256 checkpoint = vm.snapshotState();
                if (result == 3) {
                    vm.warp(
                        uint256(TruthMarket(market).deadline())
                            + TruthMarket(market).invalidationBuffer()
                    );
                    vault.finalize(market);
                } else {
                    _resolveAndSettle(result);
                }
                if (order == 0) _settleStressTrader();
                for (uint256 i; i < count; i++) {
                    uint256 index = order == 0 ? i : count - i - 1;
                    if (index == 0) {
                        _claim(receipts[index], creator, true);
                    } else {
                        _claim(receipts[index], alice, true);
                        _claim(receipts[index], bob, true);
                    }
                }
                if (order == 1) _settleStressTrader();
                _solvent();
                assertTrue(vm.revertToState(checkpoint));
            }
        }
    }

    function _settleStressTrader() private {
        (uint256 y, uint256 n) = amm.getPosition(market, trader);
        if (y + n > 0) {
            vm.prank(trader);
            amm.settlePosition(market);
        }
        _solvent();
    }

    function _assertAllResidualsBacked(uint256[7] memory receipts, uint256 count)
        private
        view
    {
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        for (uint8 outcome; outcome < 3; outcome++) {
            uint256 claims = outcome == 0 ? no : outcome == 1 ? yes : (yes + no) / 2;
            for (uint256 i; i < count; i++) {
                claims += manager.residual(receipts[i], outcome);
            }
            assertLe(
                claims,
                amm.getMarketCollateral(market),
                "LP and trader claims exceed collateral"
            );
        }
        _solvent();
    }
}

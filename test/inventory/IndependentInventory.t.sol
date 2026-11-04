// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {TruthMarket} from "src/TruthMarket.sol";

/// @dev Honest balances, with optional refused or false-after-movement payouts.
contract InventoryAcceptanceToken is MockUSDC {
    uint8 private immutable _precision;
    uint8 public mode;
    address public affected;

    constructor(uint8 precision_) MockUSDC("Inventory acceptance", "INV") {
        _precision = precision_;
    }

    function decimals() public view override returns (uint8) {
        return _precision;
    }

    function configure(uint8 mode_, address affected_) external {
        mode = mode_;
        affected = affected_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == affected && mode == 1) return false;
        bool result = super.transfer(to, amount);
        return to == affected && mode == 2 ? false : result;
    }
}

/// @notice Independent cash-flow acceptance, deliberately using gross holdings
/// and observable token transfers rather than the engine's settlement library.
abstract contract IndependentInventoryCampaign is DualTokenBase {
    uint256 internal unit;
    InventoryAcceptanceToken internal token;

    function precision() internal pure virtual returns (uint8);

    function setUp() public override {
        east = new East18E();
        token = new InventoryAcceptanceToken(precision());
        usdc = token;
        unit = 10 ** precision();
        _deployStack(address(token));
        east.mint(creator, 1000e18);
        vm.prank(creator);
        east.approve(address(marketFactory), type(uint256).max);
        address[4] memory accounts = [alice, bob, trader, creator];
        for (uint256 i; i < accounts.length; ++i) {
            token.mint(accounts[i], 1_000_000 * unit);
            vm.prank(accounts[i]);
            token.approve(address(orderEngine), type(uint256).max);
        }
        _createMarket();
    }

    function _terms(uint8 outcome, uint8 action, uint16 price, uint128 amount, bool rest)
        internal
        view
        returns (IOrderEngine.OrderParams memory p)
    {
        p.outcome = outcome;
        p.action = action;
        p.priceTick = price;
        p.amount = amount;
        p.matchLimit = 64;
        p.validUntil = uint64(block.timestamp + 1 hours);
        p.rest = rest;
        p.maxTokenIn = action == 0 ? 1_000_000 * unit : 0;
    }

    function _order(
        address user,
        uint8 outcome,
        uint8 action,
        uint16 price,
        uint128 amount,
        bool rest
    ) internal returns (uint64) {
        vm.prank(user);
        return orderEngine.placeOrder(
            market, _terms(outcome, action, price, amount, rest)
        )
        .orderId;
    }

    function _split(address user, uint256 amount) internal {
        vm.prank(user);
        orderEngine.split(
            market,
            amount,
            amount / (10 ** (18 - precision())),
            uint64(block.timestamp + 1 hours)
        );
    }

    function _merge(address user, uint256 amount) internal {
        vm.prank(user);
        orderEngine.merge(
            market,
            amount,
            amount / (10 ** (18 - precision())),
            uint64(block.timestamp + 1 hours)
        );
    }

    function _inventory(
        address user,
        uint256 yes,
        uint256 no,
        uint256 reservedYes,
        uint256 reservedNo,
        uint256 cash
    ) internal view {
        (uint256 y, uint256 n, uint256 ry, uint256 rn, uint256 c) =
            orderEngine.getInventory(market, user);
        assertEq(y, yes, "owned YES");
        assertEq(n, no, "owned NO");
        assertEq(ry, reservedYes, "reserved YES");
        assertEq(rn, reservedNo, "reserved NO");
        assertEq(c, cash, "reserved cash");
        assertEq(
            orderEngine.getNet(market, user), int256(yes) - int256(no), "derived exposure"
        );
        assertLe(ry, y);
        assertLe(rn, n);
    }

    function _supplies(uint256 yes, uint256 no) internal view {
        (uint256 y, uint256 n) = orderEngine.getSupplies(market);
        assertEq(y, yes, "YES supply");
        assertEq(n, no, "NO supply");
    }

    function test_splitFundsBothQuotesWithoutAnyRemainingCash() public {
        _split(alice, 100e18);
        token.burn(alice, token.balanceOf(alice));
        vm.prank(alice);
        token.approve(address(orderEngine), 0);
        uint64 yesOrder = _order(alice, 1, 1, 520, 100e18, true);
        uint64 noOrder = _order(alice, 0, 1, 520, 100e18, true);
        _inventory(alice, 100e18, 100e18, 100e18, 100e18, 0);
        _supplies(100e18, 100e18);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        orderEngine.merge(market, 1e18, unit, uint64(block.timestamp + 60));
        vm.prank(alice);
        orderEngine.cancelById(yesOrder);
        vm.prank(alice);
        vm.expectRevert();
        orderEngine.merge(market, 1e18, unit, uint64(block.timestamp + 60));
        vm.prank(alice);
        orderEngine.cancelById(noOrder);
        _merge(alice, 100e18);
        assertEq(token.balanceOf(alice), 100 * unit);
        _inventory(alice, 0, 0, 0, 0, 0);
        _supplies(0, 0);
    }

    function test_hundredDollarMakerWorkflowPartialFillsCancelAndMerge() public {
        uint256 makerBefore = token.balanceOf(alice);
        uint256 takerBefore = token.balanceOf(bob);
        _split(alice, 100e18);
        uint64 yesOrder = _order(alice, 1, 1, 520, 100e18, true);
        uint64 noOrder = _order(alice, 0, 1, 520, 100e18, true);
        _order(bob, 1, 0, 520, 40e18, false);
        assertEq(token.balanceOf(alice), makerBefore - 100 * unit + 208 * unit / 10);
        _inventory(alice, 60e18, 100e18, 60e18, 100e18, 0);
        _order(bob, 0, 0, 520, 40e18, false);
        _inventory(bob, 40e18, 40e18, 0, 0, 0);
        uint256 beforeCancellation = token.balanceOf(alice);
        vm.startPrank(alice);
        orderEngine.cancelById(yesOrder);
        orderEngine.cancelById(noOrder);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), beforeCancellation, "only shares unlock");
        _merge(alice, 60e18);
        _merge(bob, 40e18);
        assertEq(token.balanceOf(alice) - makerBefore, 16 * unit / 10, "maker spread");
        assertEq(
            takerBefore - token.balanceOf(bob),
            1984 * unit / 1000,
            "spread plus two taker fees"
        );
        assertEq(token.balanceOf(address(bookVault)), 384 * unit / 1000);
        _inventory(alice, 0, 0, 0, 0, 0);
        _inventory(bob, 0, 0, 0, 0, 0);
        _supplies(0, 0);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_cashBuyPairCreatesBothOutcomesAndSellPairBurnsThem() public {
        _order(alice, 1, 0, 600, 100e18, true);
        _order(bob, 0, 0, 400, 100e18, false);
        _inventory(alice, 100e18, 0, 0, 0, 0);
        _inventory(bob, 0, 100e18, 0, 0, 0);
        _supplies(100e18, 100e18);
        assertEq(orderEngine.getCollateralBacking(market), 100 * unit);
        uint256 makerBefore = token.balanceOf(alice);
        uint256 takerBefore = token.balanceOf(bob);
        _order(alice, 1, 1, 600, 100e18, true);
        _order(bob, 0, 1, 400, 100e18, false);
        assertEq(token.balanceOf(alice) - makerBefore, 60 * unit);
        assertEq(token.balanceOf(bob) - takerBefore, 396 * unit / 10);
        _supplies(0, 0);
        _inventory(alice, 0, 0, 0, 0, 0);
        _inventory(bob, 0, 0, 0, 0, 0);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_splitThenSellCannotAvoidBuyFee() public {
        uint256 snapshot = vm.snapshotState();
        uint256 before = token.balanceOf(alice);
        _order(bob, 0, 0, 400, 100e18, true);
        _order(alice, 1, 0, 600, 100e18, false);
        uint256 directCost = before - token.balanceOf(alice);
        uint256 directFee = token.balanceOf(address(bookVault));
        assertTrue(vm.revertToState(snapshot));
        _order(bob, 0, 0, 400, 100e18, true);
        _split(alice, 100e18);
        _order(alice, 0, 1, 400, 100e18, false);
        assertEq(before - token.balanceOf(alice), directCost);
        assertEq(directCost, 604 * unit / 10);
        assertEq(token.balanceOf(address(bookVault)), directFee);
        _inventory(alice, 100e18, 0, 0, 0, 0);
    }

    function test_buyThenMergeAndDirectSellPayTheSameFee() public {
        _split(alice, 100e18);
        uint256 snapshot = vm.snapshotState();
        uint256 before = token.balanceOf(alice);
        _order(bob, 1, 0, 600, 100e18, true);
        _order(alice, 1, 1, 600, 100e18, false);
        uint256 directProceeds = token.balanceOf(alice) - before;
        uint256 directFee = token.balanceOf(address(bookVault));
        assertTrue(vm.revertToState(snapshot));
        _order(bob, 1, 0, 600, 100e18, true);
        _order(alice, 0, 0, 400, 100e18, false);
        _merge(alice, 100e18);
        assertEq(token.balanceOf(alice) - before, directProceeds);
        assertEq(directProceeds, 596 * unit / 10);
        assertEq(token.balanceOf(address(bookVault)), directFee);
        _inventory(alice, 0, 100e18, 0, 0, 0);
    }

    function test_partialSyntheticAcquisitionPaysOnlyExecutedQuantity() public {
        uint256 before = token.balanceOf(alice);
        _split(alice, 100e18);
        _order(bob, 0, 0, 400, 40e18, true);
        uint64 remainder = _order(alice, 0, 1, 400, 100e18, true);
        _inventory(alice, 100e18, 60e18, 0, 60e18, 0);
        vm.prank(alice);
        orderEngine.cancelById(remainder);
        _merge(alice, 60e18);
        assertEq(before - token.balanceOf(alice), 2416 * unit / 100);
        assertEq(token.balanceOf(address(bookVault)), 16 * unit / 100);
        _inventory(alice, 40e18, 0, 0, 0, 0);
        _supplies(40e18, 40e18);
    }

    function test_sameSharesCannotFundMultipleSellOrders() public {
        _split(alice, 100e18);
        _order(alice, 1, 1, 520, 60e18, true);
        vm.prank(alice);
        vm.expectRevert();
        orderEngine.placeOrder(market, _terms(1, 1, 530, 41e18, true));
        _order(alice, 1, 1, 530, 40e18, true);
        _inventory(alice, 100e18, 100e18, 100e18, 0, 0);
    }

    function _terminalReservedInventory(uint8 outcome, bool timeout) internal {
        _split(alice, 100e18);
        uint64 id = _order(alice, 1, 1, 520, 100e18, true);
        if (timeout) {
            vm.warp(
                uint256(TruthMarket(market).deadline())
                    + TruthMarket(market).invalidationBuffer() + 1
            );
            TruthMarket(market).invalidate();
        } else {
            _resolveAndSettle(outcome);
        }
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        _inventory(alice, 100e18, 0, 100e18, 0, 0);
        vm.prank(alice);
        orderEngine.cancelById(id);
        vm.prank(alice);
        orderEngine.settlePosition(market);
        assertEq(token.balanceOf(alice) - before, 100 * unit);
        _inventory(alice, 0, 0, 0, 0, 0);
        _supplies(0, 0);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_yesSettlementPreservesThenPaysReservedInventoryOnce() public {
        _terminalReservedInventory(1, false);
    }

    function test_noSettlementPreservesThenBurnsReservedLosingInventory() public {
        _terminalReservedInventory(0, false);
    }

    function test_invalidSettlementPaysBothHalvesAcrossCancellation() public {
        _terminalReservedInventory(2, false);
    }

    function test_timeoutSettlementPaysBothHalvesAcrossCancellation() public {
        _terminalReservedInventory(2, true);
    }

    function test_invalidNativeHalfCarriesAcrossReservedInventoryClaim() public {
        uint128 quantity = uint128(3 * orderEngine.shareUnit());
        _split(alice, quantity);
        uint64 id = _order(alice, 1, 1, 600, quantity, true);
        _resolveAndSettle(2);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 1);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 1);
        vm.prank(alice);
        orderEngine.cancelById(id);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 2);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 0);
        assertEq(token.balanceOf(alice) - before, 3);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_invalidRepeatedReservationReleaseMatchesSingleCompleteSetClaim()
        public
    {
        uint128 chunk = uint128(3 * orderEngine.shareUnit());
        _split(alice, 3 * uint256(chunk));
        uint64[3] memory ids;
        for (uint16 i; i < 3; ++i) {
            ids[i] = _order(alice, 1, 1, 600 + 100 * i, chunk, true);
        }
        _resolveAndSettle(2);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 4);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 1);
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(alice);
            orderEngine.cancelById(ids[i]);
            orderEngine.settlePosition(market);
            vm.stopPrank();
        }
        assertEq(token.balanceOf(alice) - before, 9);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 0);
        _inventory(alice, 0, 0, 0, 0, 0);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_mergePreservesExistingInvalidHalfRemainder() public {
        uint128 one = uint128(orderEngine.shareUnit());
        _split(alice, 5 * uint256(one));
        uint64 yesOrder = _order(alice, 1, 1, 600, 5 * one, true);
        uint64 noOrder = _order(alice, 0, 1, 600, 2 * one, true);
        _resolveAndSettle(2);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 1);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 1);
        vm.startPrank(alice);
        orderEngine.cancelById(yesOrder);
        orderEngine.cancelById(noOrder);
        vm.stopPrank();
        _merge(alice, 2 * uint256(one));
        assertEq(orderEngine.invalidRemainderOf(market, alice), 1);
        vm.prank(alice);
        assertEq(orderEngine.settlePosition(market), 2);
        assertEq(orderEngine.invalidRemainderOf(market, alice), 0);
        assertEq(token.balanceOf(alice) - before, 5);
        assertEq(orderEngine.getCollateralBacking(market), 0);
    }

    function test_blockedInventorySellerReceivesFundedDeferredClaim() public {
        _split(alice, 100e18);
        _order(alice, 1, 1, 600, 100e18, true);
        uint256 before = token.balanceOf(alice);
        token.configure(1, alice);
        _order(bob, 1, 0, 600, 100e18, false);
        assertEq(token.balanceOf(alice), before);
        assertEq(orderEngine.deferredOf(alice), 60 * unit);
        assertEq(orderEngine.totalDeferred(), 60 * unit);
        assertEq(token.balanceOf(address(orderEngine)), 160 * unit);
        assertEq(orderEngine.getCollateralBacking(market), 100 * unit);
        _inventory(alice, 0, 100e18, 0, 0, 0);
        token.configure(0, address(0));
        vm.prank(alice);
        assertEq(orderEngine.claimDeferred(), 60 * unit);
        assertEq(token.balanceOf(alice) - before, 60 * unit);
        assertEq(token.balanceOf(address(orderEngine)), 100 * unit);
        assertEq(orderEngine.totalDeferred(), 0);
    }

    function test_falseAfterMovementRollsBackInventoryAndFeeTransfers() public {
        _split(alice, 100e18);
        _order(alice, 1, 1, 600, 100e18, true);
        uint256 before = token.balanceOf(alice);
        token.configure(2, alice);
        vm.prank(bob);
        vm.expectRevert(OrderEngine.TransferAmountMismatch.selector);
        orderEngine.placeOrder(market, _terms(1, 0, 600, 100e18, false));
        assertEq(token.balanceOf(alice), before);
        assertEq(orderEngine.totalDeferred(), 0);
        assertEq(token.balanceOf(address(bookVault)), 0);
        _inventory(alice, 100e18, 100e18, 100e18, 0, 0);
        _inventory(bob, 0, 0, 0, 0, 0);
    }

    function test_sameCollateralAmmBackingDoesNotFundBookInventory() public {
        vm.prank(creator);
        token.approve(address(marketFactory), 100 * unit);
        IMarketFactory.MarketParams memory p = _marketParams(
            "same-token inventory acceptance",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            25e18,
            0.5e18
        );
        vm.prank(creator);
        (market,) = marketFactory.createMarket(p);
        uint256 ammBefore = token.balanceOf(address(amm));
        uint256 ammVaultBefore = token.balanceOf(address(vault));
        _split(alice, 100e18);
        uint64 id = _order(alice, 1, 1, 520, 100e18, true);
        _order(bob, 1, 0, 520, 40e18, false);
        vm.prank(alice);
        orderEngine.cancelById(id);
        _merge(alice, 60e18);
        assertEq(token.balanceOf(address(amm)), ammBefore);
        assertEq(token.balanceOf(address(vault)), ammVaultBefore);
        assertEq(orderEngine.getCollateralBacking(market), 40 * unit);
        _supplies(40e18, 40e18);
    }

    function testFuzz_partialFillCancelMergeConservesCashAndClaims(uint8 rawFilled)
        public
    {
        uint256 filled = bound(rawFilled, 1, 99);
        uint128 amount = uint128(filled * 1e18);
        uint256 before = token.balanceOf(alice);
        _split(alice, 100e18);
        uint64 id = _order(alice, 1, 1, 520, 100e18, true);
        _order(bob, 1, 0, 520, amount, false);
        vm.prank(alice);
        orderEngine.cancelById(id);
        _merge(alice, (100 - filled) * 1e18);
        assertEq(before - token.balanceOf(alice), filled * 48 * unit / 100);
        _inventory(alice, 0, amount, 0, 0, 0);
        _inventory(bob, amount, 0, 0, 0, 0);
        _supplies(amount, amount);
        assertEq(orderEngine.getCollateralBacking(market), filled * unit);
        assertEq(token.balanceOf(address(orderEngine)), filled * unit);
    }
}

contract IndependentInventory6Test is IndependentInventoryCampaign {
    function precision() internal pure override returns (uint8) {
        return 6;
    }

    function test_nonNativeAlignedCompleteSetIsRejectedAtomically() public {
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        orderEngine.split(market, 1e12 + 1, 2, uint64(block.timestamp + 60));
        assertEq(token.balanceOf(alice), before);
        _inventory(alice, 0, 0, 0, 0, 0);
    }
}

contract IndependentInventory18Test is IndependentInventoryCampaign {
    function precision() internal pure override returns (uint8) {
        return 18;
    }
}

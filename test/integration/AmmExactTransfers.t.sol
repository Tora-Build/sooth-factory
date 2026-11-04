// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

/// @dev Honest balances, mutable transfer behavior: no test relies on lying getters.
contract ExactTransferToken is ERC20 {
    uint8 public behavior;
    address public affected;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    constructor() ERC20("Exact transfer fixture", "EXACT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint8 mode, address account) external {
        behavior = mode;
        affected = account;
    }

    function arm(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        return behavior == 3 && to == affected ? false : result;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) {
            require(behavior != 4 || to != affected, "BLOCKED");
            if (behavior == 1 && from == affected) {
                super._update(from, address(0xFEE), amount / 10);
            }
            if (behavior == 2 && to == affected) {
                uint256 fee = amount / 10;
                super._update(from, address(0xFEE), fee);
                amount -= fee;
            }
        }
        super._update(from, to, amount);
        if (callbackTarget != address(0)) {
            address target = callbackTarget;
            callbackTarget = address(0);
            (callbackSucceeded,) = target.call(callbackData);
        }
    }
}

contract AmmExactTransfersTest is DualTokenBase {
    ExactTransferToken internal token;
    uint256 internal positionId;

    function setUp() public override {
        super.setUp();
        token = new ExactTransferToken();
        address[3] memory holders = [creator, trader, alice];
        for (uint256 i; i < holders.length; ++i) {
            token.mint(holders[i], 100_000e18);
            vm.startPrank(holders[i]);
            token.approve(address(marketFactory), type(uint256).max);
            token.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        IMarketFactory.MarketParams memory p = _marketParams(
            "Exact AMM transfers",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (market, positionId) = marketFactory.createMarket(p);
    }

    function _buy() private {
        vm.prank(trader);
        amm.tradePositions(market, 1, 20e18, type(uint256).max);
    }

    function test_senderExtraFeeCannotOverchargeTrade() public {
        uint256 before = token.balanceOf(trader);
        bytes32 state = amm.liquidityStateHash(market);
        token.configure(1, trader);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.tradePositions(market, 1, 20e18, type(uint256).max);
        assertEq(token.balanceOf(trader), before);
        assertEq(amm.liquidityStateHash(market), state);
        (uint256 yes,) = amm.getPosition(market, trader);
        assertEq(yes, 0);
    }

    function test_senderExtraFeeCannotExceedSponsorMaximum() public {
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 1e18);
        uint256 before = token.balanceOf(alice);
        bytes32 state = amm.liquidityStateHash(market);
        token.configure(1, alice);
        vm.prank(alice);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.increaseLiquidity(market, 1e18, limits);
        assertEq(token.balanceOf(alice), before);
        assertEq(amm.liquidityStateHash(market), state);
    }

    function test_recipientTaxCannotDischargeWinningPosition() public {
        _buy();
        _resolveAndSettle(1);
        uint256 before = token.balanceOf(trader);
        uint256 collateral = amm.getMarketCollateral(market);
        token.configure(2, trader);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.settlePosition(market);
        assertEq(token.balanceOf(trader), before);
        assertEq(amm.getMarketCollateral(market), collateral);
        (uint256 yes,) = amm.getPosition(market, trader);
        assertEq(yes, 20e18);
    }

    function test_senderExtraTaxCannotConsumeEngineSurplusOnPayout() public {
        _buy();
        _resolveAndSettle(1);
        token.mint(address(amm), 100e18);
        uint256 custody = token.balanceOf(address(amm));
        token.configure(1, address(amm));
        vm.prank(trader);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.settlePosition(market);
        assertEq(token.balanceOf(address(amm)), custody);
        (uint256 yes,) = amm.getPosition(market, trader);
        assertEq(yes, 20e18);
    }

    function test_recipientTaxRevertsImmediateSaleAtomically() public {
        _buy();
        bytes32 beforeState = amm.liquidityStateHash(market);
        uint256 collateral = amm.getMarketCollateral(market);
        uint256 liability = amm.totalLiabilitiesOf(address(token));
        uint256 engineCash = token.balanceOf(address(amm));
        uint256 sellerCash = token.balanceOf(trader);
        uint256 vaultCash = token.balanceOf(address(vault));
        token.configure(2, trader);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.tradePositions(market, 1, -5e18, 0);
        assertEq(amm.liquidityStateHash(market), beforeState);
        assertEq(amm.getMarketCollateral(market), collateral);
        assertEq(amm.totalLiabilitiesOf(address(token)), liability);
        assertEq(token.balanceOf(address(amm)), engineCash);
        assertEq(token.balanceOf(trader), sellerCash);
        assertEq(token.balanceOf(address(vault)), vaultCash);
        (uint256 yes,) = amm.getPosition(market, trader);
        assertEq(yes, 20e18);
    }

    function test_recipientTaxCannotDischargeLpFloor() public {
        _buy();
        _resolveAndSettle(1);
        LPPositionManager manager = LPPositionManager(amm.positionManager());
        uint256 units = manager.balanceOf(creator, positionId);
        vm.prank(creator);
        amm.redeemLP(market, units);
        uint256 owed = amm.floorEntitlementOf(market, creator);
        assertGt(owed, 0);
        token.configure(2, creator);
        vm.prank(creator);
        vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        amm.claimFloor(market);
        assertEq(amm.floorEntitlementOf(market, creator), owed);
        assertEq(amm.claimableFloorLiability(market), owed);
    }

    function test_callbacksCannotReenterDuringCollectionOrPayout() public {
        token.arm(
            address(amm),
            abi.encodeCall(
                amm.tradePositions, (market, 1, int256(1e18), type(uint256).max)
            )
        );
        _buy();
        assertFalse(token.callbackSucceeded());
        _resolveAndSettle(1);
        token.arm(address(amm), abi.encodeCall(amm.settlePosition, (market)));
        uint256 before = token.balanceOf(trader);
        vm.prank(trader);
        assertEq(amm.settlePosition(market), 20e18);
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(trader) - before, 20e18);
    }
}

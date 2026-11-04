// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

/// @dev Honest balances; malicious behavior is confined to a selected recipient.
contract SellerPayoutToken is ERC20 {
    uint8 private immutable precision;
    uint8 public mode;
    address public seller;
    address public target;
    bytes public payload;
    bytes public callbackResult;
    bool public callbackSucceeded;
    uint256 public callbacks;

    error RecipientBlocked();

    constructor(uint8 decimals_) ERC20("Seller payout fixture", "SELL") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address seller_, uint8 mode_, address target_, bytes memory data)
        external
    {
        seller = seller_;
        mode = mode_;
        target = target_;
        payload = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to != seller) return super.transfer(to, amount);
        if (mode == 1) revert RecipientBlocked();
        if (mode == 2) {
            super.transfer(to, amount);
            return false;
        }
        if (mode == 3) {
            super.transfer(address(0xFEE), 1);
            return super.transfer(to, amount - 1);
        }
        if (mode == 4) super.transfer(address(0xFEE), 1);
        bool success = super.transfer(to, amount);
        if (target != address(0)) {
            ++callbacks;
            (callbackSucceeded, callbackResult) = target.call(payload);
        }
        return success;
    }
}

contract AmmPayoutSafetyTest is DualTokenBase {
    SellerPayoutToken private token;
    uint256 private unit;
    uint256 private positionId;
    address private otherMarket;

    function _prepare(uint8 decimals) private {
        token = new SellerPayoutToken(decimals);
        unit = 10 ** (18 - decimals);
        address[3] memory holders = [creator, trader, alice];
        for (uint256 i; i < holders.length; ++i) {
            token.mint(holders[i], 100_000e18 / unit);
            vm.startPrank(holders[i]);
            token.approve(address(marketFactory), type(uint256).max);
            token.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
        IMarketFactory.MarketParams memory p = _marketParams(
            "Seller payout isolation",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            B_BASE,
            0.5e18
        );
        vm.prank(creator);
        (market, positionId) = marketFactory.createMarket(p);
        vm.prank(creator);
        (otherMarket,) = marketFactory.createMarket(p);
        vm.prank(trader);
        amm.tradePositions(market, 1, 20e18, type(uint256).max);
        vm.prank(alice);
        amm.tradePositions(market, 0, 20e18, type(uint256).max);
    }

    function _state() private view returns (bytes32) {
        (uint256 yes, uint256 no) = amm.getPosition(market, trader);
        bytes32 engine = keccak256(
            abi.encode(
                amm.liquidityStateHash(market),
                yes,
                no,
                amm.getMarketCollateral(market),
                amm.claimableFloorLiability(market),
                amm.totalLiabilitiesOf(address(token)),
                amm.getMarketCollateral(otherMarket)
            )
        );
        LPPositionManager manager = LPPositionManager(amm.positionManager());
        bytes32 lpAndFees = keccak256(
            abi.encode(
                manager.residual(positionId, 0),
                manager.residual(positionId, 1),
                manager.residual(positionId, 2),
                vault.totalLiabilitiesOf(address(token)),
                vault.accountOf(market, IAmmFeeVault.Bucket.LP, address(token)),
                vault.accountOf(market, IAmmFeeVault.Bucket.RESOLUTION, address(token)),
                vault.accountOf(market, IAmmFeeVault.Bucket.OPERATOR, address(token))
            )
        );
        return keccak256(
            abi.encode(
                engine,
                lpAndFees,
                token.balanceOf(trader),
                token.balanceOf(alice),
                token.balanceOf(address(amm)),
                token.balanceOf(address(vault)),
                token.balanceOf(address(0xFEE)),
                token.allowance(address(amm), address(vault))
            )
        );
    }

    function _hostile(uint8 decimals, uint8 mode) private {
        _prepare(decimals);
        token.configure(trader, mode, address(0), "");
        bytes32 state = _state();
        vm.prank(trader);
        if (mode == 1) {
            vm.expectRevert(SellerPayoutToken.RecipientBlocked.selector);
        } else if (mode == 2) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    SafeERC20.SafeERC20FailedOperation.selector, address(token)
                )
            );
        } else {
            vm.expectRevert(AMMEngine.TransferAmountMismatch.selector);
        }
        amm.tradePositions(market, 1, -5e18, 0);
        assertEq(_state(), state, "failed payout rolls back every affected ledger");

        // The hostile recipient remains blocked; independent callers still exit
        // this market and buy/sell in a second market sharing the same token.
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = amm.tradePositions(market, 0, -5e18, 0);
        assertEq(token.balanceOf(alice) - before, paid / unit);
        vm.startPrank(alice);
        amm.tradePositions(otherMarket, 1, 5e18, type(uint256).max);
        amm.tradePositions(otherMarket, 1, -5e18, 0);
        vm.stopPrank();
        assertEq(
            token.balanceOf(address(amm)) * unit, amm.totalLiabilitiesOf(address(token))
        );
        token.configure(trader, 0, address(0), "");
        vm.prank(trader);
        amm.tradePositions(market, 1, -5e18, 0);
    }

    function test_SellPayoutBlockedRecipientAtomicAtSixAndEighteenDecimals() public {
        uint256 snapshot = vm.snapshotState();
        _hostile(6, 1);
        assertTrue(vm.revertToState(snapshot));
        _hostile(18, 1);
    }

    function test_SellPayoutFalseReturnAtomicAtSixAndEighteenDecimals() public {
        uint256 snapshot = vm.snapshotState();
        _hostile(6, 2);
        assertTrue(vm.revertToState(snapshot));
        _hostile(18, 2);
    }

    function test_SellPayoutInexactRecipientAtomicAtSixAndEighteenDecimals() public {
        uint256 snapshot = vm.snapshotState();
        _hostile(6, 3);
        assertTrue(vm.revertToState(snapshot));
        _hostile(18, 3);
    }

    function test_SellPayoutInexactSourceAtomicAtSixAndEighteenDecimals() public {
        uint256 snapshot = vm.snapshotState();
        _hostile(6, 4);
        assertTrue(vm.revertToState(snapshot));
        _hostile(18, 4);
    }

    function _callbacks(uint8 decimals) private {
        _prepare(decimals);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 1e18);
        bytes[7] memory calls = [
            abi.encodeCall(
                amm.tradePositions, (market, 1, int256(1e18), type(uint256).max)
            ),
            abi.encodeCall(amm.settlePosition, (market)),
            abi.encodeCall(amm.claimFloor, (market)),
            abi.encodeCall(amm.claimAvailable, (market, positionId, 0)),
            abi.encodeCall(amm.redeemLP, (market, 1)),
            abi.encodeCall(amm.redeemLPPosition, (market, positionId, 1)),
            abi.encodeCall(amm.increaseLiquidity, (market, 1e18, limits))
        ];
        for (uint256 i; i < calls.length; ++i) {
            token.configure(trader, 0, address(amm), calls[i]);
            uint256 before = token.balanceOf(trader);
            vm.prank(trader);
            uint256 paid = amm.tradePositions(market, 1, -1e18, 0);
            assertEq(token.balanceOf(trader) - before, paid / unit);
            assertEq(token.callbacks(), i + 1, "callback executed during payout");
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(),
                abi.encodeWithSelector(
                    ReentrancyGuard.ReentrancyGuardReentrantCall.selector
                ),
                "reentry rejected by guard, not by fixture preconditions"
            );
            assertEq(
                token.balanceOf(address(amm)) * unit,
                amm.totalLiabilitiesOf(address(token))
            );
        }
    }

    function test_SellPayoutCallbacksCannotReenterTradingClaimsOrLiquiditySixDecimals()
        public
    {
        _callbacks(6);
    }

    function test_SellPayoutCallbacksCannotReenterTradingClaimsOrLiquidityEighteenDecimals()
        public
    {
        _callbacks(18);
    }
}

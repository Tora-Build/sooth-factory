// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Local EVM evidence consumed by the TypeScript receipt replay tests.
/// No script, RPC, broadcast, private key, FFI or filesystem writes.
contract ClientReceiptReplayTest is DualTokenBase {
    function manager() internal view returns (LPPositionManager) {
        return LPPositionManager(amm.positionManager());
    }

    function test_clientReceiptReplayFixture() public {
        bool sixDecimals = vm.envOr("SOOTH_FACTORY_CLIENT_SIX_DECIMALS", false);
        IERC20 collateral = IERC20(address(east));
        if (sixDecimals) {
            MockUSDC tokenA = new MockUSDC("Client Token A", "CTA");
            collateral = IERC20(address(tokenA));
            tokenA.mint(creator, 1000e6);
            tokenA.mint(trader, 100_000e6);
            tokenA.mint(alice, 1000e6);
            vm.prank(creator);
            tokenA.approve(address(marketFactory), type(uint256).max);
            vm.prank(trader);
            tokenA.approve(address(amm), type(uint256).max);
        } else {
            east.mint(alice, 1000e18);
        }
        vm.recordLogs();
        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation1 = _marketParams(
            "Local client fixture", 0, deadline, address(collateral), B_BASE, 0.5e18
        );
        vm.prank(creator);
        (market,) = marketFactory.createMarket(creation1);
        vm.startPrank(alice);
        collateral.approve(address(amm), type(uint256).max);
        (uint256 tokenIn, uint256 units, uint256 price, bytes32 stateHash) =
            amm.quoteLiquidityWithState(market, 10e18);
        bytes memory added = _clientCall(
            address(amm),
            vm.envOr(
                "SOOTH_FACTORY_CLIENT_ADD_CALL",
                abi.encodeCall(
                    IAMMEngine.increaseLiquidity,
                    (
                        market,
                        10e18,
                        IAMMEngine.LiquidityLimits(
                            tokenIn, units, price, price, block.timestamp, stateHash
                        )
                    )
                )
            )
        );
        (uint256 receipt,) = abi.decode(added, (uint256, uint256));
        manager().transfer(bob, receipt, units / 2);
        vm.stopPrank();
        _seedAmmPosition();
        _resolveAndSettle(2);
        vm.startPrank(alice);
        uint256 burned = manager().balanceOf(alice, receipt) / 2;
        _clientCall(
            address(amm),
            vm.envOr(
                "SOOTH_FACTORY_CLIENT_REDEEM_CALL",
                abi.encodeCall(IAMMEngine.redeemLPPosition, (market, receipt, burned))
            )
        );
        _clientCall(
            address(amm),
            vm.envOr(
                "SOOTH_FACTORY_CLIENT_FLOOR_CALL",
                abi.encodeCall(IAMMEngine.claimFloor, (market))
            )
        );
        _clientCall(
            address(vault),
            vm.envOr(
                "SOOTH_FACTORY_CLIENT_FEES_CALL",
                abi.encodeCall(IAmmFeeVault.claimLPDividendForPosition, (market, receipt))
            )
        );
        vm.stopPrank();
        assertGe(
            collateral.balanceOf(address(amm)) * (sixDecimals ? 1e12 : 1),
            amm.totalLiabilitiesOf(address(collateral))
        );
        assertGe(
            collateral.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(collateral))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Fixed schema followed by the actual EVM logs (topics, data, emitter).
        console2.logBytes(
            abi.encode(
                address(amm),
                address(vault),
                amm.positionManager(),
                market,
                receipt,
                alice,
                bob,
                manager().totalSupply(receipt),
                manager().balanceOf(alice, receipt),
                manager().balanceOf(bob, receipt),
                logs
            )
        );
    }

    function _clientCall(address target, bytes memory data)
        internal
        returns (bytes memory result)
    {
        bool success;
        (success, result) = target.call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

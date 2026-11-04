// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {
    FeeOnTransferToken,
    RevertingToken,
    ReturnsFalseToken
} from "../mocks/HostileTokens.sol";

/// @notice Explicit token admission is complemented by exact receipt checks.
/// @dev Until these tests existed every Token-A path ran on a well-behaved token, so
///      the measured-receipt defences were never exercised against anything hostile.
///      Each test names one misbehaviour and the property that must survive it.
///
///      This is a first slice, not the full adversarial suite the architecture asks
///      for: rebasing, denylist and callback tokens are not covered here.
contract HostileTokenATest is DualTokenBase {
    FeeOnTransferToken internal fot;
    RevertingToken internal reverting;
    ReturnsFalseToken internal silent;

    function setUp() public override {
        super.setUp();
        fot = new FeeOnTransferToken(100); // 1% skimmed on every transfer
        reverting = new RevertingToken();
        silent = new ReturnsFalseToken();
        _fund(address(fot));
        _fund(address(reverting));
        _fund(address(silent));
    }

    function _fund(address token) internal {
        (bool ok,) = token.call(
            abi.encodeWithSignature("mint(address,uint256)", creator, 1_000_000e18)
        );
        require(ok, "mint");
        (ok,) = token.call(
            abi.encodeWithSignature("mint(address,uint256)", trader, 1_000_000e18)
        );
        require(ok, "mint");
        address[2] memory holders = [creator, trader];
        address[2] memory spenders = [address(amm), address(marketFactory)];
        for (uint256 i = 0; i < holders.length; ++i) {
            for (uint256 j = 0; j < spenders.length; ++j) {
                vm.prank(holders[i]);
                (ok,) = token.call(
                    abi.encodeWithSignature(
                        "approve(address,uint256)", spenders[j], type(uint256).max
                    )
                );
                require(ok, "approve");
            }
        }
    }

    function _create(address token) internal returns (address created) {
        uint64 dl = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation1 =
            _marketParams("hostile token A", 0, dl, token, B_BASE, 0.5e18);
        vm.prank(creator);
        (created,) = marketFactory.createMarket(creation1);
    }

    /// A token that skims a cut must be rejected outright: the engine would otherwise
    /// credit collateral that never arrived, under-backing every holder of that market.
    function test_feeOnTransferTokenCannotFundAMarket() public {
        // Named error, not a bare expectRevert: a bare one would also pass on an
        // allowance mistake in the test itself and prove nothing about the defence.
        IMarketFactory.MarketParams memory p = _marketParams(
            "tax", 0, uint64(block.timestamp + 20 days), address(fot), B_BASE, 0.5e18
        );
        vm.prank(creator);
        vm.expectRevert(MarketFactory.TransferAmountMismatch.selector);
        marketFactory.createMarket(p);
    }

    /// With the fee switched off the same contract behaves, proving the rejection above
    /// is about the shortfall and not about the token being unfamiliar.
    function test_sameTokenIsAcceptedOnceItStopsSkimming() public {
        FeeOnTransferToken honest = new FeeOnTransferToken(0);
        _fund(address(honest));
        address created = _create(address(honest));
        assertEq(amm.tokenAOf(created), address(honest));
    }

    /// A transfer that reverts must roll the whole call back, leaving no entitlement
    /// consumed and no collateral recorded.
    function test_revertingTransferRollsBackCleanly() public {
        address created = _create(address(reverting));
        uint256 collateralBefore = amm.getMarketCollateral(created);

        reverting.setFailTransfers(true);

        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(created, 10e18);

        vm.prank(trader);
        vm.expectRevert();
        amm.increaseLiquidity(created, 10e18, limits);

        assertEq(
            amm.getMarketCollateral(created),
            collateralBefore,
            "no collateral recorded by a failed add"
        );
    }

    /// A token that returns false instead of reverting must not be treated as success.
    /// SafeERC20 is what stands between this and silent under-collateralisation.
    function test_returnsFalseTokenIsNotTreatedAsSuccess() public {
        address created = _create(address(silent));
        uint256 collateralBefore = amm.getMarketCollateral(created);

        silent.setReturnFalse(true);

        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(created, 10e18);

        vm.prank(trader);
        vm.expectRevert();
        amm.increaseLiquidity(created, 10e18, limits);

        assertEq(
            amm.getMarketCollateral(created),
            collateralBefore,
            "a false return never becomes recorded collateral"
        );
    }
}

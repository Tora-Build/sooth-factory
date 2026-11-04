// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {LyingBalanceToken, WithholdingReceiptToken} from "../mocks/HostileTokens.sol";

/// @notice Exact source and destination deltas detect one-sided phantom receipts.
/// @dev Tokens fabricating both sides remain outside the supported trust model.
contract DishonestTokenTrustTest is DualTokenBase {
    LyingBalanceToken internal liar;

    function setUp() public override {
        super.setUp();
        liar = new LyingBalanceToken();
        liar.mint(address(this), 1_000_000e18);
    }

    /// A constant over-report cancels in `after - before`. This is why a static
    /// `lieAbout` is not the T-1 protocol case — every delta check still sees the
    /// real movement.
    function test_constantOverReportDoesNotChangeDeltas() public {
        uint256 realMint = 100e18;
        liar.lieAbout(address(vault), 5000e18);
        uint256 reportedBefore = liar.balanceOf(address(vault));
        liar.mint(address(vault), realMint);
        assertEq(
            liar.balanceOf(address(vault)) - reportedBefore,
            realMint,
            "constant inflation cancels in a delta"
        );
    }

    /// The vault's solvency statement is only as good as the balances the token
    /// reports. An honest token is the contrast case.
    function test_theMeasurementIsAboutDeltasNotHonesty() public view {
        assertGe(
            east.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(east)),
            "solvency is asserted against a reported balance"
        );
    }

    /// The old one-sided phantom receipt fixture must now revert atomically.
    function test_destinationOnlyFalseDeltaCannotCreditOrConsumeOtherBacking() public {
        WithholdingReceiptToken token = new WithholdingReceiptToken();
        token.mint(creator, 1_000_000e18);
        token.mint(trader, 1_000_000e18);
        vm.prank(creator);
        token.approve(address(marketFactory), type(uint256).max);
        vm.prank(trader);
        token.approve(address(amm), type(uint256).max);

        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory creation1 = _marketParams(
            "honest backing market", 0, deadline, address(token), B_BASE, 0.5e18
        );
        vm.prank(creator);
        (address market1,) = marketFactory.createMarket(creation1);
        IMarketFactory.MarketParams memory creation2 = _marketParams(
            "false-credit market", 0, deadline, address(token), B_BASE, 0.5e18
        );
        vm.prank(creator);
        (address market2,) = marketFactory.createMarket(creation2);

        vm.prank(trader);
        amm.tradePositions(market1, 1, 400e18, type(uint256).max);

        uint256 realVault = token.realBalanceOf(address(vault));
        uint256 liabilitiesBefore = vault.totalLiabilitiesOf(address(token));
        assertGt(realVault, 0, "market 1 deposited real fee cash");
        assertEq(realVault, liabilitiesBefore, "honest liabilities match real cash");

        token.setVault(address(vault));
        token.setLying(true);

        vm.prank(trader);
        vm.expectRevert(VenueFeeVault.DepositAmountMismatch.selector);
        amm.tradePositions(market2, 1, 400e18, type(uint256).max);
        assertEq(token.realBalanceOf(address(vault)), realVault);
        assertEq(vault.totalLiabilitiesOf(address(token)), liabilitiesBefore);
        assertEq(vault.marketLiabilitiesOf(market2, address(token)), 0);
        token.setLying(false);
        assertEq(vault.claimOperatorFees(market2), 0);

        _createMarket();
        _seedAmmPosition();
        assertGe(
            east.balanceOf(address(vault)),
            vault.totalLiabilitiesOf(address(east)),
            "a different Token A stays its own ledger"
        );
        assertEq(
            vault.totalLiabilitiesOf(address(liar)),
            0,
            "an unused token's accounting is a separate ledger"
        );
    }
}

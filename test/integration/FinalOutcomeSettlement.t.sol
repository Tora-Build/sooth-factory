// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {AlternateToken6} from "./PerMarketTokenA.t.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {VenueFeeVault} from "src/fees/VenueFeeVault.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {LPPositionView} from "../reference/LPPositionView.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";

/// @notice Two simultaneous Token-A markets exercise final outcome settlement,
/// partial LP burns, immediate sell payouts, and isolated USDG fee liabilities.
contract FinalOutcomeSettlementTest is DualTokenBase {
    struct Venue {
        address market;
        IERC20 token;
        LPPositionView lp;
        uint8 decimals;
        uint256 salePaid;
    }

    struct Receipts {
        uint256 seller;
        uint256 lp;
        uint256 yesBook;
        uint256 noBook;
    }

    Venue[2] internal venues;

    function _prepare() internal {
        AlternateToken6 six = new AlternateToken6();
        six.mint(creator, 1000e6);
        six.mint(trader, 1000e6);
        vm.prank(creator);
        six.approve(address(marketFactory), type(uint256).max);
        vm.prank(trader);
        six.approve(address(amm), type(uint256).max);
        _createVenue(0, address(east), 18);
        _createVenue(1, address(six), 6);
        _assertBothSolvent();
    }

    function _createVenue(uint256 index, address token, uint8 decimals) internal {
        uint64 dl = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory p = _marketParams(
            "Final outcome after direct seller payout", 0, dl, token, B_BASE, 0.5e18
        );
        vm.prank(creator);
        (address m, uint256 l) = marketFactory.createMarket(p);
        vm.startPrank(trader);
        amm.tradePositions(m, 1, 20e18, type(uint256).max);
        amm.tradePositions(m, 0, 12e18, type(uint256).max);
        uint256 beforeSell = IERC20(token).balanceOf(trader);
        uint256 salePaid =
            DecimalMath.fromWad(amm.tradePositions(m, 1, -5e18, 0), decimals);
        salePaid += DecimalMath.fromWad(amm.tradePositions(m, 0, -3e18, 0), decimals);
        assertEq(IERC20(token).balanceOf(trader) - beforeSell, salePaid);
        vm.stopPrank();
        vm.prank(bob);
        orderEngine.placeOrder(m, BookTestOrders.buy(0, 400, 10e18, 256));
        vm.prank(alice);
        orderEngine.placeOrder(m, BookTestOrders.buy(1, 600, 10e18, 10));
        venues[index] = Venue(
            m,
            IERC20(token),
            new LPPositionView(LPPositionManager(amm.positionManager()), l),
            decimals,
            salePaid
        );
    }

    function _finish(uint8 outcome, bool timeout) internal {
        for (uint256 i; i < 2; i++) {
            vm.prank(resolver);
            adjudicator.resolve(venues[i].market, outcome, keccak256("posted"));
        }
        if (timeout) {
            ITruthMarket tm = ITruthMarket(venues[0].market);
            vm.warp(uint256(tm.deadline()) + tm.invalidationBuffer());
            for (uint256 i; i < 2; i++) {
                vault.finalize(venues[i].market);
            }
        } else {
            vm.warp(block.timestamp + 1 hours);
            for (uint256 i; i < 2; i++) {
                adjudicator.settle(venues[i].market);
            }
        }
        for (uint256 i; i < 2; i++) {
            assertFalse(ITruthMarket(venues[i].market).isLiquidityOpen());
        }
    }

    function test_Yes_TwoTokens_PartialLPAndDirectPayoutClaimOrders() public {
        _claimMatrix(1, false);
    }

    function test_No_TwoTokens_PartialLPAndDirectPayoutClaimOrders() public {
        _claimMatrix(0, false);
    }

    function test_Invalid_TwoTokens_PartialLPAndDirectPayoutClaimOrders() public {
        _claimMatrix(2, false);
    }

    function test_TimeoutInvalid_TwoTokens_PartialLPAndDirectPayoutClaimOrders() public {
        _claimMatrix(1, true);
    }

    function _claimMatrix(uint8 proposedOutcome, bool timeout) internal {
        _prepare();
        _finish(proposedOutcome, timeout);
        uint8 outcome = timeout ? 2 : proposedOutcome;
        uint256 snapshot = vm.snapshotState();
        Receipts[2] memory baseline = _claimOrder(0, outcome);
        for (uint8 order = 1; order < 3; order++) {
            assertTrue(vm.revertToState(snapshot));
            Receipts[2] memory actual = _claimOrder(order, outcome);
            for (uint256 i; i < 2; i++) {
                assertEq(actual[i].seller, baseline[i].seller);
                assertEq(actual[i].lp, baseline[i].lp);
                assertEq(actual[i].yesBook, baseline[i].yesBook);
                assertEq(actual[i].noBook, baseline[i].noBook);
            }
        }
    }

    function _claimOrder(uint8 order, uint8 outcome)
        internal
        returns (Receipts[2] memory receipts)
    {
        // Reverse market order as well as each market's internal claim order.
        for (uint256 step; step < 2; step++) {
            uint256 index = order == 1 ? 1 - step : step;
            receipts[index] = _claimVenue(venues[index], order, outcome);
        }
    }

    function _claimVenue(Venue storage v, uint8 order, uint8 outcome)
        internal
        returns (Receipts memory result)
    {
        Receipts memory before = Receipts(
            v.token.balanceOf(trader),
            v.token.balanceOf(creator),
            usdc.balanceOf(alice),
            usdc.balanceOf(bob)
        );
        uint256 creatorBookBefore = usdc.balanceOf(creator);
        uint256 bookLiability = bookVault.marketLiabilitiesOf(v.market, address(usdc));
        uint256 lpAmount = v.lp.balanceOf(creator);
        if (order == 1) _position(v, outcome);
        _burnAndClaim(v, lpAmount / 2);
        if (order == 0) _position(v, outcome);
        _burnAndClaim(v, v.lp.balanceOf(creator));
        if (order == 2) _position(v, outcome);
        vm.prank(alice);
        orderEngine.settlePosition(v.market);
        vm.prank(bob);
        orderEngine.settlePosition(v.market);
        assertEq(usdc.balanceOf(creator), creatorBookBefore, "LP received USDG");
        assertEq(vault.lpEntitlementOf(v.market, creator, address(usdc)), 0);
        assertEq(bookVault.marketLiabilitiesOf(v.market, address(usdc)), bookLiability);
        assertGt(bookLiability, 0);
        assertEq(bookVault.sweepUnattributedSurplus(address(usdc)), 0);
        bookVault.claimProtocolFees(v.market);
        if (
            ITruthMarket(v.market).settlementKind()
                == ITruthMarket.SettlementKind.INVALIDATED
        ) {
            bookVault.claimTimeoutRefund(v.market, alice);
        } else {
            bookVault.claimResolutionFees(v.market);
        }
        assertEq(bookVault.marketLiabilitiesOf(v.market, address(usdc)), 0);
        assertEq(v.lp.totalSupply(), 0);
        // Sub-native fractions stay owned and reserved instead of returning to LP capital.
        assertLt(amm.claimableFloorLiability(v.market), 10 ** (18 - v.decimals));
        result = Receipts(
            v.token.balanceOf(trader) - before.seller,
            v.token.balanceOf(creator) - before.lp,
            usdc.balanceOf(alice) - before.yesBook,
            usdc.balanceOf(bob) - before.noBook
        );
        uint256 payout = outcome == 1 ? 15e18 : outcome == 0 ? 9e18 : 12e18;
        assertEq(result.seller, DecimalMath.fromWad(payout, v.decimals));
        _assertBothSolvent();
    }

    function _position(Venue storage v, uint8 outcome) internal {
        uint256 expected = outcome == 1 ? 15e18 : outcome == 0 ? 9e18 : 12e18;
        vm.prank(trader);
        assertEq(amm.settlePosition(v.market), expected);
        vm.prank(trader);
        vm.expectRevert(AMMEngine.NoPosition.selector);
        amm.settlePosition(v.market);
        _assertBothSolvent();
    }

    function _burnAndClaim(Venue storage v, uint256 amount) internal {
        uint256 sellerBefore = v.token.balanceOf(trader);
        vm.prank(creator);
        uint256 floor = amm.redeemLP(v.market, amount);
        if (floor > 0) {
            vm.prank(creator);
            amm.claimFloor(v.market);
        }
        if (vault.lpEntitlementOf(v.market, creator, address(v.token)) > 0) {
            vm.prank(creator);
            vault.claimLPDividend(v.market);
        }
        assertEq(
            v.token.balanceOf(trader), sellerBefore, "LP claims cannot affect paid seller"
        );
        _assertBothSolvent();
    }

    function test_DirectPayouts_TwoTokens_PersistThroughResolvingAndAttested() public {
        _prepare();
        for (uint256 i; i < 2; i++) {
            Venue storage v = venues[i];
            assertGt(v.salePaid, 0);
            uint256 paidBalance = v.token.balanceOf(trader);
            vm.prank(resolver);
            adjudicator.resolve(v.market, 1, keccak256("posted"));
            assertTrue(ITruthMarket(v.market).isResolving());
            assertEq(v.token.balanceOf(trader), paidBalance);
            vm.prank(trader);
            vm.expectRevert(AMMEngine.MarketNotLive.selector);
            amm.tradePositions(v.market, 1, -1e18, 0);
            adjudicator.attest(v.market, bytes(""));
            assertTrue(ITruthMarket(v.market).isAttested());
            assertFalse(ITruthMarket(v.market).isSettled());
            assertEq(v.token.balanceOf(trader), paidBalance);
            _assertBothSolvent();
        }
    }

    function test_InvalidFeeDistinction_AdjudicatedVersusTimeout() public {
        _prepare();
        uint256 snapshot = vm.snapshotState();
        _finish(2, false);
        _assertInvalidFees(false);
        assertTrue(vm.revertToState(snapshot));
        _finish(2, true);
        _assertInvalidFees(true);
    }

    function _assertInvalidFees(bool timeout) internal {
        for (uint256 i; i < 2; i++) {
            Venue storage v = venues[i];
            assertEq(ITruthMarket(v.market).winningOutcome(), 2);
            vault.finalize(v.market);
            uint256 bookAdj = bookVault.accountOf(
                v.market, IBookFeeVault.Bucket.RESOLUTION, address(usdc)
            );
            assertGt(bookAdj, 0);
            if (timeout) {
                assertEq(
                    vault.accountOf(
                        v.market, IAmmFeeVault.Bucket.RESOLUTION, address(v.token)
                    ),
                    0
                );
                vm.expectRevert(VenueFeeVault.ResolutionForfeited.selector);
                bookVault.claimResolutionFees(v.market);
                assertEq(bookVault.claimTimeoutRefund(v.market, alice), bookAdj);
                assertEq(
                    bookVault.accountOf(
                        v.market, IBookFeeVault.Bucket.RESOLUTION, address(usdc)
                    ),
                    0
                );
            } else {
                uint256 tokenAdj = vault.accountOf(
                    v.market, IAmmFeeVault.Bucket.RESOLUTION, address(v.token)
                );
                assertGt(tokenAdj, 0);
                assertEq(vault.claimResolutionFees(v.market), tokenAdj);
                assertEq(bookVault.claimResolutionFees(v.market), bookAdj);
            }
            assertEq(vault.lpEntitlementOf(v.market, creator, address(usdc)), 0);
            _assertBothSolvent();
        }
    }

    function _assertBothSolvent() internal view {
        for (uint256 i; i < 2; i++) {
            Venue storage v = venues[i];
            uint256 liability =
                amm.getMarketCollateral(v.market) + amm.claimableFloorLiability(v.market);
            assertEq(amm.totalLiabilitiesOf(address(v.token)), liability);
            assertGe(
                v.token.balanceOf(address(amm)),
                DecimalMath.fromWadCeil(liability, v.decimals)
            );
            assertGe(
                v.token.balanceOf(address(vault)),
                vault.totalLiabilitiesOf(address(v.token))
            );
        }
        assertGe(
            usdc.balanceOf(address(bookVault)),
            bookVault.totalLiabilitiesOf(address(usdc))
        );
        assertGe(
            usdc.balanceOf(address(orderEngine)),
            orderEngine.getCollateralBacking(venues[0].market)
                + orderEngine.getCollateralBacking(venues[1].market)
        );
    }
}

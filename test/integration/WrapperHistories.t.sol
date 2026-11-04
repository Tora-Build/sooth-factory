// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITruthMarket} from "src/interfaces/ITruthMarket.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";
import {LPPositionToken} from "src/LPPositionToken.sol";

contract WrapTokenA is ERC20 {
    uint8 private immutable precision;

    constructor(uint8 decimals_) ERC20("Wrap Token A", "WTA") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice LP wrapper histories, at both Token-A precisions.
/// @dev Cases covered: complete unwrapping followed by TIMEOUT
///      settlement, earned fees preserved across pre- AND post-settlement transfers,
///      and native-versus-wrapped histories with transfer/unwrap/rewrap intervals,
///      exercised at 6 and 18 decimals.
///
///      The differential is the same holder and the same units, snapshot-restored:
///      one history never touches the wrapper, the other wraps, unwraps and rewraps
///      around the same trades. Those two payouts must match exactly. Comparing two
///      holders of an odd split is not this property.
abstract contract WrapperHistories is DualTokenBase {
    WrapTokenA internal tokenA;
    LPPositionManager internal manager;
    LPPositionToken internal wrapper;
    uint256 internal id;

    function tokenADecimals() internal pure virtual returns (uint8);

    /// @dev Same-holder remainder after wrap/unwrap/rewrap, in native units.
    ///      Measured, not a universal bound: 0 at 18 decimals, 1 at 6. Not the
    ///      leftover-unit gap from splitting an odd supply across two holders.
    function tolerance() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        _deployStack(address(usdc));

        _fundAndApprove();

        tokenA = new WrapTokenA(tokenADecimals());
        uint256 unit = 10 ** tokenADecimals();
        address[3] memory who = [creator, trader, bob];
        for (uint256 i; i < who.length; ++i) {
            tokenA.mint(who[i], 10_000_000 * unit);
            vm.startPrank(who[i]);
            tokenA.approve(address(marketFactory), type(uint256).max);
            tokenA.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }

        uint64 deadline = uint64(block.timestamp + 20 days);
        IMarketFactory.MarketParams memory params = _marketParams(
            "Wrapper history market", 0, deadline, address(tokenA), B_BASE, 0.5e18
        );
        vm.prank(creator);
        (market,) = marketFactory.createMarket(params);
        manager = LPPositionManager(amm.positionManager());
        id = marketFactory.getLPToken(market);
        wrapper = new LPPositionToken(manager, id);
    }

    function _accrueFees() internal {
        vm.prank(trader);
        amm.tradePositions(market, 1, 400e18, type(uint256).max);
    }

    /// Settlement by timeout: nobody resolves, the buffer lapses, anyone invalidates.
    /// This is the branch that turns on `contingentPayable`, so the wrapper's harvest
    /// takes its timeout path rather than the ordinary one.
    function _settleByTimeout() internal {
        ITruthMarket tm = ITruthMarket(market);
        vm.warp(uint256(tm.deadline()) + uint256(tm.invalidationBuffer()) + 1);
        tm.invalidate();
        assertTrue(tm.isSettled(), "timeout settlement");
    }

    function _wrapAll(address holder) internal returns (uint256 amount) {
        amount = manager.balanceOf(holder, id);
        vm.startPrank(holder);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(amount);
        vm.stopPrank();
    }

    // ── the cases the issue names ────────────────────────────────────────────

    /// Everyone unwraps, then the market settles by TIMEOUT. The fees earned while
    /// wrapped are still owed and still payable — this is why `settle()` must accept
    /// a zero supply.
    function test_completeUnwrapThenTimeoutSettlement() public {
        uint256 units = _wrapAll(creator);
        _accrueFees();

        vm.prank(creator);
        wrapper.unwrap(units);
        assertEq(wrapper.totalSupply(), 0, "fully unwrapped");

        _settleByTimeout();
        wrapper.settle();
        assertEq(wrapper.supplyAtSettle(), 0);
        assertTrue(wrapper.contingentPayable(), "timeout opens the contingent leg");

        uint256 before = tokenA.balanceOf(creator);
        vm.prank(creator);
        uint256 paid = wrapper.claimFees();
        assertGt(paid, 0, "fees earned while wrapped survive a full unwrap");
        assertEq(tokenA.balanceOf(creator) - before, paid);
    }

    /// Entitlement follows the ERC-20 balance over time, on BOTH sides of settlement.
    /// A post-settlement transfer conveys the principal claim and not the seller's
    /// earned fees — the documented behaviour, asserted rather than assumed.
    function test_feesSurvivePreAndPostSettlementTransfers() public {
        uint256 units = _wrapAll(creator);
        _accrueFees();

        // Pre-settlement: half to bob, after all accrual.
        vm.prank(creator);
        wrapper.transfer(bob, units / 2);

        _settleByTimeout();
        wrapper.settle();

        uint256 creatorFees = wrapper.feesClaimable(creator);
        assertGt(creatorFees, 0, "the creator earned them");
        assertEq(wrapper.feesClaimable(bob), 0, "bob held nothing while they accrued");

        // Post-settlement: bob passes his units on. Principal moves, fees do not.
        vm.prank(bob);
        wrapper.transfer(alice, units / 2);
        assertEq(wrapper.feesClaimable(alice), 0, "a late buyer inherits no fees");
        assertEq(wrapper.feesClaimable(creator), creatorFees, "the earner keeps them");

        vm.prank(creator);
        assertEq(wrapper.claimFees(), creatorFees, "and can still collect");
    }

    /// The differential: the SAME holder, the SAME units, two restored histories.
    /// One never touches the wrapper; the other wraps, unwraps and rewraps around
    /// the same trades. Comparing two holders of an odd split is not this property
    /// — that measures the leftover unit, not wrapping (issue #1 follow-up, item 2).
    function test_nativeAndWrappedHistoriesAgree() public {
        uint256 units = manager.balanceOf(creator, id);
        uint256 snap = vm.snapshotState();

        _accrueFees();
        _accrueFees();
        _accrueFees();
        _settleByTimeout();

        uint256 nativeBefore = tokenA.balanceOf(creator);
        vm.prank(creator);
        amm.claimAvailable(market, id, units);
        uint256 nativeGot = tokenA.balanceOf(creator) - nativeBefore;

        vm.revertToState(snap);

        vm.startPrank(creator);
        manager.setOperator(address(wrapper), true);
        wrapper.wrap(units);
        vm.stopPrank();

        _accrueFees();
        vm.prank(creator);
        wrapper.unwrap(units / 2);
        _accrueFees();
        vm.prank(creator);
        wrapper.wrap(units / 2);
        _accrueFees();

        _settleByTimeout();
        wrapper.settle();

        uint256 wrappedBefore = tokenA.balanceOf(creator);
        vm.startPrank(creator);
        wrapper.redeem(wrapper.balanceOf(creator));
        amm.claimAvailable(market, id, manager.balanceOf(creator, id));
        vm.stopPrank();
        uint256 wrappedGot = tokenA.balanceOf(creator) - wrappedBefore;

        assertApproxEqAbs(
            wrappedGot,
            nativeGot,
            tolerance(),
            "wrapping must not change what this holder is owed"
        );
    }

    /// Nothing above may let the wrapper promise more than it holds.
    function test_wrapperNeverOwesMoreThanItHolds() public {
        uint256 units = _wrapAll(creator);
        _accrueFees();
        vm.prank(creator);
        wrapper.transfer(bob, units / 3);
        _accrueFees();

        _settleByTimeout();
        wrapper.settle();

        uint256 promised = wrapper.feesClaimable(creator) + wrapper.feesClaimable(bob);
        assertLe(promised, wrapper.feePot(), "fee promises fit the fee cash");
        assertGe(
            tokenA.balanceOf(address(wrapper)),
            wrapper.proceeds() + wrapper.feePot(),
            "and the wrapper holds both pots"
        );
    }
}

contract WrapperHistoriesTokenA6 is WrapperHistories {
    function tokenADecimals() internal pure override returns (uint8) {
        return 6;
    }

    function tolerance() internal pure override returns (uint256) {
        return 1;
    }
}

contract WrapperHistoriesTokenA18 is WrapperHistories {
    function tokenADecimals() internal pure override returns (uint8) {
        return 18;
    }

    function tolerance() internal pure override returns (uint256) {
        return 0;
    }
}

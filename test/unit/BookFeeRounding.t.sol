// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {DualTokenBase, East18E} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IBookFeeVault} from "src/interfaces/IBookFeeVault.sol";

contract FeeRoundingToken is ERC20 {
    uint8 private immutable precision;

    constructor(uint8 decimals_) ERC20("Book token", "BOOK") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice The book taker fee rounds UP, once per order.
///
///         History: until 2026-10-08 it was computed in WAD and floored twice, and
///         below a per-tick threshold the whole fee reached zero while the fill
///         executed — on the shipped 6-decimal book at 1%, any fill under 0.1 shares at
///         YES tick 1 traded free; at 0.01%, just under 10 shares. That was the one
///         flow where sub-unit dust favoured the payer, against `ROUNDING-SPEC.md` R1.
///         Owner decision: ceil it. Inbound to custody rounds up everywhere else, and
///         it is the remedy that costs an honest taker at most one base unit.
///
///         Rounding once per ORDER rather than per fill matters: a fee ceiled on each
///         fill would charge a sweep across N levels up to N extra units. The engine
///         sums `amount × min(tick, 1000 − tick)` exactly across every fill and rounds
///         the total (`OrderEngine._settleTaker`).
abstract contract BookFeeRoundingBase is DualTokenBase {
    FeeRoundingToken internal book;

    function bookDecimals() internal pure virtual returns (uint8);

    function feeBps() internal pure virtual returns (uint16);

    function setUp() public virtual override {
        east = new East18E();
        usdc = new MockUSDC("MockUSDC", "MUSDC");
        book = new FeeRoundingToken(bookDecimals());
        _deployStack(address(book));
        IBookFeeVault.BookConfig memory cfg = _bookConfig();
        cfg.feeBps = feeBps();
        bookVault.publishBookConfig(cfg);
        _fundAndApprove();

        uint256 unit = 10 ** bookDecimals();
        address[3] memory holders = [alice, bob, trader];
        for (uint256 i; i < holders.length; ++i) {
            book.mint(holders[i], 1_000_000_000 * unit);
            vm.prank(holders[i]);
            book.approve(address(orderEngine), type(uint256).max);
        }
        _createMarket();
    }

    function _unitWad() internal pure returns (uint256) {
        return 10 ** (18 - bookDecimals());
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b + (a % b == 0 ? 0 : 1);
    }

    function _feeTicks(uint16 yesTick) internal pure returns (uint256) {
        uint256 complement = 1000 - uint256(yesTick);
        return uint256(yesTick) < complement ? uint256(yesTick) : complement;
    }

    /// The exact fee in WAD, as a rational: `num / 1e7`.
    function _exactNumerator(uint16 yesTick, uint128 amount)
        internal
        pure
        returns (uint256)
    {
        return uint256(amount) * _feeTicks(yesTick) * feeBps();
    }

    /// The engine's rule restated: exact, then one ceil to WAD, one ceil to native.
    function _predictFee(uint256 numerator) internal pure returns (uint256) {
        return _ceilDiv(_ceilDiv(numerator, 1000 * 10_000), _unitWad());
    }

    /// Bob rests depth as a YES ask at `yesTick` (sized up past dust if needed);
    /// alice takes `amount`; bob's remainder is cancelled. Returns the vault delta.
    function _takeAndMeasureFee(uint16 yesTick, uint128 amount)
        internal
        returns (uint256 fee)
    {
        uint128 minRest = orderEngine.getMinRestingOrder(1000 - yesTick);
        uint128 restAmount = amount < minRest ? minRest : amount;
        vm.prank(bob);
        orderEngine.placeOrder(
            market, BookTestOrders.buy(0, 1000 - yesTick, restAmount, 256)
        );

        uint256 vaultBefore = book.balanceOf(address(bookVault));
        int256 netBefore = orderEngine.getNet(market, alice);
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, yesTick, amount, 256));
        assertEq(
            orderEngine.getNet(market, alice) - netBefore,
            int256(uint256(amount)),
            "the fill executed in full"
        );
        fee = book.balanceOf(address(bookVault)) - vaultBefore;

        (, uint256 remaining) = orderEngine.getOrdersAtTick(market, 1, yesTick);
        if (remaining > 0) {
            vm.prank(bob);
            orderEngine.cancel(market, 1, yesTick);
        }
    }

    function test_thePredictionMatchesWhatTheEngineCharges() public {
        uint16[4] memory ticks = [uint16(1), 100, 500, 999];
        uint128[4] memory sizes = [uint128(1e12), 1e18, 7_777_777_777_777_777, 123e18];
        for (uint256 s; s < sizes.length; ++s) {
            sizes[s] = uint128(_ceilDiv(sizes[s], _unitWad()) * _unitWad());
        }
        for (uint256 t; t < ticks.length; ++t) {
            for (uint256 s; s < sizes.length; ++s) {
                assertEq(
                    _takeAndMeasureFee(ticks[t], sizes[s]),
                    _predictFee(_exactNumerator(ticks[t], sizes[s])),
                    "engine fee == ceil(exact)"
                );
            }
        }
    }

    /// No size trades free, at any tick, decimal count or rate tested — and the fee
    /// is never more than one base unit above the exact amount.
    function test_noFillTradesFreeAndNoneIsOverchargedByMoreThanAUnit() public {
        uint16[4] memory ticks = [uint16(1), 100, 500, 999];
        uint128[3] memory sizes = [uint128(1e12), 99_999_999_999_999_999, 1e18];
        for (uint256 s; s < sizes.length; ++s) {
            sizes[s] = uint128(_ceilDiv(sizes[s], _unitWad()) * _unitWad());
        }
        for (uint256 t; t < ticks.length; ++t) {
            for (uint256 s; s < sizes.length; ++s) {
                uint256 fee = _takeAndMeasureFee(ticks[t], sizes[s]);
                assertGt(fee, 0, "a non-zero rate never rounds to a free fill");
                // exact fee in native = num / (1e7 * unitWad), a rational
                uint256 num = _exactNumerator(ticks[t], sizes[s]);
                assertLe(
                    fee * 1000 * 10_000 * _unitWad(),
                    num + 1000 * 10_000 * _unitWad(),
                    "at most one base unit above the exact fee"
                );
            }
        }
    }

    /// One rounding per order: a sweep across three levels pays ceil(Σ exact), not
    /// Σ ceil(exact per level). Each level's exact fee here is a fraction of a unit.
    function test_aSweepIsRoundedOnceNotOncePerLevel() public {
        uint128 size = uint128(_unitWad()) * 3; // tiny: well under one unit of fee
        uint16[3] memory ticks = [uint16(101), 103, 107];
        uint256 numerator;
        uint128 total;
        for (uint256 i; i < ticks.length; ++i) {
            uint128 minRest = orderEngine.getMinRestingOrder(1000 - ticks[i]);
            uint128 rest = size < minRest ? minRest : size;
            vm.prank(bob);
            orderEngine.placeOrder(
                market, BookTestOrders.buy(0, 1000 - ticks[i], rest, 256)
            );
            numerator += _exactNumerator(ticks[i], rest);
            total += rest;
        }
        uint256 vaultBefore = book.balanceOf(address(bookVault));
        vm.prank(alice);
        orderEngine.placeOrder(market, BookTestOrders.buy(1, 999, total, 256)); // sweeps all three, rests nothing
        uint256 fee = book.balanceOf(address(bookVault)) - vaultBefore;
        assertEq(fee, _predictFee(numerator), "one ceil over the whole order");
    }
}

contract BookFeeRoundingBook6Bps100Test is BookFeeRoundingBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function feeBps() internal pure override returns (uint16) {
        return 100;
    }

    /// The case the 2026-10-08 audit executed, at the shipped configuration: a taker
    /// buying 0.09 YES at tick 1 used to pay 90 base units of principal and no fee.
    /// It now pays the one base unit the ceiling owes.
    function test_theFillThatUsedToTradeFreeNowPaysOneUnit() public {
        assertEq(_takeAndMeasureFee(1, 9e16), 1, "0.09 shares at tick 1 pays 1 unit");
    }
}

contract BookFeeRoundingBook6Bps1Test is BookFeeRoundingBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 6;
    }

    function feeBps() internal pure override returns (uint16) {
        return 1;
    }
}

contract BookFeeRoundingBook18Bps100Test is BookFeeRoundingBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 18;
    }

    function feeBps() internal pure override returns (uint16) {
        return 100;
    }
}

contract BookFeeRoundingBook2Bps100Test is BookFeeRoundingBase {
    function bookDecimals() internal pure override returns (uint8) {
        return 2;
    }

    function feeBps() internal pure override returns (uint16) {
        return 100;
    }
}

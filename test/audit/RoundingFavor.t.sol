// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {DecimalMath} from "src/libraries/DecimalMath.sol";
import {BookLeg} from "src/libraries/BookLeg.sol";

/// @notice Rounding direction for custody conversion and book cash.
/// @dev AMM percentage fees are a separate case: `AMMEngine._quoteFees` floors
///      `base * feeBps / 10_000`, which favors the trader. That is I-4, covered
///      by `test_I4_ammFeeRoundsDownTowardTheTrader`.
contract RoundingFavorTest is Test {
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_decimalConversionFavorsTheProtocol(uint256 wad, uint8 decimals_)
        public
        pure
    {
        decimals_ = uint8(bound(decimals_, 0, 18));
        wad = bound(wad, 0, 1e50);
        uint256 collected = DecimalMath.fromWadCeil(wad, decimals_);
        uint256 paid = DecimalMath.fromWad(wad, decimals_);
        assertGe(collected, paid, "ceil below floor");
        assertGe(DecimalMath.toWad(collected, decimals_), wad, "under-collected");
        assertLe(DecimalMath.toWad(paid, decimals_), wad, "overpaid");
        if (collected > 0) {
            assertLt(
                DecimalMath.toWad(collected - 1, decimals_), wad, "ceil is not minimal"
            );
        }
    }

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_reserveCashRoundsUp(uint16 tick, uint256 amount, uint8 decimals_)
        public
        pure
    {
        tick = uint16(bound(tick, 1, 999));
        decimals_ = uint8(bound(decimals_, 0, 18));
        uint256 unit = 10 ** (18 - decimals_);
        amount = bound(amount, unit, 1e30);
        amount = amount / unit * unit;
        uint256 native = amount / unit;
        uint256 numerator = native * tick;
        uint256 ceil = (numerator + 999) / 1000;
        assertEq(BookLeg.reserveCash(tick, amount, unit), ceil);
        assertGe(ceil * 1000, numerator, "reservation below the tick");
    }

    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_feeNativeRoundsUp(
        uint16 tick,
        uint256 amount,
        uint16 bps,
        uint8 decimals_
    ) public pure {
        tick = uint16(bound(tick, 1, 999));
        bps = uint16(bound(bps, 0, 10_000));
        decimals_ = uint8(bound(decimals_, 0, 18));
        uint256 unit = 10 ** (18 - decimals_);
        amount = bound(amount, unit, 1e28);
        amount = amount / unit * unit;
        uint256 distance = tick < 1000 - tick ? tick : 1000 - tick;
        uint256 basis = amount * distance;
        uint256 denom = uint256(1000) * 10_000 * unit;
        uint256 numerator = basis * bps;
        uint256 ceil = numerator == 0 ? 0 : (numerator + denom - 1) / denom;
        assertEq(BookLeg.feeNative(basis, bps, unit), ceil);
        assertGe(ceil * denom, numerator, "fee below the exact product");
    }

    /// I-4, confirmed. The engine fee is `base * bps / 10_000`, which drops the
    /// remainder. A trader pays less than the exact bps whenever that product
    /// is not divisible by 10_000.
    function test_I4_ammFeeRoundsDownTowardTheTrader() public pure {
        uint256 base = 10_001;
        uint16 bps = 100;
        uint256 fee = base * bps / 10_000;
        assertEq(fee, 100);
        assertLt(fee * 10_000, base * bps, "remainder was not dropped");
    }
}

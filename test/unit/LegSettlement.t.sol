// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import "forge-std/Test.sol";
import {BookLeg} from "src/libraries/BookLeg.sol";

/// Native cash arithmetic is checked against cumulative rational entitlements.
contract LegSettlementTest is Test {
    function test_allFourIntentsNormalizeToOneYesAxis() public pure {
        (uint8 s, uint16 p) = BookLeg.normalize(0, 1, 600);
        assertEq(s, 0);
        assertEq(p, 600);
        (s, p) = BookLeg.normalize(1, 0, 400);
        assertEq(s, 0);
        assertEq(p, 600);
        (s, p) = BookLeg.normalize(0, 0, 400);
        assertEq(s, 1);
        assertEq(p, 600);
        (s, p) = BookLeg.normalize(1, 1, 600);
        assertEq(s, 1);
        assertEq(p, 600);
    }

    function testFuzz_buyReserveConsumptionTelescopes(
        uint64 raw,
        uint16 tickRaw,
        uint64 splitRaw
    ) public pure {
        uint128 q = uint128(bound(raw, 2, 1e15));
        uint16 tick = uint16(bound(tickRaw, 1, 999));
        uint128 first = uint128(bound(splitRaw, 1, q - 1));
        uint256 reserve = (uint256(q) * tick + 999) / 1000;
        uint256 a = BookLeg.makerCash(0, tick, q, q, first, reserve, 1);
        uint256 b = BookLeg.makerCash(0, tick, q, q - first, q - first, reserve - a, 1);
        assertEq(a + b, reserve);
        assertLe(a, first);
        assertLe(b, q - first);
        assertEq(first - a + (q - first) - b, uint256(q) - reserve);
    }

    function testFuzz_sellerCumulativeProceedsTelescopes(
        uint64 raw,
        uint16 tickRaw,
        uint64 splitRaw
    ) public pure {
        uint128 q = uint128(bound(raw, 2, 1e15));
        uint16 tick = uint16(bound(tickRaw, 1, 999));
        uint128 first = uint128(bound(splitRaw, 1, q - 1));
        uint256 a = BookLeg.makerCash(1, tick, q, q, first, 0, 1);
        uint256 b = BookLeg.makerCash(1, tick, q, q - first, q - first, 0, 1);
        assertEq(a + b, uint256(q) * tick / 1000);
        assertLe(a, first);
        assertLe(b, q - first);
        assertEq(first - a + (q - first) - b, uint256(q) - uint256(q) * tick / 1000);
    }

    function test_makerRoundingCarrySurvivesNativeOneUnitFills() public pure {
        assertEq(BookLeg.makerCash(1, 600, 3, 3, 1, 0, 1), 0);
        assertEq(BookLeg.makerCash(1, 600, 3, 2, 1, 0, 1), 1);
        assertEq(BookLeg.makerCash(1, 600, 3, 1, 1, 0, 1), 0);
        assertEq(BookLeg.reserveCash(600, 3, 1), 2);
    }

    function test_feeRoundedOnceForAggregateComplementaryBasis() public pure {
        assertEq(BookLeg.feeNative(300 * 1e12 + 400 * 1e12, 100, 1e12), 1);
        assertEq(
            BookLeg.feeNative(300 * 1e12, 100, 1e12)
                + BookLeg.feeNative(400 * 1e12, 100, 1e12),
            2
        );
    }

    function testFuzz_reservationRoundsUpWithinOneNative(uint64 raw, uint16 tickRaw)
        public
        pure
    {
        uint256 q = bound(raw, 1, 1e15);
        uint16 tick = uint16(bound(tickRaw, 1, 999));
        uint256 r = BookLeg.reserveCash(tick, q * 1e12, 1e12);
        assertGe(r * 1000, q * tick);
        assertLt(r * 1000 - q * tick, 1000);
    }
}

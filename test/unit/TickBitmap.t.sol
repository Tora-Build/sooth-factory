// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import {TickBitmap} from "src/libraries/TickBitmap.sol";

contract TickBitmapHarness {
    using TickBitmap for TickBitmap.Bitmap;

    TickBitmap.Bitmap internal bitmap;

    function setBit(uint16 tick) external {
        bitmap.setBit(tick);
    }

    function clearBit(uint16 tick) external {
        bitmap.clearBit(tick);
    }

    function findNextDown(uint16 startTick) external view returns (uint16) {
        return bitmap.findNextDown(startTick);
    }

    function findNextUp(uint16 startTick) external view returns (uint16) {
        return bitmap.findNextUp(startTick);
    }

    function msb(uint256 x) external pure returns (uint8) {
        return TickBitmap.mostSignificantBit(x);
    }
}

contract TickBitmapTest is Test {
    TickBitmapHarness internal harness;

    function setUp() public {
        harness = new TickBitmapHarness();
    }

    function _refMsb(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, "x=0");
        while (x > 1) {
            x >>= 1;
            unchecked {
                r++;
            }
        }
    }

    function test_mostSignificantBit_matches_reference_selected_values() public view {
        uint256[12] memory values =
            [uint256(1), 2, 3, 255, 256, 511, 512, 767, 768, 999, 1023, 1024];

        for (uint256 i = 0; i < values.length; i++) {
            uint256 x = values[i];
            assertEq(harness.msb(x), _refMsb(x), "msb mismatch");
        }
    }

    function test_findNextDown_returns_highest_active_tick_from_1000() public {
        uint16[7] memory ticks = [uint16(12), 255, 276, 512, 601, 944, 999];

        for (uint256 i = 0; i < ticks.length; i++) {
            harness.setBit(ticks[i]);
        }

        assertEq(harness.findNextDown(1000), 999, "highest tick from 1000");
        assertEq(harness.findNextDown(999), 944, "next tick below 999");
    }

    function test_findNextUp_roundtrip_consistency() public {
        uint16[4] memory ticks = [uint16(120), 255, 512, 999];

        for (uint256 i = 0; i < ticks.length; i++) {
            harness.setBit(ticks[i]);
        }

        assertEq(harness.findNextUp(0), 120, "first up");
        assertEq(harness.findNextUp(120), 255, "second up");
        assertEq(harness.findNextUp(255), 512, "third up");
        assertEq(harness.findNextUp(512), 999, "fourth up");
    }

    /// Audit F2: `bitIndex + 1` was computed in uint8 inside an unchecked block, so
    /// a start tick of 256/512/768 (bitIndex 255 after the exclusive step) built a
    /// zero mask and skipped the whole word below. Pre-fix down(256) returned 1000.
    function test_findNextDown_wordBoundaries() public {
        harness.setBit(200);
        harness.setBit(256);
        harness.setBit(300);
        harness.setBit(512);
        harness.setBit(600);
        harness.setBit(768);
        assertEq(harness.findNextDown(256), 200, "down from 256 must see word 0");
        assertEq(harness.findNextDown(257), 256, "down from 257");
        assertEq(harness.findNextDown(255), 200, "down from 255");
        assertEq(harness.findNextDown(512), 300, "down from 512 must see word 1");
        assertEq(harness.findNextDown(511), 300, "down from 511");
        assertEq(harness.findNextDown(768), 600, "down from 768 must see word 2");
        assertEq(harness.findNextDown(767), 600, "down from 767");
    }

    function testFuzz_findNextDown_matchesLinearReference(
        uint16 a,
        uint16 b,
        uint16 start
    ) public {
        a = uint16(bound(a, 0, 999));
        b = uint16(bound(b, 0, 999));
        start = uint16(bound(start, 0, 1000));
        harness.setBit(a);
        harness.setBit(b);
        uint16 expected = 1000;
        for (uint16 t = start; t > 0; t--) {
            if (t - 1 == a || t - 1 == b) {
                expected = t - 1;
                break;
            }
        }
        assertEq(harness.findNextDown(start), expected, "linear reference");
    }
}

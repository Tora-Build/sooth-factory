// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {TickBitmap} from "src/libraries/TickBitmap.sol";

/// @dev Storage harness. The reference model is a plain bool array in the test,
///      not a second copy of the word/bit indexing.
contract TickBitmapAuditHarness {
    using TickBitmap for TickBitmap.Bitmap;

    TickBitmap.Bitmap internal bitmap;

    function setBit(uint16 tick) external {
        bitmap.setBit(tick);
    }

    function clearBit(uint16 tick) external {
        bitmap.clearBit(tick);
    }

    function isSet(uint16 tick) external view returns (bool) {
        return bitmap.isSet(tick);
    }

    function findNextDown(uint16 startTick) external view returns (uint16) {
        return bitmap.findNextDown(startTick);
    }

    function findNextUp(uint16 startTick) external view returns (uint16) {
        return bitmap.findNextUp(startTick);
    }

    function leastSignificantBit(uint256 x) external pure returns (uint8) {
        return TickBitmap.leastSignificantBit(x);
    }

    function mostSignificantBit(uint256 x) external pure returns (uint8) {
        return TickBitmap.mostSignificantBit(x);
    }
}

contract TickBitmapReferenceTest is Test {
    TickBitmapAuditHarness internal harness;

    function setUp() public {
        harness = new TickBitmapAuditHarness();
    }

    function _refLsb(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, "zero");
        while (x & 1 == 0) {
            x >>= 1;
            unchecked {
                ++r;
            }
        }
    }

    function _refMsb(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, "zero");
        while (x > 1) {
            x >>= 1;
            unchecked {
                ++r;
            }
        }
    }

    function _down(bool[1000] memory bits, uint16 start) internal pure returns (uint16) {
        if (start == 0) return 1000;
        uint256 cursor = start;
        while (cursor > 0) {
            unchecked {
                --cursor;
            }
            if (bits[cursor]) return uint16(cursor);
        }
        return 1000;
    }

    function _up(bool[1000] memory bits, uint16 start) internal pure returns (uint16) {
        for (uint256 t = uint256(start) + 1; t < 1000; ++t) {
            if (bits[t]) return uint16(t);
        }
        return 1000;
    }

    function _check(bool[1000] memory bits, uint16 start) internal view {
        assertEq(harness.findNextDown(start), _down(bits, start), "down");
        assertEq(harness.findNextUp(start), _up(bits, start), "up");
    }

    /// forge-config: default.fuzz.runs = 4096
    function testFuzz_leastSignificantBitMatchesShift(uint256 x) public view {
        vm.assume(x != 0);
        assertEq(harness.leastSignificantBit(x), _refLsb(x));
    }

    /// forge-config: default.fuzz.runs = 4096
    function testFuzz_mostSignificantBitMatchesShift(uint256 x) public view {
        vm.assume(x != 0);
        assertEq(harness.mostSignificantBit(x), _refMsb(x));
    }

    function test_bitScanExtremes() public view {
        assertEq(harness.leastSignificantBit(1), 0);
        assertEq(harness.mostSignificantBit(1), 0);
        assertEq(harness.leastSignificantBit(1 << 255), 255);
        assertEq(harness.mostSignificantBit(1 << 255), 255);
        assertEq(harness.leastSignificantBit(type(uint256).max), 0);
        assertEq(harness.mostSignificantBit(type(uint256).max), 255);
    }

    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_setAndClearMatchLinearScan(uint256 seed) public {
        bool[1000] memory bits;
        uint256 state = seed;
        for (uint256 step; step < 12; ++step) {
            state = uint256(keccak256(abi.encode(state, step)));
            uint16 tick = uint16(state % 1000);
            if (((state >> 16) & 1) == 1) {
                harness.setBit(tick);
                bits[tick] = true;
            } else {
                harness.clearBit(tick);
                bits[tick] = false;
            }
            assertEq(harness.isSet(tick), bits[tick], "isSet");
            _check(bits, uint16((state >> 32) % 1001));
            // The old uint8 mask bug hid the word below 256, 512 and 768.
            _check(bits, 256);
            _check(bits, 512);
            _check(bits, 768);
            _check(bits, 0);
            _check(bits, 1000);
        }
    }
}

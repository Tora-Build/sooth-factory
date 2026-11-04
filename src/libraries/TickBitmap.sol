// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title TickBitmap
 * @notice Gas-optimized two-level bitmap for tick discovery
 * @dev Architecture: 1,000 ticks in 4 words (256 bits each)
 *      - Level 1: 4 bits (one per word)
 *      - Level 2: 4 words × 256 bits each (only ~250 bits used per word)
 *
 *      Optimizations:
 *      1. Assembly-optimized LSB/MSB (Uniswap V3 pattern)
 *      2. Unchecked arithmetic where overflow is impossible
 *      3. Custom errors instead of require strings
 *      4. 256-bit word size (EVM native)
 */
library TickBitmap {
    // ============================================
    // Structs
    // ============================================

    struct Bitmap {
        uint256 level1; // 4 bits indicating which words have liquidity
        mapping(uint8 => uint256) level2; // 4 words of 256 bits each
    }

    // ============================================
    // Constants
    // ============================================

    uint16 internal constant MAX_TICK = 999;
    uint16 internal constant WORD_SIZE = 256; // bits per word (standard EVM word)
    uint8 internal constant NUM_WORDS = 4; // ceil(1000/256) = 4 words

    // ============================================
    // Errors
    // ============================================

    error TickOutOfRange();
    error ZeroValue();

    // ============================================
    // Core Functions
    // ============================================

    /**
     * @notice Set bit for tick (mark as having liquidity)
     * @dev Uses unchecked arithmetic - tick bounds verified at entry
     */
    function setBit(Bitmap storage bitmap, uint16 tick) internal {
        require(tick <= MAX_TICK, TickOutOfRange());

        unchecked {
            uint8 wordIndex = uint8(tick >> 8); // tick / 256
            uint8 bitIndex = uint8(tick & 0xFF); // tick % 256

            // Set level 2 bit
            bitmap.level2[wordIndex] |= (1 << bitIndex);

            // Set level 1 bit
            bitmap.level1 |= (1 << wordIndex);
        }
    }

    /**
     * @notice Clear bit for tick (mark as no liquidity)
     */
    function clearBit(Bitmap storage bitmap, uint16 tick) internal {
        require(tick <= MAX_TICK, TickOutOfRange());

        unchecked {
            uint8 wordIndex = uint8(tick >> 8);
            uint8 bitIndex = uint8(tick & 0xFF);

            // Clear level 2 bit
            bitmap.level2[wordIndex] &= ~(1 << bitIndex);

            // If word is now empty, clear level 1 bit
            if (bitmap.level2[wordIndex] == 0) {
                bitmap.level1 &= ~(1 << wordIndex);
            }
        }
    }

    /**
     * @notice Set multiple bits at once
     * @dev Useful when placing wide range orders
     */
    /**
     * @notice Check if tick has liquidity
     */
    function isSet(Bitmap storage bitmap, uint16 tick) internal view returns (bool) {
        require(tick <= MAX_TICK, TickOutOfRange());

        unchecked {
            uint8 wordIndex = uint8(tick >> 8);
            uint8 bitIndex = uint8(tick & 0xFF);
            return (bitmap.level2[wordIndex] & (1 << bitIndex)) != 0;
        }
    }

    /**
     * @notice Find next tick with liquidity (upward search)
     * @param bitmap Bitmap storage reference
     * @param startTick Starting tick (exclusive)
     * @return nextTick Next tick with liquidity (returns MAX_TICK+1 if none)
     */
    function findNextUp(Bitmap storage bitmap, uint16 startTick)
        internal
        view
        returns (uint16 nextTick)
    {
        if (startTick >= MAX_TICK) return MAX_TICK + 1;

        unchecked {
            uint16 searchTick = startTick + 1;
            uint8 wordIndex = uint8(searchTick >> 8);
            uint8 bitIndex = uint8(searchTick & 0xFF);

            // Search within current word first
            uint256 word = bitmap.level2[wordIndex];
            uint256 mask = ~((1 << bitIndex) - 1); // Mask bits >= bitIndex
            uint256 masked = word & mask;

            if (masked != 0) {
                uint8 bit = leastSignificantBit(masked);
                nextTick = uint16(wordIndex) * WORD_SIZE + bit;
                return nextTick > MAX_TICK ? MAX_TICK + 1 : nextTick;
            }

            // Search level 1 for next non-empty word
            uint256 level1Mask = ~((1 << (wordIndex + 1)) - 1);
            uint256 level1Masked = bitmap.level1 & level1Mask;

            if (level1Masked == 0) {
                return MAX_TICK + 1;
            }

            // Find next non-empty word
            uint8 nextWordIndex = leastSignificantBit(level1Masked);

            // Find first bit in that word
            uint256 nextWord = bitmap.level2[nextWordIndex];
            uint8 nextBit = leastSignificantBit(nextWord);

            nextTick = uint16(nextWordIndex) * WORD_SIZE + nextBit;
            return nextTick > MAX_TICK ? MAX_TICK + 1 : nextTick;
        }
    }

    /**
     * @notice Find next tick with liquidity (downward search)
     * @param bitmap Bitmap storage reference
     * @param startTick Starting tick (exclusive)
     * @return nextTick Next tick with liquidity (returns MAX_TICK+1 if none found)
     */
    function findNextDown(Bitmap storage bitmap, uint16 startTick)
        internal
        view
        returns (uint16 nextTick)
    {
        if (startTick == 0) return MAX_TICK + 1;

        unchecked {
            uint16 searchTick = startTick - 1;
            uint8 wordIndex = uint8(searchTick >> 8);
            uint8 bitIndex = uint8(searchTick & 0xFF);

            // Search within current word first
            uint256 word = bitmap.level2[wordIndex];
            // Widen before adding: `bitIndex + 1` in uint8 wraps to 0 at 255
            // inside this unchecked block, which zeroed the mask and skipped
            // the whole word for start ticks 256/512/768.
            uint256 mask = (uint256(1) << (uint256(bitIndex) + 1)) - 1; // bits <= bitIndex
            uint256 masked = word & mask;

            if (masked != 0) {
                uint8 bit = mostSignificantBit(masked);
                return uint16(wordIndex) * WORD_SIZE + bit;
            }

            // Search level 1 for previous non-empty word
            if (wordIndex == 0) {
                return MAX_TICK + 1;
            }

            uint256 level1Mask = (1 << wordIndex) - 1;
            uint256 level1Masked = bitmap.level1 & level1Mask;

            if (level1Masked == 0) {
                return MAX_TICK + 1;
            }

            // Find previous non-empty word
            uint8 prevWordIndex = mostSignificantBit(level1Masked);

            // Find last bit in that word
            uint256 prevWord = bitmap.level2[prevWordIndex];
            uint8 prevBit = mostSignificantBit(prevWord);

            return uint16(prevWordIndex) * WORD_SIZE + prevBit;
        }
    }

    // ============================================
    // Assembly-Optimized Bit Math (Uniswap V3/V4 Pattern)
    // ============================================

    /**
     * @notice Find least significant bit using binary search
     * @dev Matches Uniswap V3 BitMath.leastSignificantBit pattern
     */
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, ZeroValue());

        assembly {
            // Binary search for LSB position
            // x & -x isolates the LSB
            let lsb := and(x, sub(0, x))

            // Check each power of 2 range
            r := 0

            // If no bits in lower 128, LSB is in upper 128
            if iszero(and(lsb, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)) {
                r := 128
                lsb := shr(128, lsb)
            }

            if iszero(and(lsb, 0xFFFFFFFFFFFFFFFF)) {
                r := add(r, 64)
                lsb := shr(64, lsb)
            }

            if iszero(and(lsb, 0xFFFFFFFF)) {
                r := add(r, 32)
                lsb := shr(32, lsb)
            }

            if iszero(and(lsb, 0xFFFF)) {
                r := add(r, 16)
                lsb := shr(16, lsb)
            }

            if iszero(and(lsb, 0xFF)) {
                r := add(r, 8)
                lsb := shr(8, lsb)
            }

            if iszero(and(lsb, 0xF)) {
                r := add(r, 4)
                lsb := shr(4, lsb)
            }

            if iszero(and(lsb, 0x3)) {
                r := add(r, 2)
                lsb := shr(2, lsb)
            }

            if iszero(and(lsb, 0x1)) { r := add(r, 1) }
        }
    }

    /**
     * @notice Find most significant bit using binary search
     * @dev Matches Uniswap V3 BitMath.mostSignificantBit
     */
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x != 0, ZeroValue());

        assembly {
            // Binary search for MSB position
            let f := shl(7, gt(x, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            r := f
            x := shr(f, x)

            f := shl(6, gt(x, 0xFFFFFFFFFFFFFFFF))
            r := or(r, f)
            x := shr(f, x)

            f := shl(5, gt(x, 0xFFFFFFFF))
            r := or(r, f)
            x := shr(f, x)

            f := shl(4, gt(x, 0xFFFF))
            r := or(r, f)
            x := shr(f, x)

            f := shl(3, gt(x, 0xFF))
            r := or(r, f)
            x := shr(f, x)

            f := shl(2, gt(x, 0xF))
            r := or(r, f)
            x := shr(f, x)

            f := shl(1, gt(x, 0x3))
            r := or(r, f)
            x := shr(f, x)

            f := gt(x, 0x1)
            r := or(r, f)
        }
    }

    // ============================================
    // Batch Operations (Gas Optimization)
    // ============================================

    /**
     * @notice Get population count (number of set bits) in a word
     * @dev Useful for analytics
     */
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {PositionPricing as Pricing} from "../../src/libraries/PositionPricing.sol";
import {PositionLedgerHarness as Ledger} from "./PositionLedgerHarness.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Composes bounded pricing with the test ledger; no ERC-20 custody claim.
contract PricedPositionTest is Test {
    address internal constant CREATOR = address(0xC0FFEE);

    struct Amounts {
        uint256 initialDeposit;
        uint256 deposit;
        uint256 buyCost;
        uint256 buyFee;
        uint256 sellCost;
        uint256 sellFee;
    }

    function replay(uint8 outcome, uint8 decimals) internal returns (int256 net) {
        Ledger h = new Ledger();
        Amounts memory a;
        uint256 b = 100e18;
        (, a.initialDeposit) = Pricing.costBounds(b, 0, 0);
        h.add(a.initialDeposit, b, CREATOR);
        (uint256 beforeLow,) = Pricing.costBounds(b, 0, 0);
        (, uint256 afterHigh) = Pricing.costBounds(b, 100e18, 0);
        a.buyCost = afterHigh - beforeLow;
        a.buyFee = a.buyCost / 100;
        h.trade(0, 100e18, int256(a.buyCost), a.buyFee / 2, a.buyFee * 3 / 10);
        b += a.buyFee / 2;
        a.deposit = Pricing.funding(b, 100e18, 0, 100e18);
        h.add(a.deposit, 100e18, address(this));
        uint256 q = Math.mulDiv(100e18, b + 100e18, b);
        b += 100e18;
        (beforeLow,) = Pricing.costBounds(b, q, 0);
        (, afterHigh) = Pricing.costBounds(b, q - 100e18, 0);
        a.sellCost = beforeLow - afterHigh;
        a.sellFee = a.sellCost / 100;
        h.trade(0, -100e18, -int256(a.sellCost), a.sellFee / 2, a.sellFee * 3 / 10);
        h.checkpoint(0);
        h.checkpoint(1);
        h.finalize(outcome);
        uint256 paid = h.claim(1, a.deposit, decimals) * 10 ** (18 - decimals);
        uint256 fees = h.claimFees();
        vm.prank(CREATOR);
        h.claim(0, a.initialDeposit, decimals);
        assertLe(h.residualBacking(), 2 * 10 ** (18 - decimals) + 100);
        net = int256(paid + fees + a.sellCost - a.sellFee)
            - int256(a.deposit + a.buyCost + a.buyFee);
    }

    function test_pricedBuyAddSellBothPrecisions() public {
        for (uint8 d; d < 2; d++) {
            uint8 decimals = d == 0 ? 6 : 18;
            int256 yes = replay(0, decimals);
            int256 no = replay(1, decimals);
            int256 invalid = replay(2, decimals);
            assertTrue(yes <= 0 || no <= 0);
            assertLe(yes + no, 0);
            assertLe(invalid, 0);
        }
    }
}

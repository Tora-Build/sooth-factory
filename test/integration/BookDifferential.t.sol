// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;
import {DualTokenBase} from "../base/DualTokenBase.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {BookTestOrders} from "../reference/BookTestOrders.sol";
import {IOrderEngine} from "src/interfaces/IOrderEngine.sol";

contract DifferentialToken18 is MockUSDC {
    constructor() MockUSDC("Differential", "DIFF") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/// Independent rational cash/inventory oracle replaces comparison with the
/// obsolete automatic-net engine. Expected values never call BookLeg.
abstract contract GrossDifferentialCampaign is DualTokenBase {
    function decimalsUnderTest() internal pure virtual returns (uint8);

    function setUp() public override {
        super.setUp();
        if (decimalsUnderTest() == 18) {
            usdc = new DifferentialToken18();
            _deployStack(address(usdc));
            vm.prank(creator);
            east.approve(address(marketFactory), type(uint256).max);
        }
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? alice : bob;
            usdc.mint(who, 1e27);
            vm.prank(who);
            usdc.approve(address(orderEngine), type(uint256).max);
        }
        _createMarket();
    }

    struct Oracle {
        uint256 q;
        uint256 u;
        uint256 makerCash;
        uint256 takerCash;
        uint256 fee;
        uint256 makerBefore;
        uint256 takerBefore;
        uint256 initialSets;
        uint8 takerOutcome;
    }

    function testFuzz_fourFillCashAndInventoryMatrix(
        uint64 size,
        uint16 price,
        bool makerSell,
        bool takerSell,
        bool makerYes
    ) public {
        Oracle memory x;
        x.u = 10 ** (18 - decimalsUnderTest());
        x.q = bound(size, 1000, 1e12);
        uint128 amount = uint128(x.q * x.u);
        uint16 p = uint16(bound(price, 1, 999));
        uint8 outcome = makerYes ? 1 : 0;
        x.takerOutcome = makerSell == takerSell ? 1 - outcome : outcome;
        if (makerSell) {
            vm.prank(alice);
            orderEngine.split(market, amount, x.q, uint64(block.timestamp + 1));
            x.initialSets += x.q;
        }
        if (takerSell) {
            vm.prank(bob);
            orderEngine.split(market, amount, x.q, uint64(block.timestamp + 1));
            x.initialSets += x.q;
        }
        x.makerBefore = usdc.balanceOf(alice);
        x.takerBefore = usdc.balanceOf(bob);
        x.makerCash = makerSell ? x.q * p / 1000 : (x.q * p + 999) / 1000;
        x.takerCash = makerSell == takerSell ? x.q - x.makerCash : x.makerCash;
        x.fee = (x.q * (p < 500 ? p : 1000 - p) * 100 + 9_999_999) / 10_000_000;
        vm.prank(alice);
        orderEngine.placeOrder(
            market,
            makerSell
                ? BookTestOrders.sell(outcome, p, amount, 64)
                : BookTestOrders.buy(outcome, p, amount, 64)
        );
        IOrderEngine.OrderParams memory t = takerSell
            ? BookTestOrders.sell(
                x.takerOutcome, makerSell == takerSell ? 1000 - p : p, amount, 64
            )
            : BookTestOrders.buy(
                x.takerOutcome, makerSell == takerSell ? 1000 - p : p, amount, 64
            );
        t.maxTokenIn = x.q + x.fee;
        vm.prank(bob);
        IOrderEngine.OrderResult memory r = orderEngine.placeOrder(market, t);
        assertEq(r.filled, amount);
        assertEq(r.fee, x.fee);
        assertEq(
            usdc.balanceOf(alice),
            makerSell ? x.makerBefore + x.makerCash : x.makerBefore - x.makerCash
        );
        assertEq(
            usdc.balanceOf(bob),
            takerSell
                ? x.takerBefore + x.takerCash - x.fee
                : x.takerBefore - x.takerCash - x.fee
        );
        (uint256 my, uint256 mn) = orderEngine.getPosition(market, alice);
        (uint256 ty, uint256 tn) = orderEngine.getPosition(market, bob);
        assertEq(outcome == 1 ? my : mn, makerSell ? 0 : amount);
        assertEq(outcome == 1 ? mn : my, makerSell ? amount : 0);
        assertEq(x.takerOutcome == 1 ? ty : tn, takerSell ? 0 : amount);
        assertEq(x.takerOutcome == 1 ? tn : ty, takerSell ? amount : 0);
        uint256 sets = x.initialSets + (makerSell || takerSell ? 0 : x.q)
            - (makerSell && takerSell ? x.q : 0);
        (uint256 sy, uint256 sn) = orderEngine.getSupplies(market);
        assertEq(sy, sets * x.u);
        assertEq(sn, sy);
        assertEq(orderEngine.getCollateralBacking(market), sets);
        assertEq(usdc.balanceOf(address(orderEngine)), sets);
        assertEq(orderEngine.getOrderCash(market), 0);
    }
}

contract BookDifferential6Test is GrossDifferentialCampaign {
    function decimalsUnderTest() internal pure override returns (uint8) {
        return 6;
    }
}

contract BookDifferential18Test is GrossDifferentialCampaign {
    function decimalsUnderTest() internal pure override returns (uint8) {
        return 18;
    }
}

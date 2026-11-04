// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BookTestOrders} from "../reference/BookTestOrders.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OrderEngine} from "src/OrderEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract MarketStub {
    bool public isTradingOpen = true;
    bool public isSettled;
    uint8 public winningOutcome;
    uint64 public deadline = type(uint64).max;
    address public immutable marketFactory;

    constructor(address marketFactory_) {
        marketFactory = marketFactory_;
    }
}

/// @dev Records the source-funded pull, including the original fee payer.
contract RecordingVault {
    IERC20 public immutable token;
    uint16 public immutable bps;
    address public lastMarket;
    address public lastPayer;
    uint256 public lastExpected;
    uint256 public preBalance;
    uint256 public sourceAtCall;
    uint256 public allowanceAtCall;
    uint256 public calls;
    uint256 public creditShortfall;

    constructor(IERC20 token_, uint16 bps_) {
        token = token_;
        bps = bps_;
    }

    function setCreditShortfall(uint256 value) external {
        creditShortfall = value;
    }

    function feeBpsOf(address) external view returns (uint16) {
        return bps;
    }

    function depositRevenue(address market, uint256 expected, address payer)
        external
        returns (uint256)
    {
        lastMarket = market;
        lastPayer = payer;
        lastExpected = expected;
        preBalance = token.balanceOf(address(this));
        sourceAtCall = token.balanceOf(msg.sender);
        allowanceAtCall = token.allowance(msg.sender, address(this));
        ++calls;
        require(token.transferFrom(msg.sender, address(this), expected));
        return expected - creditShortfall;
    }
}

contract SilentVault {
    function feeBpsOf(address) external pure returns (uint16) {
        return 100;
    }
    function depositRevenue(address, uint256, address) external {}
}

contract VaultHandoffTest is Test {
    MockUSDC internal token;
    OrderEngine internal engine;
    RecordingVault internal vaultStub;
    MarketStub internal marketStub;
    address internal maker = address(0x3A4E);
    address internal taker = address(0x7A4E);

    function _deploy(uint16 bps) internal {
        token = new MockUSDC("MockUSDC", "MUSDC");
        vaultStub = new RecordingVault(token, bps);
        _engine(address(vaultStub));
    }

    function _engine(address vault) internal {
        marketStub = new MarketStub(address(this));
        engine = new OrderEngine(address(token), address(this), vault);
        engine.registerMarket(address(marketStub), address(token), 0.5e18);
        address[2] memory who = [maker, taker];
        for (uint256 i; i < who.length; ++i) {
            token.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            token.approve(address(engine), type(uint256).max);
        }
    }

    function _fill() internal {
        vm.prank(maker);
        engine.placeOrder(address(marketStub), BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(taker);
        engine.placeOrder(address(marketStub), BookTestOrders.buy(1, 600, 100e18, 256));
    }

    function test_handoffPullsExactFeeAndBindsOriginalPayer() public {
        _deploy(100);
        _fill();
        assertEq(vaultStub.calls(), 1);
        assertEq(vaultStub.lastMarket(), address(marketStub));
        assertEq(vaultStub.lastPayer(), taker);
        assertEq(vaultStub.lastExpected(), 0.4e6);
        assertEq(vaultStub.preBalance(), 0);
        assertEq(vaultStub.sourceAtCall(), 100.4e6);
        assertEq(vaultStub.allowanceAtCall(), 0.4e6);
        assertEq(token.allowance(address(engine), address(vaultStub)), 0);
        assertEq(token.balanceOf(address(vaultStub)), 0.4e6);
        assertEq(engine.getCollateralBacking(address(marketStub)), 100e6);
    }

    function test_receiptsAccumulateWithoutHistoricalBalanceCredit() public {
        _deploy(100);
        _fill();
        _fill();
        assertEq(vaultStub.calls(), 2);
        assertEq(vaultStub.preBalance(), 0.4e6);
        assertEq(token.balanceOf(address(vaultStub)), 0.8e6);
        assertEq(engine.getCollateralBacking(address(marketStub)), 200e6);
    }

    function test_wrongCreditReturnRollsBackWholeFill() public {
        _deploy(100);
        vaultStub.setCreditShortfall(1);
        vm.prank(maker);
        engine.placeOrder(address(marketStub), BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(taker);
        vm.expectRevert();
        engine.placeOrder(address(marketStub), BookTestOrders.buy(1, 600, 100e18, 256));
        assertEq(token.balanceOf(taker), 1_000_000e6);
        assertEq(token.balanceOf(address(vaultStub)), 0);
        assertEq(vaultStub.calls(), 0);
        assertEq(engine.getCollateralBacking(address(marketStub)), 40e6);
    }

    function test_noFeeMeansNoHandoff() public {
        _deploy(0);
        _fill();
        assertEq(vaultStub.calls(), 0);
        assertEq(engine.getCollateralBacking(address(marketStub)), 100e6);
    }

    function test_closingProceedsPayFeeAttributedToClosingTaker() public {
        _deploy(100);
        _fill();
        vm.prank(taker);
        engine.placeOrder(address(marketStub), BookTestOrders.sell(1, 600, 100e18, 256));
        vm.prank(maker);
        engine.placeOrder(address(marketStub), BookTestOrders.sell(0, 400, 100e18, 256));
        assertEq(vaultStub.calls(), 2);
        assertEq(vaultStub.lastPayer(), maker);
        assertEq(vaultStub.lastExpected(), 0.4e6);
        assertEq(token.balanceOf(address(vaultStub)), 0.8e6);
        assertEq(engine.getNet(address(marketStub), maker), 0);
        assertEq(engine.getNet(address(marketStub), taker), 0);
        assertEq(engine.getCollateralBacking(address(marketStub)), 0);
        assertEq(token.allowance(address(engine), address(vaultStub)), 0);
    }

    function test_missingReturnRevertsWholeFill() public {
        token = new MockUSDC("MockUSDC", "MUSDC");
        SilentVault silent = new SilentVault();
        _engine(address(silent));
        vm.prank(maker);
        engine.placeOrder(address(marketStub), BookTestOrders.buy(0, 400, 100e18, 256));
        vm.prank(taker);
        vm.expectRevert();
        engine.placeOrder(address(marketStub), BookTestOrders.buy(1, 600, 100e18, 256));
        assertEq(token.balanceOf(taker), 1_000_000e6);
        assertEq(token.balanceOf(address(silent)), 0);
        assertEq(engine.getCollateralBacking(address(marketStub)), 40e6);
    }
}

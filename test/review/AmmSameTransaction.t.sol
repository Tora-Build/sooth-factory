// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {DualTokenBase} from "../base/DualTokenBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AMMEngine} from "src/AMMEngine.sol";
import {IAMMEngine} from "src/interfaces/IAMMEngine.sol";
import {IAmmFeeVault} from "src/interfaces/IAmmFeeVault.sol";
import {IMarketFactory} from "src/interfaces/IMarketFactory.sol";
import {LPPositionManager} from "src/LPPositionManager.sol";

interface IRoundTripAccounting {
    function assertRoundTripAccounting() external view;
}

/// @dev Real contract caller: both legs execute inside one external call, without
/// a prank, time change, balance mutation, or claim between the two trades.
contract AmmRoundTripTrader {
    AMMEngine private immutable engine;
    IRoundTripAccounting private immutable auditor;

    constructor(AMMEngine engine_, IRoundTripAccounting auditor_) {
        engine = engine_;
        auditor = auditor_;
    }

    function approve(IERC20 token) external {
        token.approve(address(engine), type(uint256).max);
    }

    function trade(address market, uint8 side, int256 shares)
        public
        returns (uint256 amount)
    {
        amount = engine.tradePositions(
            market, side, shares, shares > 0 ? type(uint256).max : 0
        );
        auditor.assertRoundTripAccounting();
    }

    function roundTrip(address market, uint8 side, uint256 shares, bool sellFirst)
        external
        returns (uint256 cashBefore, uint256 cashAfter)
    {
        IERC20 token = IERC20(engine.tokenAOf(market));
        cashBefore = token.balanceOf(address(this));
        (uint256 yesBefore, uint256 noBefore) = engine.getPosition(market, address(this));
        int256 first = sellFirst ? -int256(shares) : int256(shares);
        trade(market, side, first);
        trade(market, side, -first);
        cashAfter = token.balanceOf(address(this));
        require(cashAfter <= cashBefore, "isolated round trip made a token profit");
        (uint256 yesAfter, uint256 noAfter) = engine.getPosition(market, address(this));
        require(
            yesAfter == yesBefore && noAfter == noBefore, "round trip changed inventory"
        );
    }

    function interleaved(
        address market,
        uint8 side,
        uint256 shares,
        AmmRoundTripTrader other,
        uint8 otherSide,
        uint256 otherShares
    ) external {
        trade(market, side, int256(shares));
        other.trade(market, otherSide, int256(otherShares));
        trade(market, side, -int256(shares));
    }

    function sequence(
        address market,
        AmmRoundTripTrader[3] memory actors,
        uint256 seed,
        uint256 maxShares
    ) external returns (uint256 buys, uint256 sells) {
        for (uint256 step; step < 12; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            // Ensure all three actors participate, then fuzz the caller order.
            AmmRoundTripTrader actor = actors[step < 3 ? step : seed % 3];
            uint8 side = uint8((seed >> 8) % 2);
            bool sell = step >= 3 && ((seed >> 16) % 2 == 1);
            uint256 limit = maxShares;
            if (sell) {
                (uint256 yes, uint256 no) = engine.getPosition(market, address(actor));
                uint256 owned = side == 1 ? yes : no;
                if (owned == 0) {
                    side = 1 - side;
                    owned = side == 1 ? yes : no;
                }
                if (owned == 0) sell = false;
                else if (owned < limit) limit = owned;
            }
            uint256 shares = 1 + (seed >> 24) % limit;
            actor.trade(market, side, sell ? -int256(shares) : int256(shares));
            if (sell) ++sells;
            else ++buys;
        }
    }
}

/// @notice Isolated round trips cannot manufacture tokens. With intervening flow,
/// individual profit is allowed and is attributed to the other trader and LP
/// custody instead. All trades execute the real engine, vault and LP accounting.
contract AmmSameTransactionTest is DualTokenBase, IRoundTripAccounting {
    struct Scenario {
        uint8 decimals;
        uint16 rate;
        uint16 capital;
        uint256 depth;
        uint256 odds;
        uint256 shares;
        uint8 side;
        bool sellFirst;
    }

    IERC20 private token;
    LPPositionManager private manager;
    AmmRoundTripTrader private first;
    AmmRoundTripTrader private second;
    AmmRoundTripTrader private third;
    uint256 private unit;
    uint256 private position;
    uint256 private initialCash;
    uint256 private initialCreatorCash;
    uint256 private initialFirstCash;
    uint256 private initialSecondCash;
    uint256 private initialThirdCash;
    uint256 private initialEngineCash;
    uint256 private initialVaultCash;
    uint256[3] private initialLpResidual;

    function setUp() public override {
        super.setUp();
        manager = LPPositionManager(amm.positionManager());
        first = new AmmRoundTripTrader(amm, this);
        second = new AmmRoundTripTrader(amm, this);
        third = new AmmRoundTripTrader(amm, this);
        address[4] memory actors =
            [creator, address(first), address(second), address(third)];
        for (uint256 i; i < actors.length; ++i) {
            east.mint(actors[i], 1e32);
            usdc.mint(actors[i], 1e32);
        }
        first.approve(IERC20(address(east)));
        first.approve(IERC20(address(usdc)));
        second.approve(IERC20(address(east)));
        second.approve(IERC20(address(usdc)));
        third.approve(IERC20(address(east)));
        third.approve(IERC20(address(usdc)));
        vm.prank(creator);
        usdc.approve(address(marketFactory), type(uint256).max);
    }

    function _prepare(
        uint8 decimals,
        uint16 rate,
        uint16 capital,
        uint256 depth,
        uint256 odds
    ) private {
        token = IERC20(decimals == 6 ? address(usdc) : address(east));
        unit = 10 ** (18 - decimals);
        uint16 remaining = 10_000 - capital;
        uint16 lpBps = remaining / 2;
        uint16 resolutionBps = remaining / 4;
        vault.publishAmmConfig(
            IAmmFeeVault.AmmConfig(
                rate,
                capital,
                lpBps,
                resolutionBps,
                remaining - lpBps - resolutionBps,
                treasury
            )
        );
        initialCash = token.balanceOf(creator) + token.balanceOf(address(first))
            + token.balanceOf(address(second)) + token.balanceOf(address(third));
        IMarketFactory.MarketParams memory params = _marketParams(
            "Same transaction AMM cash-flow evidence",
            0,
            uint64(block.timestamp + 20 days),
            address(token),
            depth,
            odds
        );
        vm.prank(creator);
        (market, position) = marketFactory.createMarket(params);
        initialCreatorCash = token.balanceOf(creator);
        initialFirstCash = token.balanceOf(address(first));
        initialSecondCash = token.balanceOf(address(second));
        initialThirdCash = token.balanceOf(address(third));
        initialEngineCash = token.balanceOf(address(amm));
        initialVaultCash = token.balanceOf(address(vault));
        for (uint8 outcome; outcome < 3; ++outcome) {
            initialLpResidual[outcome] = manager.residual(position, outcome);
        }
        assertRoundTripAccounting();
    }

    /// @dev Invoked from the real trader contract after every completed trade,
    /// including the middle leg of an atomic round trip or interleaved sequence.
    function assertRoundTripAccounting() public view {
        uint256 collateral = amm.getMarketCollateral(market);
        uint256 floor = amm.claimableFloorLiability(market);
        assertEq(amm.totalLiabilitiesOf(address(token)), collateral + floor);
        assertEq(token.balanceOf(address(amm)) * unit, collateral + floor);
        assertEq(
            token.balanceOf(address(vault)), vault.totalLiabilitiesOf(address(token))
        );
        assertEq(
            vault.totalLiabilitiesOf(address(token)),
            vault.marketLiabilitiesOf(market, address(token))
        );
        assertEq(
            token.balanceOf(creator) + token.balanceOf(address(first))
                + token.balanceOf(address(second)) + token.balanceOf(address(third))
                + token.balanceOf(address(amm)) + token.balanceOf(address(vault)),
            initialCash,
            "native cash conservation at each trade boundary"
        );
        assertEq(token.balanceOf(address(orderEngine)), 0, "no book collateral access");
        assertEq(token.balanceOf(address(bookVault)), 0, "no book revenue access");
        (uint256 y1, uint256 n1) = amm.getPosition(market, address(first));
        (uint256 y2, uint256 n2) = amm.getPosition(market, address(second));
        (uint256 y3, uint256 n3) = amm.getPosition(market, address(third));
        for (uint8 outcome; outcome < 3; ++outcome) {
            uint256 traderClaims = outcome == 1
                ? y1 + y2 + y3
                : outcome == 0
                    ? n1 + n2 + n3
                    : (y1 + n1) / 2 + (y2 + n2) / 2 + (y3 + n3) / 2;
            assertLe(
                manager.residual(position, outcome) + traderClaims,
                collateral,
                "LP residual plus trader outcome obligations stay backed"
            );
        }
    }

    function _isolated(Scenario memory scenario) private {
        _prepare(
            scenario.decimals,
            scenario.rate,
            scenario.capital,
            scenario.depth,
            scenario.odds
        );
        if (scenario.sellFirst) {
            first.trade(market, scenario.side, int256(scenario.shares));
        }
        uint256 number = block.number;
        uint256 timestamp = block.timestamp;
        (uint256 beforeCash, uint256 afterCash) =
            first.roundTrip(market, scenario.side, scenario.shares, scenario.sellFirst);
        assertLe(afterCash, beforeCash, "no isolated atomic token profit");
        assertEq(block.number, number);
        assertEq(block.timestamp, timestamp);
        assertRoundTripAccounting();
    }

    function test_SameTransactionRoundTripsAllRatesCapitalAndDecimals() public {
        uint16[4] memory rates = [uint16(0), 1, 100, 10_000];
        uint16[3] memory capitals = [uint16(0), 5000, 10_000];
        uint256 snapshot = vm.snapshotState();
        for (uint256 d; d < 2; ++d) {
            for (uint256 r; r < rates.length; ++r) {
                for (uint256 c; c < capitals.length; ++c) {
                    for (uint256 reverse; reverse < 2; ++reverse) {
                        _isolated(
                            Scenario(
                                d == 0 ? 6 : 18,
                                rates[r],
                                capitals[c],
                                100e18,
                                reverse == 0 ? 0.2e18 : 0.8e18,
                                75e18,
                                uint8(reverse),
                                reverse == 1
                            )
                        );
                        assertTrue(vm.revertToState(snapshot));
                    }
                }
            }
        }
    }

    function _fuzzIsolated(
        uint8 decimals,
        bool reverse,
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint8 side,
        uint8 rateIndex,
        uint8 capitalIndex
    ) private {
        Scenario memory scenario;
        scenario.decimals = decimals;
        // Fuzz 0.1 through one million depth units, every interior WAD odds
        // value, either outcome, and sizes from one WAD quantum through 8b.
        // Deterministic cases separately exercise the complete fee/allocation
        // matrix and the exact extreme-odds/sub-native boundaries.
        scenario.depth = bound(depth, 1e17, 1e24);
        scenario.odds = bound(odds, 1, 1e18 - 1);
        scenario.shares = bound(shares, 1, 8 * scenario.depth);
        scenario.side = side % 2;
        scenario.sellFirst = reverse;
        uint16[4] memory rates = [uint16(0), 1, 100, 10_000];
        uint16[3] memory capitals = [uint16(0), 5000, 10_000];
        scenario.rate = rates[rateIndex % 4];
        scenario.capital = capitals[capitalIndex % 3];
        _isolated(scenario);
    }

    function testFuzz_SameTransactionBuySellSixDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint8 side,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzIsolated(6, false, depth, odds, shares, side, rate, capital);
    }

    function testFuzz_SameTransactionBuySellEighteenDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint8 side,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzIsolated(18, false, depth, odds, shares, side, rate, capital);
    }

    function testFuzz_SameTransactionSellBuySixDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint8 side,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzIsolated(6, true, depth, odds, shares, side, rate, capital);
    }

    function testFuzz_SameTransactionSellBuyEighteenDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint8 side,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzIsolated(18, true, depth, odds, shares, side, rate, capital);
    }

    function test_SameTransactionExtremeOddsAndSubNativeTrades() public {
        uint256[3] memory odds = [uint256(1), 0.5e18, 1e18 - 1];
        uint256[3] memory sizes = [uint256(1), 1e12 - 1, 200e18];
        uint256 snapshot = vm.snapshotState();
        for (uint256 d; d < 2; ++d) {
            for (uint256 o; o < odds.length; ++o) {
                for (uint256 s; s < sizes.length; ++s) {
                    for (uint8 side; side < 2; ++side) {
                        _isolated(
                            Scenario(
                                d == 0 ? 6 : 18,
                                1,
                                10_000,
                                100e18,
                                odds[o],
                                sizes[s],
                                side,
                                false
                            )
                        );
                        assertTrue(vm.revertToState(snapshot));
                    }
                }
            }
        }
    }

    function _assertAndReportPnl(bool report, bool firstMustBeFlat) private {
        int256 a = int256(token.balanceOf(address(first))) - int256(initialFirstCash);
        int256 b = int256(token.balanceOf(address(second))) - int256(initialSecondCash);
        int256 c = int256(token.balanceOf(address(third))) - int256(initialThirdCash);
        int256 sponsor = int256(token.balanceOf(creator)) - int256(initialCreatorCash);
        int256 engine = int256(token.balanceOf(address(amm))) - int256(initialEngineCash);
        int256 fees = int256(token.balanceOf(address(vault))) - int256(initialVaultCash);
        assertEq(a + b + c + sponsor + engine + fees, 0, "all native cash P&L attributed");
        if (firstMustBeFlat) {
            (uint256 yes, uint256 no) = amm.getPosition(market, address(first));
            assertEq(yes + no, 0, "round-trip trader ends flat");
        }
        if (report) {
            emit log_named_int("A native token P&L", a);
            emit log_named_int("B native token P&L (retains outcome shares)", b);
            emit log_named_int("C native token P&L", c);
            emit log_named_int("sponsor native wallet P&L", sponsor);
            emit log_named_int("engine native custody change", engine);
            emit log_named_int("vault native fee custody change", fees);
            for (uint8 outcome; outcome < 3; ++outcome) {
                emit log_named_uint("LP residual outcome (NO, YES, INVALID)", outcome);
                emit log_named_int(
                    "LP outcome residual WAD change",
                    int256(manager.residual(position, outcome))
                        - int256(initialLpResidual[outcome])
                );
            }
        }
        assertRoundTripAccounting();
    }

    function _zeroFeeInterleaved(uint8 decimals) private {
        _prepare(decimals, 0, 0, 100e18, 0.5e18);
        first.interleaved(market, 1, 100e18, second, 1, 100e18);
        assertGt(
            token.balanceOf(address(first)),
            initialFirstCash,
            "intervening buy raises sell proceeds"
        );
        // Measured real-engine native transfers, including both native rounding
        // and the pricing library's conservative upper/lower cost endpoints.
        assertEq(
            token.balanceOf(address(first)) - initialFirstCash,
            decimals == 6 ? 19_355_181 : 19_355_181_656_647_213_769
        );
        assertEq(
            initialSecondCash - token.balanceOf(address(second)),
            decimals == 6 ? 81_366_633 : 81_366_632_352_474_966_244
        );
        assertEq(
            token.balanceOf(address(amm)) - initialEngineCash,
            decimals == 6 ? 62_011_452 : 62_011_450_695_827_752_475
        );
        (uint256 yes, uint256 no) = amm.getPosition(market, address(second));
        assertEq(yes, 100e18);
        assertEq(no, 0);
        _assertAndReportPnl(true, true);
    }

    function test_SameTransactionInterleavedZeroFeeProfitAttributedSixDecimals() public {
        _zeroFeeInterleaved(6);
    }

    function test_SameTransactionInterleavedZeroFeeProfitAttributedEighteenDecimals()
        public
    {
        _zeroFeeInterleaved(18);
    }

    function _fuzzInterleaved(
        uint8 decimals,
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint256 otherShares,
        uint8 sides,
        uint8 rateIndex,
        uint8 capitalIndex
    ) private {
        depth = bound(depth, 1e17, 1e24);
        odds = bound(odds, 1, 1e18 - 1);
        shares = bound(shares, 1, 8 * depth);
        otherShares = bound(otherShares, 1, 8 * depth);
        uint16[4] memory rates = [uint16(0), 1, 100, 10_000];
        uint16[3] memory capitals = [uint16(0), 5000, 10_000];
        _prepare(decimals, rates[rateIndex % 4], capitals[capitalIndex % 3], depth, odds);
        first.interleaved(
            market, sides % 2, shares, second, (sides >> 1) % 2, otherShares
        );
        _assertAndReportPnl(false, true);
    }

    function testFuzz_SameTransactionInterleavedConservationSixDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint256 otherShares,
        uint8 sides,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzInterleaved(6, depth, odds, shares, otherShares, sides, rate, capital);
    }

    function testFuzz_SameTransactionInterleavedConservationEighteenDecimals(
        uint256 depth,
        uint256 odds,
        uint256 shares,
        uint256 otherShares,
        uint8 sides,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzInterleaved(18, depth, odds, shares, otherShares, sides, rate, capital);
    }

    function _fuzzSequence(
        uint8 decimals,
        uint256 depth,
        uint256 odds,
        uint256 maxShares,
        uint256 sequenceSeed,
        uint8 rateIndex,
        uint8 capitalIndex
    ) private {
        depth = bound(depth, 1e17, 1e24);
        odds = bound(odds, 1, 1e18 - 1);
        maxShares = bound(maxShares, 1, 8 * depth);
        uint16[4] memory rates = [uint16(0), 1, 100, 10_000];
        uint16[3] memory capitals = [uint16(0), 5000, 10_000];
        _prepare(decimals, rates[rateIndex % 4], capitals[capitalIndex % 3], depth, odds);
        (uint256 buys, uint256 sells) =
            first.sequence(market, [first, second, third], sequenceSeed, maxShares);
        assertEq(buys + sells, 12, "all seeded actions executed");
        assertGe(buys, 3, "every actor seeded through a real buy");
        _assertAndReportPnl(false, false);
    }

    function testFuzz_SameTransactionThreeActorSequenceSixDecimals(
        uint256 depth,
        uint256 odds,
        uint256 maxShares,
        uint256 sequenceSeed,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzSequence(6, depth, odds, maxShares, sequenceSeed, rate, capital);
    }

    function testFuzz_SameTransactionThreeActorSequenceEighteenDecimals(
        uint256 depth,
        uint256 odds,
        uint256 maxShares,
        uint256 sequenceSeed,
        uint8 rate,
        uint8 capital
    ) public {
        _fuzzSequence(18, depth, odds, maxShares, sequenceSeed, rate, capital);
    }

    function test_SameBlockTradeStillInvalidatesLiquidityAdditionQuote() public {
        _prepare(18, 0, 0, 100e18, 0.5e18);
        IAMMEngine.LiquidityLimits memory limits = _liquidityLimits(market, 10e18);
        uint256 number = block.number;
        first.trade(market, 1, 10e18);
        assertEq(block.number, number);
        uint256 creatorBefore = token.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(AMMEngine.StaleLiquidityQuote.selector);
        amm.increaseLiquidity(market, 10e18, limits);
        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(manager.positionCount(market), 1);
        assertRoundTripAccounting();
    }
}

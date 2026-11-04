// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IAMMEngine} from "./interfaces/IAMMEngine.sol";
import {IAmmFeeVault} from "./interfaces/IAmmFeeVault.sol";
import {ITruthMarket} from "./interfaces/ITruthMarket.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LPPositionManager} from "./LPPositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PositionPricing} from "./libraries/PositionPricing.sol";
import {DecimalMath} from "./libraries/DecimalMath.sol";

/**
 * @title AMMEngine
 * @notice LMSR-based AMM — sole token custodian for AMM trades.
 * @dev Traders call tradePositions() directly. Capital stays in this engine, in
 *      its own token; the fee revenue share is pulled by AmmFeeVault at
 *      collection. The trade pipeline is strictly
 *      quote → effects → collect/payout → exact vault deposit. Buy revenue is
 *      funded by just-collected tokens; sell revenue and proceeds debit only
 *      their own market's collateral. Every fee grows b by its CAPITAL share;
 *      ordinary trades never mint LP. Fee claims live at the vault; the LP floor claim is
 *      pulled here via claimFloor().
 *      Solvency per token: native balance >= ceilNative(sum of market collateral
 *      and claimable floor liabilities). Sell conversion remainders remain in
 *      market collateral and its LP cash ledger.
 */
contract AMMEngine is IAMMEngine, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // Structs
    // ============================================

    struct MarketState {
        uint256 qYes; // YES quantity (WAD)
        uint256 qNo; // NO quantity (WAD)
        uint256 liquidity; // Liquidity parameter b (WAD)
        uint256 yesFraction; // sub-WAD pricing inventory, 1e36 basis
        uint256 noFraction;
        address tokenA; // Creator-selected token pinned at creation
        uint8 tokenADecimals; // Pinned conversion precision
        bool initialized;
    }

    /// @dev Compact trade-quote carrier (avoids stack-too-deep in the pipeline).
    struct TradeQuote {
        uint256 baseCost;
        uint256 fee;
        uint256 capitalWad;
        uint256 revenueWad;
    }

    /// @dev Economics pinned per market at initialization, copied from the
    ///      vault's registered config (immutable there).
    struct FeeSnapshot {
        uint16 ammFeeBps;
        uint16 capitalBps;
    }

    // ============================================
    // Constants
    // ============================================

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ============================================
    // Immutables
    // ============================================

    IMarketFactory public immutable marketFactory;
    IAmmFeeVault public immutable feeVault;
    address public immutable override positionManager;

    // ============================================
    // State Variables
    // ============================================

    mapping(address => MarketState) internal _markets;
    mapping(address => mapping(address => Position)) internal _positions;

    // LP token registry: market → LP token address
    /// @notice Market -> the ERC-6909 id of its creator bootstrap position.
    mapping(address => uint256) public override lpPositionOf;

    // Pinned per-market economics (from the vault config at initialization)
    mapping(address => FeeSnapshot) internal _feeCfg;

    // Floor entitlements recorded at LP burn
    mapping(address => uint256) private _claimableFloorLiability; // market → WAD
    mapping(address => mapping(address => uint256)) private _floorEntitlement; // market → holder → WAD

    // Per-market collateral tracking: cap payouts to each market's own funds
    mapping(address => uint256) private _marketCollateral;

    // Sum of all engine-side market collateral and floor claims for a token.
    mapping(address => uint256) private _totalTokenLiabilities;
    mapping(address => uint8) private _tokenDecimals;
    mapping(address => bool) private _tokenDecimalsInitialized;

    // Per-market cumulative settlement payouts already deducted from _marketCollateral
    mapping(address => uint256) internal _settledPayouts;

    // Per-market LMSR seed quantities (not claimable by any user)
    mapping(address => uint256) internal _seedQYes;
    mapping(address => uint256) internal _seedQNo;

    // ============================================
    // Events
    // ============================================

    event PositionSettled(
        address indexed user,
        address indexed market,
        uint8 winningOutcome,
        uint256 yesShares,
        uint256 noShares,
        uint256 payout
    );

    // ============================================
    // Errors
    // ============================================

    error ZeroMarketFactory();
    error ZeroMarket();
    error ZeroLiquidity();
    error AlreadyInitialized();
    error NotFinalized();
    error NoPosition();
    error InvalidOutcome();
    error NotInitialized();
    error ZeroDelta();
    error MarketNotLive();
    error InsufficientYesShares();
    error InsufficientNoShares();
    error InsufficientMarketYes();
    error InsufficientMarketNo();
    error CostTooHigh();
    error SlippageExceeded();
    error UnboundedLiquidityLimits();
    error StaleLiquidityQuote();
    error NotAuthorized();
    error ZeroFeeVault();
    error InsufficientLP();
    error NothingToClaim();
    error LPTokenAlreadySet();
    error RedeemNotAvailable();
    error InsufficientMarketCollateral();
    error TopUpsDisabled();
    error MintingClosed();
    error InvalidMarketToken();
    error TransferAmountMismatch();
    error InsufficientTokenCustody();

    // ============================================
    // Constructor
    // ============================================

    constructor(address _marketFactory, address _feeVault) {
        require(_marketFactory != address(0), ZeroMarketFactory());
        require(_feeVault != address(0), ZeroFeeVault());
        marketFactory = IMarketFactory(_marketFactory);
        feeVault = IAmmFeeVault(_feeVault);
        positionManager = address(new LPPositionManager(address(this), _feeVault));
    }

    // ============================================
    // Market Initialization
    // ============================================

    function initializeMarket(
        address market,
        address tokenA,
        uint8 tokenADecimals,
        uint256 initialLiquidity,
        uint256 initialQYes,
        uint256 initialQNo,
        uint256 creatorDeposit
    ) external {
        require(msg.sender == address(marketFactory), NotAuthorized());
        require(market != address(0), ZeroMarket());
        require(tokenA != address(0) && tokenADecimals <= 18, InvalidMarketToken());
        require(
            feeVault.tokenAOf(market) == tokenA
                && feeVault.tokenADecimalsOf(market) == tokenADecimals,
            InvalidMarketToken()
        );
        require(initialLiquidity >= 1e17, ZeroLiquidity());
        PositionPricing.validate(initialLiquidity, initialQYes, initialQNo);
        (, uint256 requiredDeposit) =
            PositionPricing.costBounds(initialLiquidity, initialQYes, initialQNo);
        require(creatorDeposit >= requiredDeposit, InsufficientMarketCollateral());
        require(!_markets[market].initialized, AlreadyInitialized());

        if (_tokenDecimalsInitialized[tokenA]) {
            require(_tokenDecimals[tokenA] == tokenADecimals, InvalidMarketToken());
        } else {
            _tokenDecimalsInitialized[tokenA] = true;
            _tokenDecimals[tokenA] = tokenADecimals;
        }

        _markets[market] = MarketState({
            qYes: initialQYes,
            qNo: initialQNo,
            liquidity: initialLiquidity,
            yesFraction: 0,
            noFraction: 0,
            tokenA: tokenA,
            tokenADecimals: tokenADecimals,
            initialized: true
        });

        _marketCollateral[market] = creatorDeposit;
        _totalTokenLiabilities[tokenA] += creatorDeposit;
        _seedQYes[market] = initialQYes;
        _seedQNo[market] = initialQNo;

        // Pin the market's economics from the vault's registered config
        // (reverts if the marketFactory has not registered the market first).
        IAmmFeeVault.AmmConfig memory cfg = feeVault.configOf(market);
        _feeCfg[market] = FeeSnapshot({ammFeeBps: cfg.feeBps, capitalBps: cfg.capitalBps});

        _requireTokenSolvent(tokenA);
        emit MarketInitialized(
            market, tokenA, tokenADecimals, initialLiquidity, creatorDeposit
        );
    }

    // ============================================
    // Trading
    // ============================================

    /// @inheritdoc IAMMEngine
    function tradePositions(
        address market,
        uint8 outcome,
        int256 deltaShares,
        uint256 maxCostOrMinProceeds
    ) external override nonReentrant returns (uint256 actualCost) {
        require(deltaShares != 0, ZeroDelta());
        require(outcome <= 1, InvalidOutcome());
        require(ITruthMarket(market).isTradingOpen(), MarketNotLive());

        MarketState storage mState = _markets[market];
        require(mState.initialized, NotInitialized());

        Position storage position = _positions[market][msg.sender];

        bool isBuy = deltaShares > 0;
        uint256 absDelta = isBuy ? uint256(deltaShares) : uint256(-deltaShares);

        // Calculate new quantities
        uint256 newQYes;
        uint256 newQNo;

        if (outcome == 1) {
            // YES
            if (isBuy) {
                newQYes = mState.qYes + absDelta;
                newQNo = mState.qNo;
            } else {
                require(position.yesShares >= absDelta, InsufficientYesShares());
                require(mState.qYes >= absDelta, InsufficientMarketYes());
                newQYes = mState.qYes - absDelta;
                newQNo = mState.qNo;
            }
        } else {
            // NO
            if (isBuy) {
                newQYes = mState.qYes;
                newQNo = mState.qNo + absDelta;
            } else {
                require(position.noShares >= absDelta, InsufficientNoShares());
                require(mState.qNo >= absDelta, InsufficientMarketNo());
                newQYes = mState.qYes;
                newQNo = mState.qNo - absDelta;
            }
        }

        // ── 1. QUOTE: pure computation, nothing has moved yet ──
        TradeQuote memory q = _quoteFees(market, isBuy, mState, newQYes, newQNo);

        // ── 2. EFFECTS: every state write before any external interaction ──
        mState.qYes = newQYes;
        mState.qNo = newQNo;
        mState.liquidity += q.capitalWad;
        PositionPricing.validate(mState.liquidity, newQYes, newQNo);
        if (isBuy) {
            actualCost = q.baseCost + q.fee;
            require(actualCost <= maxCostOrMinProceeds, CostTooHigh());
            // Attribute the entire native-unit receipt retained after the
            // sendable revenue transfer to this market. This includes both
            // WAD/native conversion remainders, so no same-token market can
            // consume another market's otherwise-unassigned rounding dust.
            uint256 retainedWad =
                _receivableWad(market, actualCost) - _sendableWad(market, q.revenueWad);
            _marketCollateral[market] += retainedWad;
            _totalTokenLiabilities[mState.tokenA] += retainedWad;
            LPPositionManager(positionManager)
                .recordTrade(market, outcome, deltaShares, int256(retainedWad));
            if (outcome == 1) position.yesShares += absDelta;
            else position.noShares += absDelta;
        } else {
            actualCost = q.baseCost - q.fee; // net proceeds
            if (maxCostOrMinProceeds > 0) {
                require(actualCost >= maxCostOrMinProceeds, SlippageExceeded());
            }
            if (outcome == 1) position.yesShares -= absDelta;
            else position.noShares -= absDelta;
            // Only native-sendable proceeds and revenue leave custody. Retain
            // each sell's sub-native remainder in this market's collateral and
            // existing LP cash allocation, never outside the liability ledger.
            uint256 debitWad =
                _sendableWad(market, actualCost) + _sendableWad(market, q.revenueWad);
            LPPositionManager(positionManager)
                .recordTrade(market, outcome, deltaShares, -int256(debitWad));
            _marketCollateral[market] -= debitWad;
            _totalTokenLiabilities[mState.tokenA] -= debitWad;
        }

        // ── 3. CASH: exact buyer collection or same-transaction seller payout ──
        if (isBuy) {
            _collectExactTokenA(market, msg.sender, actualCost);
        } else {
            _pushExactTokenA(mState.tokenA, msg.sender, _wadToToken(market, actualCost));
        }

        // ── 4. DEPOSIT the revenue share to the vault.
        _depositRevenue(market, q.revenueWad);
        _requireTokenSolvent(mState.tokenA);

        emit PositionTraded(
            msg.sender, market, outcome, deltaShares, actualCost, newQYes, newQNo
        );

        return actualCost;
    }

    // ============================================
    // Settlement
    // ============================================

    /// @inheritdoc IAMMEngine
    function settlePosition(address market)
        external
        override
        nonReentrant
        returns (uint256 payout)
    {
        require(ITruthMarket(market).isSettled(), NotFinalized());

        Position storage position = _positions[market][msg.sender];
        require(position.yesShares > 0 || position.noShares > 0, NoPosition());

        uint8 winningOutcome_ = ITruthMarket(market).winningOutcome();

        uint256 yesShares = position.yesShares;
        uint256 noShares = position.noShares;

        // Clear position first (CEI pattern)
        position.yesShares = 0;
        position.noShares = 0;

        if (winningOutcome_ == 1) {
            payout = yesShares;
        } else if (winningOutcome_ == 0) {
            payout = noShares;
        } else {
            payout = (yesShares + noShares) / 2;
        }

        if (payout > 0) {
            // Debit only what actually leaves; the entitlement is still fully
            // discharged, so _settledPayouts records the whole payout.
            uint256 debitWad = _sendableWad(market, payout);
            require(debitWad <= _marketCollateral[market], InsufficientMarketCollateral());
            _marketCollateral[market] -= debitWad;
            _totalTokenLiabilities[_markets[market].tokenA] -= debitWad;
            _settledPayouts[market] += payout;
            _pushExactTokenA(
                _markets[market].tokenA, msg.sender, _wadToToken(market, payout)
            );
            _requireTokenSolvent(_markets[market].tokenA);
        }

        emit PositionSettled(
            msg.sender, market, winningOutcome_, yesShares, noShares, payout
        );
    }

    // ============================================
    // LP Operations
    // ============================================

    /// @inheritdoc IAMMEngine
    function mintLPTokens(address market, address to, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256 positionId)
    {
        // Bootstrap mint only: the creator's one-time registration mint at
        // createMarket. Ordinary trades never mint LP units.
        require(msg.sender == address(marketFactory), NotAuthorized());
        require(lpPositionOf[market] == 0, LPTokenAlreadySet());
        require(amount == _marketCollateral[market], InvalidMarketToken());

        LPPositionManager manager = LPPositionManager(positionManager);
        positionId = manager.bootstrap(market, to, _markets[market].liquidity, amount);
        lpPositionOf[market] = positionId;
        feeVault.enablePositionFees(market, positionManager);

        emit LPMinted(market, to, amount, manager.totalSupply(positionId));
    }

    /// @inheritdoc IAMMEngine
    function redeemLP(address market, uint256 lpAmount)
        external
        override
        nonReentrant
        returns (uint256 tokenAmount)
    {
        return _redeemLP(market, lpPositionOf[market], lpAmount);
    }

    function redeemLPPosition(address market, uint256 positionId, uint256 amount)
        external
        override
        nonReentrant
        returns (uint256)
    {
        return _redeemLP(market, positionId, amount);
    }

    /// @notice Pull a floor entitlement recorded at redeemLP. Independent of the
    ///         vault dividend pulls — custody never aggregates across contracts.
    function claimFloor(address market)
        external
        override
        nonReentrant
        returns (uint256 amount)
    {
        return _claimFloor(market, msg.sender, false);
    }

    /// @notice Collect everything a position has available in one transaction.
    /// @dev Redeem, floor and fees were three separate caller-scoped calls, so an LP
    ///      needed 2N+1 transactions to clear N positions. Order is forced: the redeem
    ///      credits the floor entitlement and moves the fee slice, so it must run first.
    ///      Components that have nothing to pay return zero rather than reverting, so a
    ///      client can call this unconditionally.
    /// @param units LP units to redeem, or zero to only sweep floor and fees.
    /// @return redeemedWad Residual floor entitlement credited by the redeem, **WAD**.
    ///         Not LP units burned and not a cash transfer. `_redeemLP` returns
    ///         `manager.redeem`, which is then credited to the floor and discharged
    ///         as `floorPaid` in this same call.
    /// @return floorPaid Floor entitlement discharged, **WAD** — divide by
    ///         `10**(18 - tokenADecimals)` for the native amount that moved.
    /// @return feesPaid Vault dividend, **native Token A units** — already the
    ///         transferred amount.
    /// @dev **The three returns are not in the same unit; summing them is a bug**
    ///      (issue #1, I-1). The native total actually transferred is
    ///      `floorPaid / 10**(18 - decimals) + feesPaid`. `redeemedWad` is not a
    ///      third cash leg. See `LPProceedsClaimed`.
    function claimAvailable(address market, uint256 positionId, uint256 units)
        external
        nonReentrant
        returns (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid)
    {
        // The private redeem, not the external one: that is nonReentrant and would
        // double-guard against this function's own guard.
        if (units > 0) redeemedWad = _redeemLP(market, positionId, units);
        floorPaid = _claimFloor(market, msg.sender, true);
        feesPaid = feeVault.claimLPDividendFor(market, positionId, msg.sender);
        emit LPProceedsClaimed(
            msg.sender, market, positionId, redeemedWad, floorPaid, feesPaid
        );
    }

    // ============================================
    // Public Separate-Entry Liquidity
    // ============================================

    /// @inheritdoc IAMMEngine
    function increaseLiquidity(
        address market,
        uint256 additionalB,
        LiquidityLimits calldata limits
    ) external override nonReentrant returns (uint256 positionId, uint256 depositWad) {
        require(ITruthMarket(market).isLiquidityOpen(), MintingClosed());
        require(
            limits.maxTokenIn > 0 && limits.maxTokenIn < type(uint256).max
                && limits.minLpOut > 0 && limits.minYesPrice > 0
                && limits.maxYesPrice < WAD && limits.minYesPrice <= limits.maxYesPrice
                && limits.deadline <= ITruthMarket(market).deadline(),
            UnboundedLiquidityLimits()
        );
        require(block.timestamp <= limits.deadline, SlippageExceeded());
        require(
            limits.expectedStateHash != bytes32(0)
                && limits.expectedStateHash == liquidityStateHash(market),
            StaleLiquidityQuote()
        );
        {
            (uint256 nativeIn, uint256 units, uint256 price) =
                quoteLiquidity(market, additionalB);
            require(
                nativeIn <= limits.maxTokenIn && units >= limits.minLpOut
                    && price >= limits.minYesPrice && price <= limits.maxYesPrice,
                SlippageExceeded()
            );
            depositWad = units;
        }
        MarketState storage m = _markets[market];
        uint256 oldB = m.liquidity;
        _scalePricing(market, oldB + additionalB);
        _marketCollateral[market] += depositWad;
        _totalTokenLiabilities[m.tokenA] += depositWad;
        // Exact inbound transfer completes before minting the new entry receipt.
        _collectExactTokenA(market, msg.sender, depositWad);
        positionId = LPPositionManager(positionManager)
            .add(market, msg.sender, oldB, additionalB, depositWad);
        _requireTokenSolvent(m.tokenA);
        emit LiquidityPositionAdded(
            market, msg.sender, positionId, additionalB, depositWad
        );
    }

    function accountingLocked() external view override returns (bool) {
        return _reentrancyGuardEntered();
    }

    // ============================================
    // View Functions
    // ============================================

    /// @notice The market's total unclaimed floor entitlements.
    function claimableFloorLiability(address market)
        external
        view
        override
        returns (uint256)
    {
        return _claimableFloorLiability[market];
    }

    function floorEntitlementOf(address market, address holder)
        external
        view
        override
        returns (uint256)
    {
        return _floorEntitlement[market][holder];
    }

    /// @inheritdoc IAMMEngine
    function getPositionQuote(address market, uint8 outcome, int256 deltaShares)
        external
        view
        override
        returns (uint256 cost, uint256 fee, uint256 netAmount, uint256 newPrice)
    {
        require(deltaShares != 0, ZeroDelta());
        require(outcome <= 1, InvalidOutcome());
        MarketState memory mState = _markets[market];
        require(mState.initialized, NotInitialized());

        bool isBuy = deltaShares > 0;
        uint256 absDelta = isBuy ? uint256(deltaShares) : uint256(-deltaShares);

        uint256 newQYes;
        uint256 newQNo;

        if (outcome == 1) {
            if (isBuy) {
                newQYes = mState.qYes + absDelta;
                newQNo = mState.qNo;
            } else {
                require(mState.qYes >= absDelta, InsufficientMarketYes());
                newQYes = mState.qYes - absDelta;
                newQNo = mState.qNo;
            }
        } else {
            if (isBuy) {
                newQYes = mState.qYes;
                newQNo = mState.qNo + absDelta;
            } else {
                newQYes = mState.qYes;
                require(mState.qNo >= absDelta, InsufficientMarketNo());
                newQNo = mState.qNo - absDelta;
            }
        }

        cost = PositionPricing.tradeCost(
            mState.liquidity, mState.qYes, mState.qNo, newQYes, newQNo, isBuy
        );

        FeeSnapshot storage feeCfg = _feeCfg[market];
        fee = (cost * feeCfg.ammFeeBps) / BPS_DENOMINATOR;
        netAmount = isBuy ? cost + fee : cost - fee;

        // newPrice reflects the fee-induced b
        // change the trade itself will cause — never the stale liquidity.
        uint256 deltaB = (fee * feeCfg.capitalBps) / BPS_DENOMINATOR;
        newPrice = PositionPricing.probability(mState.liquidity + deltaB, newQYes, newQNo);
    }

    /// @inheritdoc IAMMEngine
    function getPosition(address market, address user)
        external
        view
        override
        returns (uint256 yesShares, uint256 noShares)
    {
        Position memory position = _positions[market][user];
        return (position.yesShares, position.noShares);
    }

    function getMarketCollateral(address market)
        external
        view
        override
        returns (uint256)
    {
        return _marketCollateral[market];
    }

    /// @inheritdoc IAMMEngine
    function getMarketState(address market)
        external
        view
        override
        returns (uint256 qYes, uint256 qNo, uint256 price)
    {
        MarketState memory mState = _markets[market];
        require(mState.initialized, NotInitialized());

        qYes = mState.qYes;
        qNo = mState.qNo;
        price = PositionPricing.probability(mState.liquidity, qYes, qNo);
    }

    /// @inheritdoc IAMMEngine
    function getLiquidity(address market) external view override returns (uint256) {
        return _markets[market].liquidity;
    }

    /// @inheritdoc IAMMEngine
    /// @dev `b`-side only: the YES/NO inventory bounds of `PositionPricing.validate`
    ///      are not reflected here, so a positive `tradeHeadroom` is not a
    ///      guarantee that a given trade will not revert with `Domain()`.
    function liquidityHeadroom(address market)
        external
        view
        override
        returns (uint256 tradeHeadroom, uint256 admissionHeadroom)
    {
        uint256 b = _markets[market].liquidity;
        require(_markets[market].initialized, NotInitialized());
        tradeHeadroom =
            b < PositionPricing.MAX_AMOUNT ? PositionPricing.MAX_AMOUNT - b : 0;
        admissionHeadroom = b < PositionPricing.MAX_ADMITTED_DEPTH
            ? PositionPricing.MAX_ADMITTED_DEPTH - b
            : 0;
    }

    /// @inheritdoc IAMMEngine
    function tokenAOf(address market) external view override returns (address) {
        MarketState storage mState = _markets[market];
        require(mState.initialized, NotInitialized());
        return mState.tokenA;
    }

    /// @inheritdoc IAMMEngine
    function tokenADecimalsOf(address market) external view override returns (uint8) {
        MarketState storage mState = _markets[market];
        require(mState.initialized, NotInitialized());
        return mState.tokenADecimals;
    }

    /// @inheritdoc IAMMEngine
    function totalLiabilitiesOf(address token) external view override returns (uint256) {
        return _totalTokenLiabilities[token];
    }

    // ============================================
    // Internal: LP Floor Calculation
    // ============================================

    /// @inheritdoc IAMMEngine
    function increaseLiquidityFromCreator(address, uint256) external pure override {
        // Retained selector, permanently disabled: it has no slippage protection
        // and issued pooled claims. Config cannot revive this inherited behavior.
        revert TopUpsDisabled();
    }

    function quoteLiquidity(address market, uint256 additionalB)
        public
        view
        override
        returns (uint256 tokenIn, uint256 receiptUnits, uint256 price)
    {
        MarketState storage m = _markets[market];
        require(m.initialized, NotInitialized());
        uint256 funding = PositionPricing.funding(m.liquidity, m.qYes, m.qNo, additionalB);
        funding += PositionPricing.weightBuffer(
            m.liquidity,
            m.qYes,
            m.qNo,
            LPPositionManager(positionManager).totalWeight(market)
        );
        tokenIn = _wadToTokenCeil(market, funding);
        receiptUnits = DecimalMath.toWad(tokenIn, m.tokenADecimals);
        price = PositionPricing.probability(m.liquidity, m.qYes, m.qNo);
    }

    /// @inheritdoc IAMMEngine
    function quoteLiquidityWithState(address market, uint256 additionalB)
        external
        view
        override
        returns (uint256 tokenIn, uint256 receiptUnits, uint256 price, bytes32 stateHash)
    {
        (tokenIn, receiptUnits, price) = quoteLiquidity(market, additionalB);
        stateHash = liquidityStateHash(market);
    }

    /// @inheritdoc IAMMEngine
    function liquidityStateHash(address market) public view override returns (bytes32) {
        MarketState storage m = _markets[market];
        require(m.initialized, NotInitialized());
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                market,
                m.liquidity,
                m.qYes,
                m.qNo,
                m.yesFraction,
                m.noFraction,
                LPPositionManager(positionManager).totalWeight(market)
            )
        );
    }

    /// @dev Market-wide safety ceiling: collateral net of outstanding user claims.
    /// Native sell payouts and transferred fees were already removed from collateral.
    /// Individual LP payouts come from their entry ledger, not a slice of this ceiling.
    function _calculateFloor(address market) internal view returns (uint256) {
        // Fee obligations are AmmFeeVault liabilities, not engine collateral, so
        // the floor reserves only the remaining settlement liability owed to
        // position holders.
        MarketState memory mState = _markets[market];
        // Seed shares have no owner and cannot be redeemed.
        uint256 claimableYes =
            mState.qYes > _seedQYes[market] ? mState.qYes - _seedQYes[market] : 0;
        uint256 claimableNo =
            mState.qNo > _seedQNo[market] ? mState.qNo - _seedQNo[market] : 0;
        uint256 totalLiability;
        uint8 outcome = ITruthMarket(market).winningOutcome();
        if (outcome == 1) {
            totalLiability = claimableYes;
        } else if (outcome == 0) {
            totalLiability = claimableNo;
        } else {
            totalLiability = (claimableYes + claimableNo) / 2;
        }
        uint256 remainingLiability = totalLiability > _settledPayouts[market]
            ? totalLiability - _settledPayouts[market]
            : 0;

        uint256 collateral = _marketCollateral[market];
        return collateral > remainingLiability ? collateral - remainingLiability : 0;
    }

    // ============================================
    // Internal Helpers
    // ============================================

    function _wadToToken(address market, uint256 wadAmount)
        internal
        view
        returns (uint256)
    {
        return DecimalMath.fromWad(wadAmount, _markets[market].tokenADecimals);
    }

    function _wadToTokenCeil(address market, uint256 wadAmount)
        internal
        view
        returns (uint256)
    {
        return DecimalMath.fromWadCeil(wadAmount, _markets[market].tokenADecimals);
    }

    /// @dev The WAD value a transfer can actually carry: toWad(fromWad(x)).
    ///      A sub-unit remainder physically cannot move, so the WAD ledger must
    ///      be debited by this — never by the pre-rounding amount. Debiting more
    ///      than left would make _marketCollateral understate the tokens the
    ///      engine still holds, and that counter gates every payout. Identity on
    ///      an 18-decimal token, where fromWad/toWad are both no-ops.
    function _sendableWad(address market, uint256 wadAmount)
        internal
        view
        returns (uint256)
    {
        uint8 decimals = _markets[market].tokenADecimals;
        return DecimalMath.toWad(_wadToToken(market, wadAmount), decimals);
    }

    function _claimFloor(address market, address holder, bool allowZero)
        private
        returns (uint256 amount)
    {
        amount = _sendableWad(market, _floorEntitlement[market][holder]);
        if (amount == 0) {
            require(allowZero, NothingToClaim());
            return 0;
        }
        _floorEntitlement[market][holder] -= amount;
        _claimableFloorLiability[market] -= amount;
        address tokenA = _markets[market].tokenA;
        uint256 sendableWad = _sendableWad(market, amount);
        _totalTokenLiabilities[tokenA] -= sendableWad;
        _pushExactTokenA(tokenA, holder, _wadToToken(market, amount));
        _requireTokenSolvent(tokenA);
        emit FloorClaimed(holder, market, amount);
    }

    function _redeemLP(address market, uint256 positionId, uint256 lpAmount)
        private
        returns (uint256 tokenAmount)
    {
        // Lazy finalization first: permissionless and
        // idempotent — when the market is invalidation-eligible and unsettled,
        // the vault performs invalidate() itself, so the first redeemer makes
        // settlement happen in one transaction. Reverts NotFinalizable when
        // settlement is not reachable yet.
        feeVault.finalize(market);
        require(ITruthMarket(market).isSettled(), RedeemNotAvailable());

        require(lpPositionOf[market] != 0, NotInitialized());

        LPPositionManager manager = LPPositionManager(positionManager);
        require(manager.balanceOf(msg.sender, positionId) >= lpAmount, InsufficientLP());

        // Pro-rata against the supply BEFORE this burn — the frozen cohort
        uint256 supplyBeforeBurn = manager.totalSupply(positionId);
        tokenAmount = manager.redeem(market, positionId, msg.sender, lpAmount);
        // Defense in depth: LP cannot consume outstanding trader liabilities.
        require(tokenAmount <= _calculateFloor(market), InsufficientMarketCollateral());

        // State-only burn: record the market Token-A floor entitlement here (collateral
        // debited in the same write — the floor must shrink at burn time or a
        // second partial redeemer over-allocates)...
        if (tokenAmount > 0) {
            require(
                tokenAmount <= _marketCollateral[market], InsufficientMarketCollateral()
            );
            _marketCollateral[market] -= tokenAmount;
            _claimableFloorLiability[market] += tokenAmount;
            _floorEntitlement[market][msg.sender] += tokenAmount;
        }

        // ...and the Token-A vault dividend entitlement. Book-token value is
        // structurally excluded. The vault lazily finalizes before this first slice.
        feeVault.notifyLPBurn(market, msg.sender, lpAmount, supplyBeforeBurn);

        emit LPRedeemed(msg.sender, market, lpAmount, tokenAmount);
    }

    function _scalePricing(address market, uint256 newB) private {
        MarketState storage m = _markets[market];
        // Carry sub-WAD inventory across repeated entries. Discarding it at each
        // entry would accumulate price drift. Actual user shares remain integers.
        uint256 y = Math.mulDiv(m.qYes * 1e36 + m.yesFraction, newB, m.liquidity);
        uint256 n = Math.mulDiv(m.qNo * 1e36 + m.noFraction, newB, m.liquidity);
        PositionPricing.validate(newB, y / 1e36, n / 1e36);
        _seedQYes[market] += y / 1e36 - m.qYes;
        _seedQNo[market] += n / 1e36 - m.qNo;
        m.qYes = y / 1e36;
        m.qNo = n / 1e36;
        m.yesFraction = y % 1e36;
        m.noFraction = n % 1e36;
        m.liquidity = newB;
    }

    function _collectExactTokenA(address market, address from, uint256 wadAmount)
        private
    {
        MarketState storage mState = _markets[market];
        IERC20 token = IERC20(mState.tokenA);
        uint256 expectedNative = _wadToTokenCeil(market, wadAmount);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 payerBefore = token.balanceOf(from);
        token.safeTransferFrom(from, address(this), expectedNative);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 payerAfter = token.balanceOf(from);
        require(
            afterBalance >= beforeBalance
                && afterBalance - beforeBalance == expectedNative
                && payerBefore >= payerAfter
                && payerBefore - payerAfter == expectedNative,
            TransferAmountMismatch()
        );
    }

    /// @dev A failed or short payout must preserve the full claim for retry.
    function _pushExactTokenA(address tokenAddress, address to, uint256 amount) private {
        if (amount == 0) return;
        IERC20 token = IERC20(tokenAddress);
        uint256 sourceBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 sourceAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        require(
            sourceBefore >= sourceAfter && sourceBefore - sourceAfter == amount
                && recipientAfter >= recipientBefore
                && recipientAfter - recipientBefore == amount,
            TransferAmountMismatch()
        );
    }

    /// @dev The venue vault pulls only the native revenue share in its guarded,
    ///      exact-receipt call. Ordinary trades do not mint LP.
    function _depositRevenue(address market, uint256 revenueWad) private {
        MarketState storage mState = _markets[market];
        IERC20 tokenA = IERC20(mState.tokenA);
        if (revenueWad > 0) {
            uint256 revenueNative = _wadToToken(market, revenueWad);
            if (revenueNative > 0) {
                tokenA.forceApprove(address(feeVault), revenueNative);
                require(
                    feeVault.depositRevenue(market, revenueNative, msg.sender)
                        == revenueNative,
                    TransferAmountMismatch()
                );
            }
        }
    }

    function _requireTokenSolvent(address token) private view {
        require(
            IERC20(token).balanceOf(address(this))
                >= DecimalMath.fromWadCeil(
                    _totalTokenLiabilities[token], _tokenDecimals[token]
                ),
            InsufficientTokenCustody()
        );
    }

    /// @dev The normalized WAD value collected when a WAD amount is rounded up
    ///      to the market token's smallest native unit.
    function _receivableWad(address market, uint256 wadAmount)
        private
        view
        returns (uint256)
    {
        uint8 decimals = _markets[market].tokenADecimals;
        return DecimalMath.toWad(_wadToTokenCeil(market, wadAmount), decimals);
    }

    /// @dev Step 1 of the pipeline: LMSR base cost + fee decomposition from the
    ///      pinned per-market economics. Pure view computation.
    function _quoteFees(
        address market,
        bool isBuy,
        MarketState storage mState,
        uint256 newQYes,
        uint256 newQNo
    ) private view returns (TradeQuote memory q) {
        q.baseCost = PositionPricing.tradeCost(
            mState.liquidity, mState.qYes, mState.qNo, newQYes, newQNo, isBuy
        );
        FeeSnapshot storage feeCfg = _feeCfg[market];
        q.fee = (q.baseCost * feeCfg.ammFeeBps) / BPS_DENOMINATOR;
        q.capitalWad = (q.fee * feeCfg.capitalBps) / BPS_DENOMINATOR;
        q.revenueWad = q.fee - q.capitalWad;
    }
}

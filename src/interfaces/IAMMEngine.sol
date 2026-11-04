// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/**
 * @title IAMMEngine
 * @notice Interface for the LMSR-based AMM and sole token custodian for AMM trades.
 * @dev Traders call tradePositions() directly. Dual-token architecture: capital
 *      stays in the engine; the fee revenue share is pulled by AmmFeeVault at
 *      collection (pipeline: quote → effects → collect/payout → exact deposit).
 *      Positions are non-transferable ledger entries; sells pay directly in
 *      the same transaction. LP mint / redeem live here;
 *      fee claims live at the vault; the floor claim is pulled here.
 */
interface IAMMEngine {
    /// @notice Sponsor-selected execution bounds and an exact pricing-state quote.
    /// @dev A trade or liquidity addition that changes the quoted pricing state
    ///      invalidates this request. Callers must refresh, never replace the hash
    ///      silently at execution. This protects accepted entry economics at the
    ///      cost of failed inclusion when other participants change the market.
    ///      Max input and min receipt must be nonzero; unlimited input, endpoints
    ///      0/1 for the odds range, and deadlines beyond the market are rejected.
    struct LiquidityLimits {
        uint256 maxTokenIn; // Native Token-A units
        uint256 minLpOut; // WAD receipts within the new entry only
        uint256 minYesPrice; // WAD probability, inclusive — SET THIS
        uint256 maxYesPrice; // WAD probability, inclusive — AND THIS
        uint256 deadline; // Caller transaction deadline, no later than market deadline
        bytes32 expectedStateHash; // Obtain atomically with quoteLiquidityWithState
    }
    // ============================================
    // Structs
    // ============================================

    struct Position {
        uint256 yesShares;
        uint256 noShares;
    }

    // ============================================
    // Events
    // ============================================

    event PositionTraded(
        address indexed user,
        address indexed market,
        uint8 outcome,
        int256 deltaShares,
        uint256 cost,
        uint256 newQYes,
        uint256 newQNo
    );
    event LiquidityPositionAdded(
        address indexed market,
        address indexed holder,
        uint256 indexed positionId,
        uint256 addedDepth,
        uint256 depositWad
    );

    event MarketInitialized(
        address indexed market,
        address indexed tokenA,
        uint8 tokenADecimals,
        uint256 initialLiquidity,
        uint256 creatorDeposit
    );

    event LPMinted(
        address indexed market, address indexed to, uint256 amount, uint256 newTotalSupply
    );

    event LPRedeemed(
        address indexed user,
        address indexed market,
        uint256 lpAmount,
        uint256 tokenAmount
    );

    event FloorClaimed(address indexed user, address indexed market, uint256 amount);

    /// @notice Emitted by `claimAvailable`. **The three amounts are NOT in the same
    ///         unit — do not add them.**
    /// @dev For a Token A with `d` decimals:
    ///
    ///        native Token A actually transferred
    ///          == floorPaid / 10**(18 - d)  +  feesPaid
    ///
    ///      They coincide only at `d == 18`, so a consumer that sums the fields to
    ///      show "total claimed" is wrong by a factor of 10**(18-d) on every other
    ///      token — 1e12 for a 6-decimal one. The payout arithmetic is correct; this
    ///      is about reading the tuple.
    /// @param redeemedWad Residual floor entitlement credited by the redeem, **WAD**.
    ///        Not LP units burned and not a cash amount. The redeem is a state-only
    ///        burn that records this entitlement; `floorPaid` is the cash leg.
    /// @param floorPaid Floor entitlement discharged, **WAD**. Divide by
    ///        `10**(18 - decimals)` for the native amount that moved.
    /// @param feesPaid Vault dividend paid, **native Token A units**. Already the
    ///        transferred amount; do not scale it.
    event LPProceedsClaimed(
        address indexed holder,
        address indexed market,
        uint256 indexed positionId,
        uint256 redeemedWad,
        uint256 floorPaid,
        uint256 feesPaid
    );

    event LiquidityIncreasedFromCreator(
        address indexed market,
        uint256 additionalB,
        uint256 depositRequired,
        uint256 newLiquidity
    );

    // ============================================
    // Functions
    // ============================================

    /// @notice Add a price-neutral, separate liquidity entry within explicit limits.
    /// @dev Requires nonzero finite input/minimum receipt, odds strictly inside
    ///      (0, WAD), deadline no later than the market, and the exact quoted state.
    ///      A very wide [1, WAD-1] odds band is allowed; tightness is caller-selected.
    function increaseLiquidity(
        address market,
        uint256 additionalB,
        LiquidityLimits calldata limits
    ) external returns (uint256 positionId, uint256 depositWad);
    function redeemLPPosition(address market, uint256 positionId, uint256 amount)
        external
        returns (uint256);

    /// @notice Initialize AMM state after the marketFactory registers the market with AmmFeeVault.
    function initializeMarket(
        address market,
        address tokenA,
        uint8 tokenADecimals,
        uint256 initialLiquidity,
        uint256 initialQYes,
        uint256 initialQNo,
        uint256 creatorDeposit
    ) external;

    /**
     * @notice Buy (deltaShares > 0) or sell (deltaShares < 0) outcome shares
     * @dev Pipeline: quote → effects → collect/payout → deposit. The configured CAPITAL
     *      share grows `b` and the remainder is deposited to AmmFeeVault.
     *      Ordinary trades never mint LP. Sells pay floorNative(net proceeds)
     *      exactly in this transaction; sub-native remainders stay in market
     *      principal/LP accounting. A failed or inexact transfer reverts the trade.
     * @param maxCostOrMinProceeds WAD max cost on a buy; WAD min proceeds on a sell
     * @return actualCost WAD cost on a buy or net sell proceeds before native rounding
     */
    function tradePositions(
        address market,
        uint8 outcome,
        int256 deltaShares,
        uint256 maxCostOrMinProceeds
    ) external returns (uint256 actualCost);

    /**
     * @notice Redeem a settled position for its outcome payout (in WAD)
     */
    function settlePosition(address market) external returns (uint256 payout);

    // ============================================
    // LP Operations
    // ============================================

    /**
     * @notice Mint LP tokens for a market (bootstrap mint)
     * @dev Callable by MarketFactory only — the creator's one-time
     *      registration mint at createMarket. Ordinary trades never mint LP.
     * @param market Market address
     * @param to Recipient address
     * @param amount LP tokens to mint (WAD)
     */
    function mintLPTokens(address market, address to, uint256 amount)
        external
        returns (uint256 positionId);

    /**
     * @notice Redeem LP tokens (state-only burn recording Token-A claims)
     * @dev Compatibility shortcut for the creator's position-zero receipt.
     *      Burns a fraction of that entry's residual and records its engine-side
     *      entitlement while checkpointing earned Token-A fees. The holder pulls
     *      each independently: claimFloor() here; claimLPDividend() at the vault.
     * @param market Market address
     * @param lpAmount LP tokens to redeem (WAD)
     * @return tokenAmount Floor entitlement recorded (WAD)
     */
    function redeemLP(address market, uint256 lpAmount)
        external
        returns (uint256 tokenAmount);

    /**
     * @notice Pull a floor entitlement recorded at redeemLP
     * @return amount Amount transferred (WAD basis)
     */
    function claimFloor(address market) external returns (uint256 amount);

    /**
     * @notice Collect everything a position has available in one transaction
     * @dev Redeem, floor and fees are otherwise three caller-scoped calls, so an LP
     *      needs 2N+1 transactions to clear N positions. Components with nothing to
     *      pay return zero rather than reverting, so a client can call this without
     *      pre-checking each entitlement.
     * @param units LP units to redeem, or zero to only sweep floor and fees
     * @return redeemedWad Residual floor entitlement credited, **WAD** — not burned
     *         LP units and not cash
     * @return floorPaid Floor entitlement discharged, **WAD**
     * @return feesPaid Vault dividend, **native Token A**
     */
    function claimAvailable(address market, uint256 positionId, uint256 units)
        external
        returns (uint256 redeemedWad, uint256 floorPaid, uint256 feesPaid);

    // ============================================
    // Creator Liquidity Top-Up
    // ============================================

    /**
     * @notice Disabled inherited selector; always reverts.
     * @dev Use increaseLiquidity with a separate entry and explicit limits.
     */
    function increaseLiquidityFromCreator(address market, uint256 additionalB) external;

    // ============================================
    // View Functions
    // ============================================

    function positionManager() external view returns (address);
    function accountingLocked() external view returns (bool);
    function quoteLiquidity(address market, uint256 additionalB)
        external
        view
        returns (uint256 tokenIn, uint256 receiptUnits, uint256 price);

    /// @notice Exact native input, WAD receipt, odds and state commitment in one read.
    function quoteLiquidityWithState(address market, uint256 additionalB)
        external
        view
        returns (uint256 tokenIn, uint256 receiptUnits, uint256 price, bytes32 stateHash);

    /// @notice Commitment to chain, engine, market, depth, pricing inventories and
    ///         LP weight. Does not promise transaction inclusion or economic yield.
    function liquidityStateHash(address market) external view returns (bytes32);

    function getPositionQuote(address market, uint8 outcome, int256 deltaShares)
        external
        view
        returns (uint256 cost, uint256 fee, uint256 netAmount, uint256 newPrice);

    function getPosition(address market, address user)
        external
        view
        returns (uint256 yesShares, uint256 noShares);

    function getMarketState(address market)
        external
        view
        returns (uint256 qYes, uint256 qNo, uint256 price);

    function getLiquidity(address market) external view returns (uint256);

    /// @notice Remaining fee-driven `b` growth before the `b` bound of the pricing
    ///         domain closes. This is the `b`-side only.
    /// @dev Every fee-bearing trade grows `b` by its CAPITAL share and reverts with
    ///      `Domain()` once `b` would exceed the pricing library's checked bound.
    ///      Liquidity admission stops earlier, at the admitted-depth cap, so the
    ///      two values differ. The pricing library also bounds the YES and NO
    ///      inventories (`PositionPricing.validate`), and a trade that would push
    ///      either quantity past that bound reverts with `Domain()` regardless of
    ///      the values reported here. `tradeHeadroom > 0` therefore does NOT mean
    ///      "a trade cannot revert"; clients must simulate the trade itself.
    /// @return tradeHeadroom WAD growth of `b` still accepted before `Domain()`.
    /// @return admissionHeadroom WAD depth still admissible via `increaseLiquidity`.
    function liquidityHeadroom(address market)
        external
        view
        returns (uint256 tradeHeadroom, uint256 admissionHeadroom);

    function tokenAOf(address market) external view returns (address);

    function tokenADecimalsOf(address market) external view returns (uint8);

    function lpPositionOf(address market) external view returns (uint256);

    function claimableFloorLiability(address market) external view returns (uint256);

    function getMarketCollateral(address market) external view returns (uint256);

    function totalLiabilitiesOf(address token) external view returns (uint256);

    function floorEntitlementOf(address market, address holder)
        external
        view
        returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Gross outcome ownership, explicit action, one YES-price book.
interface IOrderEngine {
    struct OrderParams {
        uint8 outcome; // NO=0, YES=1
        uint8 action; // BUY=0, SELL=1
        uint16 priceTick; // price of the named outcome, 1..999
        uint128 amount; // WAD, aligned to shareUnit()
        uint32 matchLimit; // 1..256 queue iterations
        uint64 validUntil; // submission expiry
        uint64 expiry; // resting expiry; zero selects market deadline
        bool rest;
        bool postOnly;
        uint256 maxTokenIn; // native collateral, includes fee and new BUY reservation
        uint256 minTokenOut; // native proceeds after fee
    }

    struct OrderResult {
        uint128 filled;
        uint64 orderId;
        uint256 tokenIn;
        uint256 tokenOut;
        uint256 fee;
    }

    struct OrderView {
        address market;
        address maker;
        uint8 action;
        uint8 outcome;
        uint16 yesTick;
        uint128 amount;
        uint64 expiry;
        uint256 cashReserved;
    }

    event MarketRegistered(
        address indexed market, address baseToken, uint256 initialPrice
    );
    event OrderPlaced(
        address indexed market,
        address indexed maker,
        uint64 indexed orderId,
        uint8 action,
        uint8 outcome,
        uint16 yesTick,
        uint128 amount,
        uint64 expiry,
        uint256 cashReserved
    );
    event OrderFilled(
        address indexed market,
        uint64 indexed orderId,
        address indexed taker,
        uint128 amount,
        uint16 yesTick,
        uint8 settlementType,
        uint128 remaining,
        uint256 cashReserved
    );
    event OrderCancelled(
        address indexed market,
        address indexed maker,
        uint64 indexed orderId,
        uint128 amount,
        uint256 cashRefund
    );
    event OrderExecuted(
        address indexed market,
        address indexed user,
        uint8 action,
        uint8 outcome,
        uint128 filled,
        uint64 orderId,
        uint256 tokenIn,
        uint256 tokenOut,
        uint256 fee
    );
    event InventoryChanged(
        address indexed market,
        address indexed user,
        uint256 yesOwned,
        uint256 noOwned,
        uint256 yesReserved,
        uint256 noReserved,
        uint256 cashReserved
    );
    event Split(
        address indexed market, address indexed user, uint256 amount, uint256 collateral
    );
    event Merged(
        address indexed market, address indexed user, uint256 amount, uint256 collateral
    );
    event PositionSettled(address indexed market, address indexed user, uint256 payout);
    event InvalidRemainderChanged(
        address indexed market, address indexed user, uint8 halfNativeUnit
    );
    event PayoutDeferred(address indexed recipient, uint256 amount);
    event DeferredClaimed(address indexed recipient, uint256 amount);
    event HeadAdvanced(address indexed market, uint8 side, uint16 tick, uint256 head);
    event MakerCancelProgress(
        address indexed market,
        address indexed maker,
        uint8 side,
        uint16 tick,
        uint256 nextCursor,
        uint64 cancelledOrderId
    );

    function placeOrder(address market, OrderParams calldata params)
        external
        returns (OrderResult memory result);
    function split(address market, uint256 amount, uint256 maxTokenIn, uint64 validUntil)
        external
        returns (uint256 collateral);
    function merge(address market, uint256 amount, uint256 minTokenOut, uint64 validUntil)
        external
        returns (uint256 collateral);
    function cancelById(uint64 orderId) external;
    /// @notice Inspects at most 32 own historical IDs, cancelling the earliest live one.
    /// @return cancelledOrderId The cancelled ID, or zero if only dead IDs were skipped.
    /// @dev Progress is persisted and emitted. Repeat after zero; an already exhausted
    /// cursor reverts. Prefer cancelById when the intended order ID is known.
    function cancel(address market, uint8 side, uint16 yesTick)
        external
        returns (uint64 cancelledOrderId);
    function settlePosition(address market) external returns (uint256 payout);
    function claimDeferred() external returns (uint256 amount);
    function advanceHead(address market, uint8 side, uint16 tick, uint256 maxSteps)
        external
        returns (uint256 head);
    function registerMarket(address market, address baseToken, uint256 initialPrice)
        external;
    function baseToken() external view returns (IERC20);
    function shareUnit() external view returns (uint256);
    function getPosition(address market, address user)
        external
        view
        returns (uint256 yesShares, uint256 noShares);
    function getInventory(address market, address user)
        external
        view
        returns (
            uint256 yesOwned,
            uint256 noOwned,
            uint256 yesReserved,
            uint256 noReserved,
            uint256 cashReserved
        );
    function getNet(address market, address user) external view returns (int256);
    function getSupplies(address market)
        external
        view
        returns (uint256 yesSupply, uint256 noSupply);
    function invalidRemainderOf(address market, address user)
        external
        view
        returns (uint8);
    function getOrder(uint64 orderId) external view returns (OrderView memory);
    function getCollateralBacking(address market) external view returns (uint256);
    function isMarketRegistered(address market) external view returns (bool);
    function requireBeforeDeadline(address market) external view;
    function fillCount() external view returns (uint256);
}

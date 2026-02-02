// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title ILimitOrderManager
 * @author HyperLend
 * @notice Interface for the HyperLend Limit Order Manager
 * @dev Manages limit orders that integrate HyperLend deposits with Hyperliquid's HyperCore spot trading.
 *
 * Use Case: Users can create limit orders to sell their yield-bearing aTokens at a target price.
 * For example: User deposits aWHYPE, sets trigger price at $20. When HYPE reaches $20, the keeper:
 * 1. Withdraws WHYPE from HyperLend
 * 2. Bridges WHYPE to HyperCore spot balance
 * 3. Places a spot limit order to sell HYPE for USDC
 * 4. When filled, settles USDC back to the user
 *
 * Order Lifecycle:
 * 1. PENDING - Order created, waiting for trigger price to be reached
 * 2. TRIGGERED - Keeper detected trigger price, withdrew funds from HyperLend
 * 3. ON_HYPERCORE - Order bridged to HyperCore and placed on spot order book
 * 4. FILLED - Order filled on HyperCore (can be partial)
 * 5. SETTLED - Funds transferred to user (on EVM or HyperCore)
 *
 * Users can cancel PENDING orders or request refunds for TRIGGERED/ON_HYPERCORE orders.
 *
 * Spot Pair ID Format:
 * - hyperCoreSpotPairId = 10000 + spot_pair_index (e.g., 10107 for HYPE/USDC)
 * - The spot_pair_index can be found in HyperCore's spotMeta.universe
 */
interface ILimitOrderManager {
    // ============ Custom Errors ============

    /// @notice Thrown when caller is not an authorized keeper
    error NotAuthorizedKeeper();

    /// @notice Thrown when caller is not an authorized keeper or the order owner
    error NotAuthorizedKeeperOrOwner();

    /// @notice Thrown when caller is not the order owner
    error NotOrderOwner();

    /// @notice Thrown when order amount is zero
    error ZeroAmount();

    /// @notice Thrown when aToken address is zero
    error InvalidAToken();

    /// @notice Thrown when allowance is insufficient for the order amount
    error InsufficientAllowance();

    /// @notice Thrown when underlying token cannot be resolved from aToken
    error InvalidUnderlying();

    /// @notice Thrown when order is not in PENDING status
    error OrderNotPending();

    /// @notice Thrown when order is not in TRIGGERED status
    error OrderNotTriggered();

    /// @notice Thrown when order is not in BRIDGING status
    error OrderNotBridging();

    /// @notice Thrown when order is not on HyperCore (TRIGGERED or ON_HYPERCORE)
    error OrderNotOnHyperCore();

    /// @notice Thrown when order is not in FILLED status
    error OrderNotFilled();

    /// @notice Thrown when order cannot be refunded in current status
    error CannotRefundInCurrentStatus();

    /// @notice Thrown when withdrawal amount doesn't match expected amount
    error WithdrawalAmountMismatch();

    /// @notice Thrown when HyperCore token is not configured for the asset ID
    error TokenNotConfigured();

    /// @notice Thrown when order is not in ON_HYPERCORE status (for cancellation request)
    error OrderNotOnHyperCoreForCancellation();

    /// @notice Thrown when order is not in CANCEL_REQUESTED status
    error OrderNotCancelRequested();

    /// @notice Thrown when the contract doesn't have enough balance on HyperCore to settle
    error InsufficientHyperCoreBalance();

    // ============ Enums ============

    /**
     * @notice Represents the current status of a limit order
     * @dev Status transitions: NONE -> PENDING -> TRIGGERED -> BRIDGING -> ON_HYPERCORE -> FILLED -> SETTLED
     *      Alternative paths:
     *      - PENDING -> CANCELLED (user cancel)
     *      - TRIGGERED -> CANCELLED (user refund, tokens on EVM)
     *      - ON_HYPERCORE -> CANCEL_REQUESTED -> CANCELLED (two-step cancellation for HyperCore orders)
     *
     *      Note: BRIDGING status is needed because HyperEVM to HyperCore transfers are not immediate.
     *      Transfers finalize by the next Core block, so bridgeToHyperCore and placeOrderOnHyperCore
     *      must be called in separate transactions.
     */
    enum OrderStatus {
        NONE,              // Order doesn't exist (default value)
        PENDING,           // Order created, waiting for trigger price
        TRIGGERED,         // Trigger price hit, keeper executing withdrawal from HyperLend
        BRIDGING,          // Tokens bridged to HyperCore, waiting for next Core block to finalize
        ON_HYPERCORE,      // Order placed on HyperCore spot order book, waiting for fill
        CANCEL_REQUESTED,  // User requested cancellation, waiting for keeper to cancel on HyperCore
        FILLED,            // Order fully filled on HyperCore
        SETTLED,           // Funds returned to user
        CANCELLED          // Order cancelled by user
    }

    /**
     * @notice Time-in-force options for HyperCore orders
     * @dev These correspond to HyperCore's TIF values:
     *      ALO (1) - Add Liquidity Only: Order only executes as maker
     *      GTC (2) - Good Till Cancel: Order remains until filled or cancelled
     *      IOC (3) - Immediate Or Cancel: Fill immediately or cancel unfilled portion
     */
    enum TimeInForce {
        ALO,    // Add Liquidity Only (1)
        GTC,    // Good Till Cancel (2)
        IOC     // Immediate Or Cancel (3)
    }

    // ============ Structs ============

    /// @notice SpotInfo struct from HyperCore Spot Info Precompile
    /// @dev tokens[0] = base token index, tokens[1] = quote token index
    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    /// @notice TokenInfo struct from HyperCore Token Info Precompile
    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    /**
     * @notice Order data containing user-defined parameters
     * @dev These values are set at order creation and remain immutable
     * @param user The address that created the order (order owner)
     * @param aToken The HyperLend aToken to withdraw from
     * @param underlyingToken The underlying token of the aToken (e.g., WHYPE for aWHYPE, USDC for aUSDC).
     *                        For sell orders: this is the spot pair's base token being sold.
     *                        For buy orders: this is the spot pair's quote token being spent.
     * @param amount The amount of aTokens to use for the order
     * @param triggerPrice The price at which keepers should trigger the order (10^8 precision)
     * @param limitPrice The limit price for the HyperCore order (10^8 precision)
     * @param hyperCoreSpotPairId The spot pair ID on HyperCore (10000 + spot_pair_index)
     * @param isBuy True for buy orders, false for sell orders
     * @param tif Time-in-force option for the HyperCore order
     * @param reduceOnly If true, order can only reduce an existing position
     */
    struct OrderData {
        address user;
        address aToken;
        address underlyingToken;
        uint256 amount;
        uint64 triggerPrice;
        uint64 limitPrice;
        uint32 hyperCoreSpotPairId;
        bool isBuy;
        TimeInForce tif;
        bool reduceOnly;
    }

    /**
     * @notice Order state containing execution status and metadata
     * @dev These values are updated as the order progresses through its lifecycle
     * @param status The current status of the order
     * @param hyperCoreOrderId The order ID assigned by HyperCore (set after placement)
     * @param cloid Client order ID used for tracking on HyperCore
     * @param createdAt Timestamp when the order was created
     * @param triggeredAt Timestamp when the order was triggered by a keeper
     * @param filledBaseAmount Total base token amount filled so far (e.g., HYPE sold/bought)
     * @param filledQuoteAmount Total quote token amount filled so far (e.g., USDC received/spent)
     * @param placedBaseAmount For buy orders: the calculated base token amount to buy (quoteAmount / limitPrice).
     *                         For sell orders: same as data.amount. Used to determine when order is fully filled.
     */
    struct OrderState {
        OrderStatus status;
        uint64 hyperCoreOrderId;
        uint128 cloid;
        uint256 createdAt;
        uint256 triggeredAt;
        uint256 filledBaseAmount;
        uint256 filledQuoteAmount;
        uint256 placedBaseAmount;
    }

    /**
     * @notice Full limit order structure combining data and state
     * @dev Used for returning complete order information in view functions
     * @param data The user-defined order parameters
     * @param state The current execution state
     */
    struct LimitOrder {
        OrderData data;
        OrderState state;
    }

    /**
     * @notice Parameters required to create a new limit order
     * @param aToken The HyperLend aToken address to use as collateral
     * @param amount The amount of aTokens to use
     * @param triggerPrice The price at which to trigger the order (10^8 precision)
     * @param limitPrice The limit price for the HyperCore order (10^8 precision)
     * @param hyperCoreSpotPairId The spot pair ID on HyperCore (10000 + spot_pair_index)
     * @param isBuy True for buy order, false for sell order
     * @param tif Time-in-force option (ALO, GTC, or IOC)
     * @param reduceOnly If true, order can only reduce existing position
     */
    struct CreateOrderParams {
        address aToken;
        uint256 amount;
        uint64 triggerPrice;
        uint64 limitPrice;
        uint32 hyperCoreSpotPairId;
        bool isBuy;
        TimeInForce tif;
        bool reduceOnly;
    }

    /**
     * @notice EIP-2612 permit signature data for gasless approvals
     * @param amount The amount to approve
     * @param deadline The deadline timestamp for the permit
     * @param v The recovery byte of the signature
     * @param r The first 32 bytes of the signature
     * @param s The second 32 bytes of the signature
     */
    struct PermitSignature {
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // ============ Events ============

    /**
     * @notice Emitted when a keeper's authorization status is updated
     * @param keeper The keeper address
     * @param authorized True if authorized, false if revoked
     */
    event KeeperUpdated(address indexed keeper, bool authorized);

    /**
     * @notice Emitted when a new limit order is created
     * @param orderId The unique identifier for the order
     * @param user The address that created the order
     * @param aToken The aToken used as collateral
     * @param amount The amount of aTokens
     * @param triggerPrice The price at which to trigger the order
     * @param limitPrice The limit price for HyperCore
     * @param hyperCoreSpotPairId The HyperCore spot pair ID
     * @param isBuy True for buy, false for sell
     */
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        address aToken,
        uint256 amount,
        uint64 triggerPrice,
        uint64 limitPrice,
        uint32 hyperCoreSpotPairId,
        bool isBuy
    );

    /**
     * @notice Emitted when a keeper triggers an order
     * @param orderId The order ID that was triggered
     * @param keeper The keeper address that triggered the order
     * @param withdrawnAmount The amount of underlying tokens withdrawn from HyperLend
     */
    event OrderTriggered(
        uint256 indexed orderId,
        address indexed keeper,
        uint256 withdrawnAmount
    );

    /**
     * @notice Emitted when tokens are bridged from EVM to HyperCore
     * @param orderId The order ID
     * @param executor The address that executed the bridge (keeper or owner)
     * @param token The token address that was bridged
     * @param amount The amount bridged (in EVM decimals)
     */
    event TokensBridgedToHyperCore(
        uint256 indexed orderId,
        address indexed executor,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when an order is placed on HyperCore's spot order book
     * @param orderId The order ID
     * @param executor The address that placed the order (keeper or owner)
     * @param cloid The client order ID used for tracking on HyperCore
     * @param spotPairId The spot pair ID (10000 + spot_pair_index)
     */
    event OrderPlacedOnHyperCore(
        uint256 indexed orderId,
        address indexed executor,
        uint128 cloid,
        uint32 spotPairId
    );

    /**
     * @notice Emitted when an order is filled (can be partial)
     * @param orderId The order ID
     * @param executor The address that reported the fill (keeper)
     * @param baseAmountFilled The base token amount filled in this fill event
     * @param quoteAmountReceived The quote token amount received in this fill event
     * @param totalBaseFilled The cumulative total base token amount filled
     * @param totalQuoteReceived The cumulative total quote token amount received
     */
    event OrderFilled(
        uint256 indexed orderId,
        address indexed executor,
        uint256 baseAmountFilled,
        uint256 quoteAmountReceived,
        uint256 totalBaseFilled,
        uint256 totalQuoteReceived
    );

    /**
     * @notice Emitted when an order is settled and funds transferred to user
     * @param orderId The order ID
     * @param executor The address that settled the order (keeper or owner)
     * @param user The user receiving the funds
     * @param amount The amount of tokens transferred
     */
    event OrderSettled(
        uint256 indexed orderId,
        address indexed executor,
        address user,
        uint256 amount
    );

    /**
     * @notice Emitted when an order is cancelled
     * @param orderId The order ID
     * @param user The user who cancelled the order
     */
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed user
    );

    /**
     * @notice Emitted when a user requests cancellation of an ON_HYPERCORE order
     * @param orderId The order ID
     * @param user The user who requested cancellation
     */
    event CancellationRequested(
        uint256 indexed orderId,
        address indexed user
    );

    /**
     * @notice Emitted when keeper cancels an order on HyperCore
     * @param orderId The order ID
     * @param keeper The keeper who cancelled on HyperCore
     * @param cloid The client order ID that was cancelled
     */
    event OrderCancelledOnHyperCore(
        uint256 indexed orderId,
        address indexed keeper,
        uint128 cloid
    );

    // ============ User Functions ============

    /**
     * @notice Create a new limit order using aToken collateral
     * @dev User must have approved this contract to spend their aTokens before calling.
     * The aTokens remain in the user's wallet until a keeper triggers the order.
     * @param params The order creation parameters
     * @return orderId The unique identifier for the created order
     */
    function createOrder(CreateOrderParams calldata params) external returns (uint256 orderId);

    /**
     * @notice Create a new limit order using EIP-2612 permit for gasless approval
     * @dev Combines approval and order creation in a single transaction
     * @param params The order creation parameters
     * @param permit The permit signature data for aToken approval
     * @return orderId The unique identifier for the created order
     */
    function createOrderWithPermit(
        CreateOrderParams calldata params,
        PermitSignature calldata permit
    ) external returns (uint256 orderId);

    /**
     * @notice Cancel a pending order
     * @dev Only callable by the order owner. Only PENDING orders can be cancelled.
     * No token transfer occurs since aTokens haven't been moved yet.
     * @param orderId The order ID to cancel
     */
    function cancelOrder(uint256 orderId) external;

    /**
     * @notice Request a refund for a triggered but unfilled order
     * @dev Only callable by the order owner. Only TRIGGERED, BRIDGING, or ON_HYPERCORE orders can be refunded.
     * Returns the underlying tokens (already withdrawn from HyperLend) to the user.
     * @param orderId The order ID to refund
     */
    function userRefund(uint256 orderId) external;

    // ============ Keeper Functions ============

    /**
     * @notice Execute a pending order when trigger price is reached
     * @dev Only callable by authorized keepers or the order owner. Withdraws underlying from HyperLend.
     * @param orderId The order ID to execute
     */
    function executeOrder(uint256 orderId) external;

    /**
     * @notice Bridge tokens from EVM to HyperCore spot balance
     * @dev Only callable by authorized keepers or the order owner. Must be called after executeOrder.
     *      Due to HyperEVM timing, the tokens won't be available on HyperCore until
     *      the next Core block, so placeOrderOnHyperCore must be called in a separate transaction.
     * @param orderId The order ID to bridge tokens for
     */
    function bridgeToHyperCore(uint256 orderId) external;

    /**
     * @notice Place a bridged order on HyperCore's spot order book
     * @dev Only callable by authorized keepers or the order owner. Must be called after bridgeToHyperCore
     *      and after waiting for the next Core block to ensure tokens are available.
     *      The base token index is derived from the spot pair ID stored in the order.
     * @param orderId The order ID to place on HyperCore
     * @param cloid Client order ID for tracking the order on HyperCore
     */
    function placeOrderOnHyperCore(uint256 orderId, uint128 cloid) external;

    /**
     * @notice Report a fill from HyperCore
     * @dev Only callable by authorized keepers (not order owner). Can be called multiple times for partial fills.
     *      This is keeper-only to prevent users from reporting fake fills and draining contract funds.
     *      Order status changes to FILLED only when fully filled (filledBaseAmount >= order amount).
     * @param orderId The order ID that was filled
     * @param baseAmountFilled The base token amount filled in this event (in base token decimals, e.g., 18 for HYPE)
     * @param quoteAmountReceived The quote token amount received in this event (in quote token decimals, e.g., 6 for USDC)
     */
    function reportFill(uint256 orderId, uint256 baseAmountFilled, uint256 quoteAmountReceived) external;

    /**
     * @notice Settle a filled order and transfer funds to the user on HyperCore
     * @dev Only callable by authorized keepers or the order owner.
     *      - For sell orders: sends quote tokens (e.g., USDC when selling HYPE)
     *      - For buy orders: sends base tokens (e.g., HYPE when buying HYPE with USDC)
     * @param orderId The order ID to settle
     */
    function settleOrder(uint256 orderId) external;

    /**
     * @notice Cancel an order in BRIDGING status
     * @dev Only callable by the order owner. Tokens have been bridged to HyperCore but order
     *      hasn't been placed yet. Sends base tokens back to user on HyperCore.
     *      Must wait for next Core block after bridgeToHyperCore before calling.
     * @param orderId The order ID to cancel
     */
    function cancelBridging(uint256 orderId) external;

    /**
     * @notice Cancel an order on HyperCore (step 1 of 2)
     * @dev Only callable by the order owner. Cancels the order on HyperCore using the cloid.
     *      Sets status to CANCEL_REQUESTED. After calling this, wait for the next Core block,
     *      then call completeCancellation to receive tokens.
     * @param orderId The order ID to cancel on HyperCore
     */
    function cancelOrderOnHyperCore(uint256 orderId) external;

    /**
     * @notice Complete cancellation and receive tokens (step 2 of 2)
     * @dev Only callable by the order owner or keeper. Sends tokens back to user on HyperCore:
     *      - For sell orders: filled quote tokens + unfilled base tokens
     *      - For buy orders: filled base tokens + unfilled quote tokens
     *      Must be called after cancelOrderOnHyperCore and waiting for next Core block.
     * @param orderId The order ID to complete cancellation for
     */
    function completeCancellation(uint256 orderId) external;

    // ============ View Functions ============

    /**
     * @notice Get complete order information
     * @param orderId The order ID to query
     * @return The full LimitOrder struct containing data and state
     */
    function getOrder(uint256 orderId) external view returns (LimitOrder memory);

    /**
     * @notice Get only the order data (user-defined parameters)
     * @dev More gas efficient than getOrder() when only data is needed
     * @param orderId The order ID to query
     * @return The OrderData struct
     */
    function getOrderData(uint256 orderId) external view returns (OrderData memory);

    /**
     * @notice Get only the order state (execution status and metadata)
     * @dev More gas efficient than getOrder() when only state is needed
     * @param orderId The order ID to query
     * @return The OrderState struct
     */
    function getOrderState(uint256 orderId) external view returns (OrderState memory);

    /**
     * @notice Get all order IDs created by a user
     * @param user The user address to query
     * @return Array of order IDs belonging to the user
     */
    function getUserOrders(address user) external view returns (uint256[] memory);

    /**
     * @notice Get the total number of orders created
     * @return The order counter (also the last order ID)
     */
    function getOrderCount() external view returns (uint256);

    /**
     * @notice Get the contract's HyperCore spot balance for a given token
     * @dev Useful for keepers to verify the actual balance before calling reportFill.
     *      The balance returned is in HyperCore wei (8 decimals).
     *      For USDC: divide by 10^8 to get USDC amount
     *      For HYPE: divide by 10^8 to get HYPE amount
     * @param tokenIndex The HyperCore token index (0 for USDC, 150 for HYPE, etc.)
     * @return total The total balance available
     * @return hold The amount on hold (in open orders)
     */
    function getHyperCoreBalance(uint64 tokenIndex) external view returns (uint64 total, uint64 hold);
}


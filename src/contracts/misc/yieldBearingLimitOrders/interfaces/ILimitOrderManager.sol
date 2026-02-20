// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title ILimitOrderManager
 * @author HyperLend
 * @notice Interface for the HyperLend Limit Order Manager
 * @dev Manages limit orders that integrate HyperLend deposits with Hyperliquid's HyperCore spot trading.
 *
 **/
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

    /// @notice Thrown when withdrawal amount doesn't match expected amount
    error WithdrawalAmountMismatch();

    /// @notice Thrown when HyperCore token is not configured for the asset ID
    error TokenNotConfigured();

    /// @notice Thrown when the contract doesn't have enough balance on HyperCore to settle
    error InsufficientHyperCoreBalance();

    /// @notice Thrown when order is already finalized (SETTLED or CANCELLED)
    error OrderAlreadyFinalized();

    /// @notice Thrown when refund is not allowed in the current order status
    error CannotRefundInCurrentStatus();

    /// @notice Thrown when order is not on HyperCore for cancellation
    error OrderNotOnHyperCoreForCancellation();

    /// @notice Thrown when order is not in CANCEL_REQUESTED status
    error OrderNotCancelRequested();

    /// @notice Thrown when order is not in FAILED_ON_HYPERCORE status
    error OrderNotFailedOnHyperCore();

    /// @notice Thrown when order is not in FAILED_ON_EVM status
    error OrderNotFailedOnEvm();

    /// @notice Thrown when spot pair ID is invalid (must be >= 10000)
    error InvalidSpotPairId();

    /// @notice Thrown when limit price is zero
    error InvalidLimitPrice();

    /// @notice Thrown when order has expired
    error OrderExpired();

    /// @notice Thrown when keeper address is zero
    error ZeroKeeperAddress();

    /// @notice Thrown when order does not exist
    error OrderDoesNotExist();

    /// @notice Thrown when contract has insufficient WHYPE balance for unwrap
    error InsufficientWHYPEBalance();

    /// @notice Thrown when native HYPE transfer fails
    error NativeHypeTransferFailed();

    /// @notice Thrown when address is zero
    error ZeroAddress();

    // ============ Enums ============

    /**
     * @notice Represents the current status of a limit order
     * @dev Status transitions: NONE -> PENDING -> TRIGGERED -> BRIDGING -> ON_HYPERCORE -> FILLED -> SETTLED
     *      Alternative paths:
     *      - PENDING -> CANCELLED (user cancel)
     *      - TRIGGERED -> CANCELLED (user refund, tokens on EVM)
     *      - ON_HYPERCORE -> CANCEL_REQUESTED -> CANCELLED (two-step cancellation for HyperCore orders)
     *      - Any status -> FAILED_ON_EVM or FAILED_ON_HYPERCORE (keeper sets error status when something fails)
     *
     *      Note: BRIDGING status is needed because HyperEVM to HyperCore transfers are not immediate.
     *      Transfers finalize by the next Core block, so bridgeToHyperCore and placeOrderOnHyperCore
     *      must be called in separate transactions.
     *
     *      Error Statuses:
     *      - FAILED_ON_EVM: Order failed and funds are still on EVM (use recoverFromFailedOnEvm)
     *      - FAILED_ON_HYPERCORE: Order failed and funds are on HyperCore (use recoverFromFailedOnHyperCore)
     */
    enum OrderStatus {
        // ============ Normal Lifecycle Statuses ============
        NONE,              // Order doesn't exist (default value)
        PENDING,           // Order created, waiting for trigger price
        TRIGGERED,         // Trigger price hit, keeper executing withdrawal from HyperLend
        BRIDGING,          // Tokens bridged to HyperCore, waiting for next Core block to finalize
        ON_HYPERCORE,      // Order placed on HyperCore spot order book, waiting for fill
        CANCEL_REQUESTED,  // User requested cancellation, waiting for keeper to cancel on HyperCore
        FILLED,            // Order fully filled on HyperCore
        SETTLED,           // Funds returned to user
        CANCELLED,         // Order cancelled by user

        // ============ Error Statuses ============
        /// @dev Order failed and funds are still on EVM - use recoverFromFailedOnEvm()
        FAILED_ON_EVM,
        /// @dev Order failed and funds are on HyperCore - use recoverFromFailedOnHyperCore()
        FAILED_ON_HYPERCORE
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
     * @dev These values are set at order creation and remain immutable.
     * @param user The address that created the order (order owner)
     * @param triggerPrice The price at which keepers should trigger the order (10^8 precision)
     * @param hyperCoreSpotPairId The spot pair ID on HyperCore (10000 + spot_pair_index)
     * @param aToken The HyperLend aToken to withdraw from
     * @param limitPrice The limit price for the HyperCore order (10^8 precision)
     * @param isBuy True for buy orders, false for sell orders
     * @param tif Time-in-force option for the HyperCore order
     * @param reduceOnly If true, order can only reduce an existing position
     * @param underlyingToken The underlying token of the aToken (e.g., WHYPE for aWHYPE, USDC for aUSDC).
     *                        For sell orders: this is the spot pair's base token being sold.
     *                        For buy orders: this is the spot pair's quote token being spent.
     * @param amount The amount of aTokens to use for the order
     * @param expiresAt Unix timestamp when the order expires (0 for no expiration)
     */
    struct OrderData {
        address user;
        uint64 triggerPrice;
        uint32 hyperCoreSpotPairId;
        address aToken;
        uint64 limitPrice;
        bool isBuy;
        TimeInForce tif;
        bool reduceOnly;
        address underlyingToken;
        uint256 amount;
        uint256 expiresAt;
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
     * @param expiresAt Unix timestamp when the order expires (0 for no expiration)
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
        uint256 expiresAt;
    }

    /**
     * @notice Parameters for placing an order on HyperCore in batch operations
     * @param orderId The order ID to place on HyperCore
     * @param cloid Client order ID for tracking the order on HyperCore
     */
    struct PlaceOrderOnHyperCoreParams {
        uint256 orderId;
        uint128 cloid;
    }

    /**
     * @notice Parameters for reporting a fill in batch operations
     * @param orderId The order ID that was filled
     * @param baseAmountFilled The base token amount filled in this event
     * @param quoteAmountReceived The quote token amount received in this event
     */
    struct ReportFillParams {
        uint256 orderId;
        uint256 baseAmountFilled;
        uint256 quoteAmountReceived;
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
     * @param tif Time in force for the order
     * @param reduceOnly Whether the order is reduce-only
     * @param expiresAt Unix timestamp when the order expires (0 for no expiration)
     */
    event OrderCreated(
        uint256 indexed orderId,
        address indexed user,
        address aToken,
        uint256 amount,
        uint64 triggerPrice,
        uint64 limitPrice,
        uint32 hyperCoreSpotPairId,
        bool isBuy,
        TimeInForce tif,
        bool reduceOnly,
        uint256 expiresAt
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
     * @notice Emitted when user cancels an order on HyperCore (first step of two-step refund)
     * @param orderId The order ID
     * @param user The user who cancelled on HyperCore
     * @param cloid The client order ID that was cancelled
     */
    event OrderCancelledOnHyperCore(
        uint256 indexed orderId,
        address indexed user,
        uint128 cloid
    );

    /**
     * @notice Emitted when a keeper changes an order's status
     * @param orderId The order ID
     * @param keeper The keeper who changed the status
     * @param oldStatus The previous status
     * @param newStatus The new status
     */
    event OrderStatusChanged(
        uint256 indexed orderId,
        address indexed keeper,
        OrderStatus oldStatus,
        OrderStatus newStatus
    );

    /**
     * @notice Emitted when native HYPE is received (from WHYPE unwrap)
     * @param sender The address that sent the native HYPE
     * @param amount The amount of native HYPE received
     */
    event NativeHypeReceived(address indexed sender, uint256 amount);

    /**
     * @notice Emitted when ERC20 tokens are recovered from the contract
     * @param token The token address that was recovered
     * @param to The address that received the tokens
     * @param amount The amount of tokens recovered
     */
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when native HYPE is recovered from the contract
     * @param to The address that received the native HYPE
     * @param amount The amount of native HYPE recovered
     */
    event NativeHypeRecovered(address indexed to, uint256 amount);

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
     * @notice Cancel a PENDING order
     * @dev Only callable by the order owner. Since aTokens are only transferred when the order
     * is triggered, no token transfer is needed for cancellation of pending orders.
     * @param orderId The order ID to cancel
     */
    function cancelPendingOrder(uint256 orderId) external;

    /**
     * @notice Cancel a TRIGGERED order and return tokens on EVM
     * @dev Only callable by the order owner. Returns underlying tokens that were withdrawn
     * from HyperLend but not yet bridged to HyperCore.
     * @param orderId The order ID to cancel
     */
    function cancelTriggeredOrder(uint256 orderId) external;

    /**
     * @notice Cancel a BRIDGING order and return tokens on HyperCore
     * @dev Only callable by the order owner. Tokens have been bridged to HyperCore but
     * the order hasn't been placed yet. Sends tokens back to user on HyperCore.
     * Must wait for the next Core block after bridgeToHyperCore before calling.
     * @param orderId The order ID to cancel
     */
    function cancelBridgedOrder(uint256 orderId) external;

    /**
     * @notice Request cancellation of an ON_HYPERCORE order (first step of two-step cancellation)
     * @dev Only callable by the order owner. Cancels the order on HyperCore and sets
     * status to CANCEL_REQUESTED. Must call finalizeCancellation() after next Core block.
     * @param orderId The order ID to cancel
     */
    function requestCancellation(uint256 orderId) external;

    /**
     * @notice Finalize cancellation and return tokens on HyperCore (second step)
     * @dev Callable by the order owner or authorized keepers. Sends filled tokens and
     * unfilled tokens back to user on HyperCore.
     * Must be called after requestCancellation and waiting for the next Core block.
     * @param orderId The order ID to finalize cancellation for
     */
    function finalizeCancellation(uint256 orderId) external;

    /**
     * @notice Recover funds from an order in FAILED_ON_HYPERCORE status
     * @dev Only callable by the order owner. Sends tokens back to user on HyperCore.
     * Use this when order failed and funds are on HyperCore.
     * @param orderId The order ID to recover funds from
     */
    function recoverFromFailedOnHyperCore(uint256 orderId) external;

    /**
     * @notice Recover funds from FAILED_ON_EVM status when tokens are still on EVM
     * @dev Only callable by the order owner. Returns underlying tokens on EVM.
     * Use this when order failed and tokens never reached HyperCore.
     * @param orderId The order ID to recover funds from
     */
    function recoverFromFailedOnEvm(uint256 orderId) external;

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
     * @notice Change the status of an order
     * @dev Only callable by authorized keepers. Use with caution - this bypasses normal state transitions.
     *      Intended for emergency recovery or correcting order states that got stuck.
     * @param orderId The order ID to update
     * @param newStatus The new status to set
     */
    function setOrderStatus(uint256 orderId, OrderStatus newStatus) external;

    // ============ Admin Functions ============

    /**
     * @notice Pause the contract
     * @dev Only callable by the contract owner. When paused, order creation and execution are disabled.
     *      Cancellation functions remain available so users can recover their funds.
     */
    function pause() external;

    /**
     * @notice Unpause the contract
     * @dev Only callable by the contract owner.
     */
    function unpause() external;
}


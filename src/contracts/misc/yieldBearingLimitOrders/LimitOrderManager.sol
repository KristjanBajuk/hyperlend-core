// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Ownable} from '../../dependencies/openzeppelin/contracts/Ownable.sol';
import {ReentrancyGuard} from '../../dependencies/openzeppelin/ReentrancyGuard.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IAToken} from '../../interfaces/IAToken.sol';
import {IERC20WithPermit} from '../../interfaces/IERC20WithPermit.sol';
import {ILimitOrderManager} from './interfaces/ILimitOrderManager.sol';
import {CoreWriterLib} from './libraries/CoreWriterLib.sol';
import {PrecompileLib} from '@hyper-evm-lib/PrecompileLib.sol';

/// @notice Interface for Wrapped HYPE (WHYPE) token
interface IWHYPE {
    function withdraw(uint256 value) external;
}

/**
 * @title LimitOrderManager
 * @author HyperLend
 * @notice Manages limit orders that integrate HyperLend deposits with Hyperliquid's HyperCore spot trading
 * @dev This contract allows users to create limit orders using their aToken collateral from HyperLend.
 *
 * Use Case Example:
 * - User has aWHYPE earning yield in HyperLend
 * - User creates a limit order: "Sell my HYPE when price reaches $20"
 * - When HYPE hits $20, keeper triggers the order:
 *   1. Withdraws WHYPE from HyperLend
 *   2. Bridges WHYPE to HyperCore spot balance
 *   3. Places a spot limit order to sell HYPE for USDC
 * - When order fills, keeper settles USDC back to user
 *
 * Spot Pair ID Format:
 * - hyperCoreSpotPairId = 10000 + spot_pair_index
 * - Example: HYPE/USDC pair index is 107, so use 10107
 *
 * Order lifecycle: PENDING -> TRIGGERED -> BRIDGING -> ON_HYPERCORE -> FILLED -> SETTLED
 * Note: BRIDGING and ON_HYPERCORE are separate steps because HyperEVM to HyperCore transfers
 * are not immediately available - they finalize by the next Core block.
 * Users can cancel PENDING orders or request refunds for TRIGGERED/BRIDGING/ON_HYPERCORE orders.
 */
contract LimitOrderManager is ILimitOrderManager, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice HyperCore Spot Info Precompile address for querying spot pair data
    address constant SPOT_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080b;

    /// @notice HyperCore Token Info Precompile address for querying token decimals
    address constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;

    /// @notice Wrapped HYPE (WHYPE) contract address - used by HyperLend for HYPE
    address constant WHYPE = 0x5555555555555555555555555555555555555555;

    /// @notice HYPE token index on HyperCore mainnet
    uint64 constant HYPE_TOKEN_INDEX = 150;

    /// @notice HYPE has 10 extra decimals on EVM (18 EVM decimals - 8 HyperCore wei decimals)
    uint8 constant HYPE_EVM_EXTRA_DECIMALS = 10;

    /// @notice Price precision for HyperCore (10^8)
    uint256 constant PRICE_PRECISION = 1e8;

    // ============ Immutables ============

    /// @notice The HyperLend Pool Addresses Provider contract
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /// @notice The HyperLend Pool contract for deposits and withdrawals
    IPool public immutable POOL;

    // ============ State Variables ============

    /// @notice Counter for generating unique order IDs
    uint256 public orderCounter;

    /// @notice Mapping from order ID to order data (user-defined parameters)
    mapping(uint256 => OrderData) public orderData;

    /// @notice Mapping from order ID to order state (execution status and metadata)
    mapping(uint256 => OrderState) public orderStates;

    /// @notice Mapping from user address to array of their order IDs
    mapping(address => uint256[]) public userOrderIds;

    /// @notice Mapping from keeper address to their authorization status
    mapping(address => bool) public authorizedKeepers;

    // ============ Modifiers ============

    /**
     * @notice Restricts function access to authorized keepers only
     * @dev Reverts if msg.sender is not an authorized keeper
     */
    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    /**
     * @notice Restricts function access to the order owner or authorized keepers
     * @dev Reverts if msg.sender is neither the order owner nor an authorized keeper
     * @param orderId The order ID to check ownership for
     */
    modifier onlyKeeperOrOwner(uint256 orderId) {
        _checkKeeperOrOwner(orderId);
        _;
    }

    function _checkKeeper() internal view {
        if (!authorizedKeepers[msg.sender]) {
            revert NotAuthorizedKeeper();
        }
    }

    function _checkKeeperOrOwner(uint256 orderId) internal view {
        if (!authorizedKeepers[msg.sender] && orderData[orderId].user != msg.sender) {
            revert NotAuthorizedKeeperOrOwner();
        }
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the LimitOrderManager contract
     * @param provider The HyperLend Pool Addresses Provider contract
     */
    constructor(IPoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
        POOL = IPool(provider.getPool());
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize or revoke a keeper address
     * @dev Only callable by the contract owner. Keepers are trusted addresses that can
     * execute orders, place them on HyperCore, report fills, and settle orders.
     * @param keeper The address to authorize or revoke
     * @param authorized True to authorize, false to revoke
     */
    function setKeeper(address keeper, bool authorized) external onlyOwner {
        authorizedKeepers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    // ============ User Functions ============

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Creates a new limit order. The user must have approved this contract to spend
     * their aTokens before calling. The aTokens remain in the user's wallet until a keeper
     * triggers the order.
     */
    function createOrder(CreateOrderParams calldata params) external override nonReentrant returns (uint256 orderId) {
        return _createOrder(params);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Creates a new limit order using EIP-2612 permit for gasless approval.
     * The permit signature authorizes this contract to spend the user's aTokens.
     */
    function createOrderWithPermit(
        CreateOrderParams calldata params,
        PermitSignature calldata permit
    ) external override nonReentrant returns (uint256 orderId) {
        // Execute permit on aToken to set allowance
        IERC20WithPermit(params.aToken).permit(
            msg.sender,
            address(this),
            permit.amount,
            permit.deadline,
            permit.v,
            permit.r,
            permit.s
        );
        return _createOrder(params);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Cancels a pending order. Only the order owner can cancel.
     * Since aTokens are only transferred when the order is triggered,
     * no token transfer is needed for cancellation of pending orders.
     */
    function cancelOrder(uint256 orderId) external override nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.PENDING) revert OrderNotPending();

        state.status = OrderStatus.CANCELLED;

        // No token transfer needed - aTokens are still in user's wallet (approve-only pattern)

        emit OrderCancelled(orderId, msg.sender);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Allows the order owner to request a refund for orders that have been triggered
     * but not yet bridged to HyperCore. The underlying tokens (already withdrawn from HyperLend)
     * are returned to the user on EVM.
     *
     * Note: For orders that are ON_HYPERCORE, use cancelOrderOnHyperCore() and completeCancellation() instead.
     */
    function userRefund(uint256 orderId) external override nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (data.user != msg.sender) revert NotOrderOwner();
        // Only allow refund for TRIGGERED status (tokens are still on EVM)
        // For ON_HYPERCORE, tokens are on HyperCore - use cancelOrderOnHyperCore instead
        if (state.status != OrderStatus.TRIGGERED) {
            revert CannotRefundInCurrentStatus();
        }

        state.status = OrderStatus.CANCELLED;

        // Transfer underlying tokens back to user (already withdrawn from pool)
        IERC20(data.underlyingToken).safeTransfer(msg.sender, data.amount);

        emit OrderCancelled(orderId, msg.sender);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Allows the order owner to cancel an order that is in BRIDGING status.
     * Tokens have been bridged to HyperCore but the order hasn't been placed yet.
     * This sends the base tokens back to the user on HyperCore.
     *
     * Note: Must wait for the next Core block after bridgeToHyperCore before calling this.
     */
    function cancelBridging(uint256 orderId) external override nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.BRIDGING) {
            revert OrderNotBridging();
        }

        state.status = OrderStatus.CANCELLED;

        // Get the token index based on order type and send tokens back to user on HyperCore
        // Sell order: user bridged spot base tokens (e.g., HYPE)
        // Buy order: user bridged spot quote tokens (e.g., USDC)
        uint64 tokenIndex = data.isBuy
            ? _getSpotQuoteTokenIndex(data.hyperCoreSpotPairId)
            : _getSpotBaseTokenIndex(data.hyperCoreSpotPairId);
        uint64 weiAmount = CoreWriterLib.evmToWei(tokenIndex, data.amount);
        CoreWriterLib.spotSend(data.user, tokenIndex, weiAmount);

        emit OrderCancelled(orderId, data.user);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Allows the order owner to cancel an order on HyperCore.
     * This is the first step of the two-step cancellation process:
     * 1. User calls cancelOrderOnHyperCore() - cancels order on HyperCore, sets status to CANCEL_REQUESTED
     * 2. [Wait for next Core block]
     * 3. User calls completeCancellation() - receives filled quote tokens and unfilled base tokens
     */
    function cancelOrderOnHyperCore(uint256 orderId) external override nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.ON_HYPERCORE) {
            revert OrderNotOnHyperCoreForCancellation();
        }

        state.status = OrderStatus.CANCEL_REQUESTED;

        // Cancel the order on HyperCore using cloid
        CoreWriterLib.cancelOrderByCloid(data.hyperCoreSpotPairId, state.cloid);

        emit OrderCancelledOnHyperCore(orderId, msg.sender, state.cloid);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Allows the order owner to complete cancellation after the order is cancelled on HyperCore.
     * For sell orders:
     *   - Sends filled quote tokens (what user received from partial fills)
     *   - Sends unfilled base tokens back (what wasn't sold)
     * For buy orders:
     *   - Sends filled base tokens (what user received from partial fills)
     *   - Sends unfilled quote tokens back (what wasn't spent)
     *
     * Note: Must be called after cancelOrderOnHyperCore and waiting for the next Core block.
     */
    function completeCancellation(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.CANCEL_REQUESTED) {
            revert OrderNotCancelRequested();
        }

        state.status = OrderStatus.CANCELLED;

        // Get spot pair token indices
        uint64 spotBaseTokenIndex = _getSpotBaseTokenIndex(data.hyperCoreSpotPairId);
        uint64 spotQuoteTokenIndex = _getSpotQuoteTokenIndex(data.hyperCoreSpotPairId);

        if (data.isBuy) {
            // Buy order: user placed spot quote tokens to buy spot base tokens
            // Send filled spot base tokens to user (what they bought)
            if (state.filledBaseAmount > 0) {
                uint64 spotBaseWeiAmount = CoreWriterLib.evmToWei(spotBaseTokenIndex, state.filledBaseAmount);
                CoreWriterLib.spotSend(data.user, spotBaseTokenIndex, spotBaseWeiAmount);
            }

            // Send unfilled spot quote tokens back to user (what wasn't spent)
            // For buy orders, data.amount is the spot quote token amount placed
            uint256 unfilledQuoteAmount = data.amount - state.filledQuoteAmount;
            if (unfilledQuoteAmount > 0) {
                uint64 spotQuoteWeiAmount = CoreWriterLib.evmToWei(spotQuoteTokenIndex, unfilledQuoteAmount);
                CoreWriterLib.spotSend(data.user, spotQuoteTokenIndex, spotQuoteWeiAmount);
            }
        } else {
            // Sell order: user placed spot base tokens to sell for spot quote tokens
            // Send filled spot quote tokens to user (what they received)
            if (state.filledQuoteAmount > 0) {
                uint64 spotQuoteWeiAmount = CoreWriterLib.evmToWei(spotQuoteTokenIndex, state.filledQuoteAmount);
                CoreWriterLib.spotSend(data.user, spotQuoteTokenIndex, spotQuoteWeiAmount);
            }

            // Send unfilled spot base tokens back to user (what wasn't sold)
            uint256 unfilledBaseAmount = data.amount - state.filledBaseAmount;
            if (unfilledBaseAmount > 0) {
                uint64 spotBaseWeiAmount = CoreWriterLib.evmToWei(spotBaseTokenIndex, unfilledBaseAmount);
                CoreWriterLib.spotSend(data.user, spotBaseTokenIndex, spotBaseWeiAmount);
            }
        }

        emit OrderCancelled(orderId, data.user);
    }

    // ============ Keeper/Owner Functions ============

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Called by keepers or the order owner when the trigger price condition is met.
     * This function:
     * 1. Transfers aTokens from the user to this contract
     * 2. Withdraws the underlying asset from HyperLend Pool
     * 3. Updates the order status to TRIGGERED
     * The caller should then call bridgeToHyperCore to bridge tokens to HyperCore.
     */
    function executeOrder(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.PENDING) revert OrderNotPending();

        state.status = OrderStatus.TRIGGERED;
        state.triggeredAt = block.timestamp;

        // Transfer aTokens from user to this contract
        IERC20(data.aToken).safeTransferFrom(data.user, address(this), data.amount);

        // Withdraw underlying token from Pool
        uint256 withdrawn = POOL.withdraw(data.underlyingToken, data.amount, address(this));
        if (withdrawn != data.amount) revert WithdrawalAmountMismatch();

        emit OrderTriggered(orderId, msg.sender, withdrawn);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Called by keepers or the order owner after executeOrder. This function bridges tokens
     *      from EVM to HyperCore spot balance. Due to HyperEVM timing constraints,
     *      the tokens won't be available on HyperCore until the next Core block.
     *      The caller must wait and then call placeOrderOnHyperCore in a separate transaction.
     *
     *      For sell orders: bridges base tokens (e.g., HYPE to sell for USDC)
     *      For buy orders: bridges quote tokens (e.g., USDC to buy HYPE)
     *
     *      Note: For HYPE orders, HyperLend gives us WHYPE (ERC20 wrapper). We must unwrap it to
     *      native HYPE before bridging, since the CoreWriterLib expects native HYPE.
     */
    function bridgeToHyperCore(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.TRIGGERED) revert OrderNotTriggered();

        state.status = OrderStatus.BRIDGING;

        // Get the token index based on order type
        // Sell order: bridge spot base tokens (e.g., HYPE)
        // Buy order: bridge spot quote tokens (e.g., USDC)
        uint64 tokenIndex = data.isBuy
            ? _getSpotQuoteTokenIndex(data.hyperCoreSpotPairId)
            : _getSpotBaseTokenIndex(data.hyperCoreSpotPairId);

        // For HYPE, we need to unwrap WHYPE to native HYPE before bridging
        // HyperLend uses WHYPE (0x555...555) as the underlying for aWHYPE
        // The CoreWriterLib.bridgeToCoreByIndex expects native HYPE (sent via msg.value)
        if (tokenIndex == HYPE_TOKEN_INDEX) {
            // Unwrap WHYPE to native HYPE - this sends native HYPE to this contract (msg.sender)
            IWHYPE(WHYPE).withdraw(data.amount);
        }

        // Bridge tokens from EVM to HyperCore spot balance using token index
        CoreWriterLib.bridgeToCoreByIndex(tokenIndex, data.amount);

        emit TokensBridgedToHyperCore(orderId, msg.sender, data.underlyingToken, data.amount);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Called by keepers or the order owner after bridgeToHyperCore and after waiting for the next Core block.
     *      This function places the spot limit order on HyperCore's order book.
     *
     *      For spot trading, the hyperCoreSpotPairId should be 10000 + spot_pair_index.
     *      For example, HYPE/USDC pair index is 107, so spot pair ID should be 10107.
     *
     *      For sell orders: places order to sell base tokens for quote tokens
     *        - data.amount = base token amount to sell
     *        - sz = base token amount in wei
     *        - placedBaseAmount = data.amount
     *
     *      For buy orders: places order to buy base tokens with quote tokens
     *        - data.amount = quote token amount to spend
     *        - sz = calculated base token amount in wei (quoteAmount / limitPrice)
     *        - placedBaseAmount = calculated base token amount (for fill tracking)
     *
     *      HyperCore's sz parameter is ALWAYS in base token units, regardless of buy/sell.
     */
    function placeOrderOnHyperCore(
        uint256 orderId,
        uint128 cloid
    ) external override onlyKeeperOrOwner(orderId) nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.BRIDGING) revert OrderNotBridging();

        state.status = OrderStatus.ON_HYPERCORE;
        state.cloid = cloid;

        uint64 spotBaseTokenIndex = _getSpotBaseTokenIndex(data.hyperCoreSpotPairId);
        uint64 orderSizeWei;

        if (data.isBuy) {
            // Buy order: user wants to buy spot base tokens with spot quote tokens
            // data.amount = spot quote token amount (e.g., 100 USDC)
            // We need to calculate how much spot base token to buy at the limit price
            //
            // Formula: spotBaseAmount = spotQuoteAmount / price
            // In wei terms with price precision (10^8):
            //   spotBaseAmountWei = spotQuoteAmountWei * 10^8 / limitPrice
            //
            // But we need to account for different decimal precisions between tokens.
            // We calculate in EVM decimals first, then convert to wei.
            //
            // spotBaseAmountEvm = (spotQuoteAmountEvm * PRICE_PRECISION) / limitPrice
            // Then convert spotBaseAmountEvm to wei using spot base token's conversion
            uint256 spotBaseAmountEvm = (data.amount * PRICE_PRECISION) / data.limitPrice;

            // Store the calculated spot base amount for fill tracking (in EVM decimals)
            state.placedBaseAmount = spotBaseAmountEvm;

            // Convert to HyperCore wei for order placement
            orderSizeWei = CoreWriterLib.evmToWei(spotBaseTokenIndex, spotBaseAmountEvm);
        } else {
            // Sell order: user wants to sell spot base tokens for spot quote tokens
            // data.amount = spot base token amount to sell
            state.placedBaseAmount = data.amount;

            // Convert to HyperCore wei for order placement
            orderSizeWei = CoreWriterLib.evmToWei(spotBaseTokenIndex, data.amount);
        }

        // Encode TIF for HyperCore
        uint8 encodedTif = CoreWriterLib.encodeTif(
            data.tif == TimeInForce.ALO ? CoreWriterLib.TIF_ALO :
            data.tif == TimeInForce.GTC ? CoreWriterLib.TIF_GTC :
            CoreWriterLib.TIF_IOC
        );

        // Place spot limit order on HyperCore
        // The hyperCoreSpotPairId should already be in spot format (10000 + pair_index)
        // sz is ALWAYS in base token wei, regardless of buy/sell
        CoreWriterLib.placeLimitOrder(
            data.hyperCoreSpotPairId,
            data.isBuy,
            data.limitPrice,
            orderSizeWei,
            data.reduceOnly,
            encodedTif,
            cloid
        );

        emit OrderPlacedOnHyperCore(orderId, msg.sender, cloid, data.hyperCoreSpotPairId);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Called by keepers to report partial or full fills from HyperCore.
     * Can be called multiple times for partial fills. Order status changes to FILLED
     * only when fully filled.
     *
     * For sell orders: fully filled when filledBaseAmount >= placedBaseAmount (all base tokens sold)
     * For buy orders: fully filled when filledBaseAmount >= placedBaseAmount (all base tokens bought)
     *
     * Note: Both buy and sell orders track fills by base token amount since HyperCore's
     * order size is always in base token units. The placedBaseAmount is set in placeOrderOnHyperCore:
     * - Sell orders: placedBaseAmount = data.amount (the base tokens being sold)
     * - Buy orders: placedBaseAmount = calculated base amount (quoteAmount / limitPrice)
     *
     * Note: This function is keeper-only (not owner) to prevent users from reporting
     * fake fills and draining funds from the contract's HyperCore balance.
     */
    function reportFill(
        uint256 orderId,
        uint256 baseAmountFilled,
        uint256 quoteAmountReceived
    ) external override onlyKeeper {
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.ON_HYPERCORE && state.status != OrderStatus.FILLED) {
            revert OrderNotOnHyperCore();
        }

        state.filledBaseAmount += baseAmountFilled;
        state.filledQuoteAmount += quoteAmountReceived;

        // Only mark as FILLED when fully filled
        // Both buy and sell orders are fully filled when all base tokens have been traded
        // placedBaseAmount is set in placeOrderOnHyperCore based on order type
        if (state.filledBaseAmount >= state.placedBaseAmount) {
            state.status = OrderStatus.FILLED;
        }

        emit OrderFilled(
            orderId,
            msg.sender,
            baseAmountFilled,
            quoteAmountReceived,
            state.filledBaseAmount,
            state.filledQuoteAmount
        );
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Called by keepers or the order owner to settle a filled order and transfer funds to the user on HyperCore.
     * - For sell orders: sends quote tokens (e.g., USDC when selling HYPE)
     * - For buy orders: sends base tokens (e.g., HYPE when buying HYPE with USDC)
     * The amount transferred is based on state.filledQuoteAmount (sell) or state.filledBaseAmount (buy).
     *
     * @param orderId The order ID to settle
     */
    function settleOrder(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant {
        OrderData storage data = orderData[orderId];
        OrderState storage state = orderStates[orderId];
        if (state.status != OrderStatus.FILLED) revert OrderNotFilled();

        state.status = OrderStatus.SETTLED;

        uint64 spotTokenIndex;
        uint256 amount;

        if (data.isBuy) {
            // Buy order: user bought spot base tokens (e.g., bought HYPE with USDC)
            // Send the filled spot base amount to user
            spotTokenIndex = _getSpotBaseTokenIndex(data.hyperCoreSpotPairId);
            amount = state.filledBaseAmount;
        } else {
            // Sell order: user sold spot base tokens for spot quote tokens (e.g., sold HYPE for USDC)
            // Send the filled spot quote amount to user
            spotTokenIndex = _getSpotQuoteTokenIndex(data.hyperCoreSpotPairId);
            amount = state.filledQuoteAmount;
        }

        // Send tokens to user on HyperCore via spotSend
        // Convert EVM amount to HyperCore wei for spotSend
        uint64 weiAmount = CoreWriterLib.evmToWei(spotTokenIndex, amount);

        // Verify contract has sufficient balance on HyperCore before sending
        // This prevents failures due to fees deducted by HyperCore during trading
        // The keeper should report the NET amount (after fees) in reportFill
        PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(this), spotTokenIndex);
        if (balance.total < weiAmount) revert InsufficientHyperCoreBalance();

        CoreWriterLib.spotSend(data.user, spotTokenIndex, weiAmount);

        emit OrderSettled(orderId, msg.sender, data.user, amount);
    }

    /**
     * @notice Get the spot pair's base token index from a spot pair ID
     * @dev Queries the SPOT_INFO_PRECOMPILE to get the tokens in the pair.
     *      SpotInfo.tokens[0] = spot base token (e.g., HYPE in HYPE/USDC)
     *      SpotInfo.tokens[1] = spot quote token (e.g., USDC in HYPE/USDC)
     * @param spotPairId The spot pair ID (10000 + spot_pair_index)
     * @return spotBaseTokenIndex The HyperCore token index of the spot pair's base token
     */
    function _getSpotBaseTokenIndex(uint32 spotPairId) internal view returns (uint64 spotBaseTokenIndex) {
        // Convert spot pair ID to spot index (e.g., 10107 -> 107)
        uint64 spotIndex = uint64(spotPairId - 10000);
        (bool success, bytes memory result) = SPOT_INFO_PRECOMPILE.staticcall(abi.encode(spotIndex));
        if (!success) revert TokenNotConfigured();
        SpotInfo memory info = abi.decode(result, (SpotInfo));
        return info.tokens[0]; // tokens[0] is the spot base token
    }

    /**
     * @notice Get the spot pair's quote token index from a spot pair ID
     * @dev Queries the SPOT_INFO_PRECOMPILE to get the tokens in the pair.
     *      SpotInfo.tokens[0] = spot base token (e.g., HYPE in HYPE/USDC)
     *      SpotInfo.tokens[1] = spot quote token (e.g., USDC in HYPE/USDC)
     * @param spotPairId The spot pair ID (10000 + spot_pair_index)
     * @return spotQuoteTokenIndex The HyperCore token index of the spot pair's quote token
     */
    function _getSpotQuoteTokenIndex(uint32 spotPairId) internal view returns (uint64 spotQuoteTokenIndex) {
        // Convert spot pair ID to spot index (e.g., 10107 -> 107)
        uint64 spotIndex = uint64(spotPairId - 10000);
        (bool success, bytes memory result) = SPOT_INFO_PRECOMPILE.staticcall(abi.encode(spotIndex));
        if (!success) revert TokenNotConfigured();
        SpotInfo memory info = abi.decode(result, (SpotInfo));
        return info.tokens[1]; // tokens[1] is the spot quote token
    }

    // ============ Internal Functions ============

    /**
     * @notice Internal function to create a new order
     * @dev Validates parameters, increments order counter, initializes order data,
     * and emits the OrderCreated event.
     * @param params The order creation parameters
     * @return orderId The newly created order ID
     */
    function _createOrder(CreateOrderParams calldata params) internal returns (uint256 orderId) {
        if (params.amount == 0) revert ZeroAmount();
        if (params.aToken == address(0)) revert InvalidAToken();
        if (IERC20(params.aToken).allowance(msg.sender, address(this)) < params.amount) {
            revert InsufficientAllowance();
        }

        // Get underlying token from aToken and verify it's registered in HyperLend Pool
        address underlyingToken = IAToken(params.aToken).UNDERLYING_ASSET_ADDRESS();
        if (POOL.getReserveData(underlyingToken).aTokenAddress != params.aToken) {
            revert InvalidUnderlying();
        }

        orderId = ++orderCounter;
        userOrderIds[msg.sender].push(orderId);

        // Initialize order data
        OrderData storage data = orderData[orderId];
        data.user = msg.sender;
        data.aToken = params.aToken;
        data.underlyingToken = underlyingToken;
        data.amount = params.amount;
        data.triggerPrice = params.triggerPrice;
        data.limitPrice = params.limitPrice;
        data.hyperCoreSpotPairId = params.hyperCoreSpotPairId;
        data.isBuy = params.isBuy;
        data.tif = params.tif;
        data.reduceOnly = params.reduceOnly;

        // Initialize order state
        OrderState storage state = orderStates[orderId];
        state.status = OrderStatus.PENDING;
        state.createdAt = block.timestamp;

        emit OrderCreated(
            orderId,
            msg.sender,
            params.aToken,
            params.amount,
            params.triggerPrice,
            params.limitPrice,
            params.hyperCoreSpotPairId,
            params.isBuy
        );
    }

    // ============ View Functions ============

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Returns the complete order information by combining data and state.
     */
    function getOrder(uint256 orderId) external view override returns (LimitOrder memory) {
        return LimitOrder({
            data: orderData[orderId],
            state: orderStates[orderId]
        });
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Returns only the order data (user-defined parameters). More gas efficient
     * than getOrder() when only data is needed.
     */
    function getOrderData(uint256 orderId) external view override returns (OrderData memory) {
        return orderData[orderId];
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Returns only the order state (execution status and metadata). More gas efficient
     * than getOrder() when only state is needed.
     */
    function getOrderState(uint256 orderId) external view override returns (OrderState memory) {
        return orderStates[orderId];
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Returns all order IDs created by a specific user.
     */
    function getUserOrders(address user) external view override returns (uint256[] memory) {
        return userOrderIds[user];
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Returns the total number of orders created (also the last order ID).
     */
    function getOrderCount() external view override returns (uint256) {
        return orderCounter;
    }

    /**
     * @notice Get the current status of an order
     * @dev Most gas efficient way to check order status without loading full order data.
     * @param orderId The order ID to query
     * @return The current OrderStatus enum value
     */
    function getOrderStatus(uint256 orderId) external view returns (OrderStatus) {
        return orderStates[orderId].status;
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Queries the HyperCore spot balance precompile for this contract's balance.
     */
    function getHyperCoreBalance(uint64 tokenIndex) external view override returns (uint64 total, uint64 hold) {
        PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(this), tokenIndex);
        return (balance.total, balance.hold);
    }

    /**
     * @notice Receive native HYPE from WHYPE unwrap
     * @dev Required to receive native HYPE when unwrapping WHYPE before bridging to HyperCore
     */
    receive() external payable {}
}

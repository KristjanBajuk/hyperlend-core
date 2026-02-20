// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Ownable} from '../../dependencies/openzeppelin/contracts/Ownable.sol';
import {Pausable} from '../../dependencies/openzeppelin/contracts/Pausable.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IAToken} from '../../interfaces/IAToken.sol';
import {IERC20WithPermit} from '../../interfaces/IERC20WithPermit.sol';
import {ILimitOrderManager} from './interfaces/ILimitOrderManager.sol';
import {LimitOrderCancellation, IWHYPE} from './LimitOrderCancellation.sol';
import {CoreWriterLib} from './libraries/CoreWriterLib.sol';
import {PrecompileLib} from '@hyper-evm-lib/PrecompileLib.sol';

/**
 * @title LimitOrderManager
 * @author HyperLend
 * @notice Manages limit orders that integrate HyperLend deposits with Hyperliquid's HyperCore spot trading
 * @dev This contract allows users to create limit orders using their aToken collateral from HyperLend.
 *
 */
contract LimitOrderManager is LimitOrderCancellation, Ownable, Pausable {
  using SafeERC20 for IERC20;

  // ============ Constants ============

  /// @notice HyperCore Spot Info Precompile address for querying spot pair data
  address constant SPOT_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080b;

  /// @notice HyperCore Token Info Precompile address for querying token decimals
  address constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;

  /// @notice HYPE token index on HyperCore mainnet
  uint64 constant HYPE_TOKEN_INDEX = 150;

  /// @notice HYPE has 10 extra decimals on EVM (18 EVM decimals - 8 HyperCore wei decimals)
  uint8 constant HYPE_EVM_EXTRA_DECIMALS = 10;

  /// @notice Price precision for HyperCore (10^8)
  uint256 constant PRICE_PRECISION = 1e8;

  /// @notice Spot pair ID offset (spot pair ID = 10000 + spot_pair_index)
  uint32 constant SPOT_PAIR_ID_OFFSET = 10000;

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
    if (keeper == address(0)) revert ZeroKeeperAddress();
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
  function createOrder(CreateOrderParams calldata params) external override nonReentrant whenNotPaused returns (uint256 orderId) {
    return _createOrder(params);
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
  function executeOrder(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant whenNotPaused {
    OrderData storage data = orderData[orderId];
    OrderState storage state = orderStates[orderId];

    if (data.user == address(0)) revert OrderDoesNotExist();
    if (state.status != OrderStatus.PENDING) revert OrderNotPending();

    // Check if order has expired
    if (data.expiresAt != 0 && block.timestamp > data.expiresAt) revert OrderExpired();

    state.status = OrderStatus.TRIGGERED;
    state.triggeredAt = block.timestamp;

    address user = data.user;
    address aToken = data.aToken;
    address underlyingToken = data.underlyingToken;
    uint256 amount = data.amount;

    // Transfer aTokens from user to this contract
    IERC20(aToken).safeTransferFrom(user, address(this), amount);

    // Withdraw underlying token from Pool
    uint256 withdrawn = POOL.withdraw(underlyingToken, amount, address(this));
    if (withdrawn != amount) revert WithdrawalAmountMismatch();

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
  function bridgeToHyperCore(uint256 orderId) external override onlyKeeperOrOwner(orderId) nonReentrant whenNotPaused {
    OrderData storage data = orderData[orderId];
    OrderState storage state = orderStates[orderId];
    if (state.status != OrderStatus.TRIGGERED) revert OrderNotTriggered();

    state.status = OrderStatus.BRIDGING;

    bool isBuy = data.isBuy;
    uint32 hyperCoreSpotPairId = data.hyperCoreSpotPairId;
    uint256 amount = data.amount;
    address underlyingToken = data.underlyingToken;

    // Get the token index based on order type
    // Sell order: bridge spot base tokens (e.g., HYPE)
    // Buy order: bridge spot quote tokens (e.g., USDC)
    uint64 tokenIndex = isBuy
      ? _getSpotQuoteTokenIndex(hyperCoreSpotPairId)
      : _getSpotBaseTokenIndex(hyperCoreSpotPairId);

    // For HYPE, we need to unwrap WHYPE to native HYPE before bridging
    // HyperLend uses WHYPE (0x555...555) as the underlying for aWHYPE
    // The CoreWriterLib.bridgeToCoreByIndex expects native HYPE (sent via msg.value)
    if (tokenIndex == HYPE_TOKEN_INDEX) {
      uint256 whypeBalance = IERC20(WHYPE).balanceOf(address(this));
      if (whypeBalance < amount) revert InsufficientWHYPEBalance();
      // Unwrap WHYPE to native HYPE - this sends native HYPE to this contract (msg.sender)
      IWHYPE(WHYPE).withdraw(amount);
    }

    // Bridge tokens from EVM to HyperCore spot balance using token index
    CoreWriterLib.bridgeToCoreByIndex(tokenIndex, amount);

    emit TokensBridgedToHyperCore(orderId, msg.sender, underlyingToken, amount);
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
  ) external override onlyKeeperOrOwner(orderId) nonReentrant whenNotPaused {
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
    if (state.status != OrderStatus.ON_HYPERCORE) {
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
   * @inheritdoc ILimitOrderManager
   * @dev Only callable by authorized keepers. Use with caution - this bypasses normal state transitions.
   * Intended for emergency recovery or correcting order states that got stuck.
   */
  function setOrderStatus(uint256 orderId, OrderStatus newStatus) external override onlyKeeper {
    OrderState storage state = orderStates[orderId];
    OrderStatus oldStatus = state.status;
    state.status = newStatus;
    emit OrderStatusChanged(orderId, msg.sender, oldStatus, newStatus);
  }


  /**
   * @notice Get the spot pair's base token index from a spot pair ID
     * @dev Queries the SPOT_INFO_PRECOMPILE to get the tokens in the pair.
     *      SpotInfo.tokens[0] = spot base token (e.g., HYPE in HYPE/USDC)
     *      SpotInfo.tokens[1] = spot quote token (e.g., USDC in HYPE/USDC)
     * @param spotPairId The spot pair ID (10000 + spot_pair_index)
     * @return spotBaseTokenIndex The HyperCore token index of the spot pair's base token
     */
  function _getSpotBaseTokenIndex(uint32 spotPairId) internal view override returns (uint64 spotBaseTokenIndex) {
    // Convert spot pair ID to spot index (e.g., 10107 -> 107)
    uint64 spotIndex = uint64(spotPairId - SPOT_PAIR_ID_OFFSET);
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
  function _getSpotQuoteTokenIndex(uint32 spotPairId) internal view override returns (uint64 spotQuoteTokenIndex) {
    // Convert spot pair ID to spot index (e.g., 10107 -> 107)
    uint64 spotIndex = uint64(spotPairId - SPOT_PAIR_ID_OFFSET);
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
    if (params.hyperCoreSpotPairId < SPOT_PAIR_ID_OFFSET) revert InvalidSpotPairId();
    if (params.limitPrice == 0) revert InvalidLimitPrice();
    if (IERC20(params.aToken).allowance(msg.sender, address(this)) < params.amount) {
      revert InsufficientAllowance();
    }

    // Get underlying token from aToken and verify it's registered in HyperLend Pool
    address underlyingToken = IAToken(params.aToken).UNDERLYING_ASSET_ADDRESS();
    if (POOL.getReserveData(underlyingToken).aTokenAddress != params.aToken) {
      revert InvalidUnderlying();
    }

    orderId = ++orderCounter;

    OrderData storage data = orderData[orderId];
    data.user = msg.sender;
    data.triggerPrice = params.triggerPrice;
    data.hyperCoreSpotPairId = params.hyperCoreSpotPairId;
    data.aToken = params.aToken;
    data.limitPrice = params.limitPrice;
    data.isBuy = params.isBuy;
    data.tif = params.tif;
    data.reduceOnly = params.reduceOnly;
    data.underlyingToken = underlyingToken;
    data.amount = params.amount;
    data.expiresAt = params.expiresAt;

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
      params.isBuy,
      params.tif,
      params.reduceOnly,
      params.expiresAt
    );
  }

  /**
   * @notice Receive native HYPE from WHYPE unwrap
   * @dev Required to receive native HYPE when unwrapping WHYPE before bridging to HyperCore.
   */
  receive() external payable {
    emit NativeHypeReceived(msg.sender, msg.value);
  }

  // ============ Abstract Function Implementations (for LimitOrderCancellation) ============

  /// @inheritdoc LimitOrderCancellation
  function _getOrderData(uint256 orderId) internal view override returns (OrderData storage) {
    return orderData[orderId];
  }

  /// @inheritdoc LimitOrderCancellation
  function _getOrderState(uint256 orderId) internal view override returns (OrderState storage) {
    return orderStates[orderId];
  }

  /// @inheritdoc LimitOrderCancellation
  function _isKeeperOrOwner(uint256 orderId) internal view override returns (bool) {
    return authorizedKeepers[msg.sender] || orderData[orderId].user == msg.sender;
  }

  // ============ Admin Functions ============

  /**
   * @inheritdoc ILimitOrderManager
   * @dev Only callable by the contract owner. When paused, order creation and execution are disabled.
   *      Cancellation functions remain available so users can recover their funds.
   */
  function pause() external override onlyOwner {
    _pause();
  }

  /**
   * @inheritdoc ILimitOrderManager
   * @dev Only callable by the contract owner.
   */
  function unpause() external override onlyOwner {
    _unpause();
  }

  /**
   * @notice Recover ERC20 tokens accidentally sent to this contract
   * @dev Only callable by the contract owner. This is an emergency function to recover
   *      tokens that were accidentally sent to the contract address.
   *      WARNING: Use with caution - ensure the tokens are not part of active orders.
   * @param token The ERC20 token address to recover
   * @param to The address to send the recovered tokens to
   * @param amount The amount of tokens to recover
   */
  function recoverERC20(address token, address to, uint256 amount) external onlyOwner {
    if (to == address(0)) revert ZeroAddress();
    IERC20(token).safeTransfer(to, amount);
    emit TokensRecovered(token, to, amount);
  }

  /**
   * @notice Recover native HYPE accidentally sent to this contract
   * @dev Only callable by the contract owner. This is an emergency function to recover
   *      native HYPE that was accidentally sent to the contract address.
   *      WARNING: Use with caution - ensure the HYPE is not part of active orders
   *      (e.g., from WHYPE unwrap waiting to be bridged).
   * @param to The address to send the recovered HYPE to
   * @param amount The amount of native HYPE to recover
   */
  function recoverNativeHYPE(address payable to, uint256 amount) external onlyOwner {
    if (to == address(0)) revert ZeroAddress();
    (bool success, ) = to.call{value: amount}("");
    if (!success) revert NativeHypeTransferFailed();
    emit NativeHypeRecovered(to, amount);
  }
}

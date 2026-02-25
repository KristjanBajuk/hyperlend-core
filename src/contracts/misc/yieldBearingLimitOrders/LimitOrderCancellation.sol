// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {ReentrancyGuard} from '../../dependencies/openzeppelin/ReentrancyGuard.sol';
import {ILimitOrderManager} from './interfaces/ILimitOrderManager.sol';
import {CoreWriterLib} from './libraries/CoreWriterLib.sol';
import {PrecompileLib} from '@hyper-evm-lib/PrecompileLib.sol';

/// @notice Interface for Wrapped HYPE (WHYPE) token
interface IWHYPE {
    function withdraw(uint256 value) external;
}

/**
 * @title LimitOrderCancellation
 * @author HyperLend
 * @notice Abstract contract handling order cancellation and refund logic
 * @dev Inherited by LimitOrderManager. Provides cancellation functions for different order states:
 *      - PENDING: cancelPendingOrder() - No token transfer needed
 *      - TRIGGERED: cancelTriggeredOrder() - Returns EVM tokens (unwraps WHYPE to native HYPE)
 *      - BRIDGING: cancelBridgedOrder() - Returns HyperCore tokens
 *      - ON_HYPERCORE: requestCancellation() + finalizeCancellation() - Two-step process
 */
abstract contract LimitOrderCancellation is ILimitOrderManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Wrapped HYPE (WHYPE) contract address - used by HyperLend for HYPE
    address constant WHYPE = 0x5555555555555555555555555555555555555555;

    // ============ Abstract Functions ============
    // These must be implemented by the inheriting contract

    function _getOrderData(uint256 orderId) internal view virtual returns (OrderData storage);
    function _getOrderState(uint256 orderId) internal view virtual returns (OrderState storage);
    function _getSpotBaseTokenIndex(uint32 spotPairId) internal view virtual returns (uint64);
    function _getSpotQuoteTokenIndex(uint32 spotPairId) internal view virtual returns (uint64);
    function _isKeeperOrOwner(uint256 orderId) internal view virtual returns (bool);

    // ============ Private Helper Functions ============

    /**
     * @dev Transfers tokens back to user on EVM.
     * For WHYPE, unwraps to native HYPE so user gets back what they deposited.
     * For other tokens, transfers ERC20 directly.
     * @param recipient The address to send tokens to
     * @param token The token address to transfer
     * @param amount The amount to transfer
     */
    function _transferTokensOnEvm(address recipient, address token, uint256 amount) private {
        if (token == WHYPE) {
            uint256 whypeBalance = IERC20(WHYPE).balanceOf(address(this));
            if (whypeBalance < amount) revert InsufficientWHYPEBalance();
            IWHYPE(WHYPE).withdraw(amount);
            (bool success, ) = recipient.call{value: amount}("");
            if (!success) revert NativeHypeTransferFailed();
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    /**
     * @dev Transfers tokens back to user on HyperCore using spotSend.
     * Determines the correct token index based on order type (buy/sell).
     * @param recipient The address to send tokens to on HyperCore
     * @param spotPairId The HyperCore spot pair ID
     * @param amount The amount to transfer (in EVM wei)
     * @param isBuy True if this is a buy order, false for sell order
     */
    function _transferTokensOnHyperCore(
        address recipient,
        uint32 spotPairId,
        uint256 amount,
        bool isBuy
    ) private {
        // For buy orders, user placed quote tokens; for sell orders, user placed base tokens
        uint64 tokenIndex = isBuy
            ? _getSpotQuoteTokenIndex(spotPairId)
            : _getSpotBaseTokenIndex(spotPairId);
        uint64 weiAmount = CoreWriterLib.evmToWei(tokenIndex, amount);
        CoreWriterLib.spotSend(recipient, tokenIndex, weiAmount);
    }

    /**
     * @dev Internal helper to send tokens on HyperCore with balance verification.
     * Skips if amount is zero.
     * @param recipient The address to send tokens to on HyperCore
     * @param tokenIndex The HyperCore token index
     * @param amount The amount to send in EVM wei units
     */
    function _sendTokensOnHyperCore(address recipient, uint64 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;

        uint64 weiAmount = CoreWriterLib.evmToWei(tokenIndex, amount);
        PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(this), tokenIndex);
        if (balance.total < weiAmount) revert InsufficientHyperCoreBalance();
        CoreWriterLib.spotSend(recipient, tokenIndex, weiAmount);
    }

    // ============ Cancellation Functions ============

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Cancels a PENDING order. Only the order owner can cancel.
     * Since aTokens are only transferred when the order is triggered,
     * no token transfer is needed for cancellation of pending orders.
     */
    function cancelPendingOrder(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.PENDING) revert OrderNotPending();

        state.status = OrderStatus.CANCELLED;

        emit OrderCancelled(orderId, msg.sender);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Cancels a TRIGGERED order and returns underlying tokens on EVM.
     * Only the order owner can cancel. Tokens were withdrawn from HyperLend
     * but not yet bridged to HyperCore.
     * Note: For HYPE orders, user deposited native HYPE but HyperLend holds WHYPE.
     *       We unwrap WHYPE to native HYPE so user gets back what they deposited.
     */
    function cancelTriggeredOrder(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.TRIGGERED) {
            revert CannotRefundInCurrentStatus();
        }

        state.status = OrderStatus.CANCELLED;

        _transferTokensOnEvm(msg.sender, data.underlyingToken, data.amount);

        emit OrderCancelled(orderId, msg.sender);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Cancels a BRIDGING order and returns tokens on HyperCore.
     * Only the order owner can cancel. Tokens were bridged to HyperCore
     * but the order hasn't been placed yet.
     * Note: Must wait for the next Core block after bridgeToHyperCore before calling.
     */
    function cancelBridgedOrder(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.BRIDGING) {
            revert OrderNotBridging();
        }

        state.status = OrderStatus.CANCELLED;

        _transferTokensOnHyperCore(data.user, data.hyperCoreSpotPairId, data.amount, data.isBuy);

        emit OrderCancelled(orderId, data.user);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev First step of two-step cancellation for ON_HYPERCORE or PARTIALLY_FILLED orders.
     * Cancels the order on HyperCore and sets status to CANCEL_REQUESTED.
     * Must call finalizeCancellation() after next Core block.
     *
     * For PARTIALLY_FILLED orders, this cancels the remaining unfilled portion on HyperCore.
     * The user will receive both filled tokens and unfilled refund in finalizeCancellation().
     */
    function requestCancellation(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.ON_HYPERCORE && state.status != OrderStatus.PARTIALLY_FILLED) {
            revert OrderNotOnHyperCoreForCancellation();
        }

        state.status = OrderStatus.CANCEL_REQUESTED;

        // Cancel the order on HyperCore using cloid
        CoreWriterLib.cancelOrderByCloid(data.hyperCoreSpotPairId, state.cloid);

        emit OrderCancelledOnHyperCore(orderId, msg.sender, state.cloid);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Second step of two-step cancellation. Sends tokens back to user on HyperCore.
     * For sell orders: sends filled quote tokens + unfilled base tokens
     * For buy orders: sends filled base tokens + unfilled quote tokens
     * Must be called after requestCancellation and waiting for the next Core block.
     */
    function finalizeCancellation(uint256 orderId) external override nonReentrant {
        if (!_isKeeperOrOwner(orderId)) revert NotAuthorizedKeeperOrOwner();

        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
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
            // Send unfilled spot quote tokens back to user (what wasn't spent)
            uint256 unfilledQuoteAmount = state.filledQuoteAmount >= data.amount
                ? 0
                : data.amount - state.filledQuoteAmount;

            _sendTokensOnHyperCore(data.user, spotBaseTokenIndex, state.filledBaseAmount);
            _sendTokensOnHyperCore(data.user, spotQuoteTokenIndex, unfilledQuoteAmount);
        } else {
            // Sell order: user placed spot base tokens to sell for spot quote tokens
            // Send filled spot quote tokens to user (what they received)
            // Send unfilled spot base tokens back to user (what wasn't sold)
            uint256 unfilledBaseAmount = state.filledBaseAmount >= data.amount
                ? 0
                : data.amount - state.filledBaseAmount;

            _sendTokensOnHyperCore(data.user, spotQuoteTokenIndex, state.filledQuoteAmount);
            _sendTokensOnHyperCore(data.user, spotBaseTokenIndex, unfilledBaseAmount);
        }

        emit OrderCancelled(orderId, data.user);
    }

    // ============ Error Recovery Functions ============

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Recovers funds from FAILED_ON_HYPERCORE status when tokens are on HyperCore.
     * Use this when order failed and funds are on HyperCore.
     */
    function recoverFromFailedOnHyperCore(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.FAILED_ON_HYPERCORE) revert OrderNotFailedOnHyperCore();

        state.status = OrderStatus.CANCELLED;

        _transferTokensOnHyperCore(data.user, data.hyperCoreSpotPairId, data.amount, data.isBuy);

        emit OrderCancelled(orderId, data.user);
    }

    /**
     * @inheritdoc ILimitOrderManager
     * @dev Recovers funds from FAILED_ON_EVM status when tokens are still on EVM.
     * Use this when order failed and tokens never reached HyperCore.
     * Note: For HYPE orders, user deposited native HYPE but HyperLend holds WHYPE.
     *       We unwrap WHYPE to native HYPE so user gets back what they deposited.
     */
    function recoverFromFailedOnEvm(uint256 orderId) external override nonReentrant {
        OrderData storage data = _getOrderData(orderId);
        OrderState storage state = _getOrderState(orderId);
        if (data.user != msg.sender) revert NotOrderOwner();
        if (state.status != OrderStatus.FAILED_ON_EVM) revert OrderNotFailedOnEvm();

        state.status = OrderStatus.CANCELLED;

        _transferTokensOnEvm(msg.sender, data.underlyingToken, data.amount);

        emit OrderCancelled(orderId, msg.sender);
    }
}


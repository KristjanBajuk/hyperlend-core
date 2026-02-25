// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {ILimitOrderManager} from './interfaces/ILimitOrderManager.sol';
import {CoreWriterLib} from './libraries/CoreWriterLib.sol';
import {PrecompileLib} from '@hyper-evm-lib/PrecompileLib.sol';

/**
 * @title LimitOrderRecovery
 * @author HyperLend
 * @notice Abstract contract handling admin recovery functions for stuck tokens
 * @dev Inherited by LimitOrderManager. Provides emergency recovery functions for:
 *      - ERC20 tokens accidentally sent to the contract
 *      - Native HYPE accidentally sent to the contract
 *      - Tokens stuck on HyperCore
 *
 *      All recovery functions are restricted to the contract owner and should be
 *      used with extreme caution to avoid recovering tokens that belong to active orders.
 */
abstract contract LimitOrderRecovery is ILimitOrderManager {
    using SafeERC20 for IERC20;

    // ============ Abstract Functions ============
    // These must be implemented by the inheriting contract

    /**
     * @dev Returns true if the caller is the contract owner
     */
    function _isOwner() internal view virtual returns (bool);

    // ============ Recovery Functions ============

    /**
     * @notice Recover ERC20 tokens accidentally sent to this contract
     * @dev Only callable by the contract owner. This is an emergency function to recover
     *      tokens that were accidentally sent to the contract address.
     *      WARNING: Use with caution - ensure the tokens are not part of active orders.
     * @param token The ERC20 token address to recover
     * @param to The address to send the recovered tokens to
     * @param amount The amount of tokens to recover
     */
    function recoverERC20(address token, address to, uint256 amount) external {
        if (!_isOwner()) revert NotOwner();
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
    function recoverNativeHYPE(address payable to, uint256 amount) external {
        if (!_isOwner()) revert NotOwner();
        if (to == address(0)) revert ZeroAddress();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert NativeHypeTransferFailed();
        emit NativeHypeRecovered(to, amount);
    }

    /**
     * @notice Recover tokens stuck on HyperCore to a destination address
     * @dev Only callable by the contract owner. This is an emergency function to recover
     *      tokens that are stuck on HyperCore (similar to how recoverNativeHYPE recovers native HYPE on EVM).
     *
     *      WARNING: Use with extreme caution! This function can recover ANY tokens held by this contract
     *      on HyperCore. Before calling, ensure the tokens are not part of active orders:
     *      - Tokens bridged but not yet placed as orders (BRIDGING status)
     *      - Tokens from filled orders waiting to be settled (FILLED status)
     *      - Tokens from partially filled orders (PARTIALLY_FILLED status)
     *      - Tokens from cancelled orders waiting for finalization (CANCEL_REQUESTED status)
     *
     *      Incorrectly recovering tokens that belong to active orders will result in users losing their funds.
     *
     * @param tokenIndex The HyperCore token index to recover (e.g., 150 for HYPE, 0 for USDC)
     * @param destination The address to send the recovered tokens to on HyperCore
     * @param weiAmount The amount to recover in HyperCore wei units (8 decimals for most tokens)
     */
    function recoverFundsFromHyperCore(
        uint64 tokenIndex,
        address destination,
        uint64 weiAmount
    ) external {
        if (!_isOwner()) revert NotOwner();
        if (destination == address(0)) revert ZeroAddress();

        // Verify the contract has sufficient balance on HyperCore
        PrecompileLib.SpotBalance memory balance = PrecompileLib.spotBalance(address(this), tokenIndex);
        if (balance.total < weiAmount) revert InsufficientHyperCoreBalance();

        // Transfer tokens to destination on HyperCore
        CoreWriterLib.spotSend(destination, tokenIndex, weiAmount);

        emit HyperCoreFundsRecovered(tokenIndex, destination, weiAmount);
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ILimitOrderManager} from './ILimitOrderManager.sol';

/**
 * @title ILimitOrderBatchExecutor
 * @author HyperLend
 * @notice Interface for batch execution of limit order operations
 * @dev This contract handles batch operations to reduce gas costs for keepers.
 *      It calls the main LimitOrderManager contract for each operation.
 */
interface ILimitOrderBatchExecutor {
    // ============ Errors ============

    /// @notice Thrown when caller is not an authorized keeper
    error NotAuthorizedKeeper();

    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();

    // ============ Events ============

    /// @notice Emitted when a keeper is authorized or revoked
    event KeeperUpdated(address indexed keeper, bool authorized);

    /// @notice Emitted when the LimitOrderManager is updated
    event LimitOrderManagerUpdated(address indexed oldManager, address indexed newManager);

    // ============ Admin Functions ============

    /**
     * @notice Authorize or revoke a keeper address
     * @param keeper The address to authorize or revoke
     * @param authorized True to authorize, false to revoke
     */
    function setKeeper(address keeper, bool authorized) external;

    /**
     * @notice Update the LimitOrderManager contract address
     * @param newLimitOrderManager The new LimitOrderManager contract address
     */
    function setLimitOrderManager(ILimitOrderManager newLimitOrderManager) external;

    // ============ Batch Functions ============

    /**
     * @notice Execute multiple pending orders in a single transaction
     * @dev Only callable by authorized keepers. Withdraws underlying from HyperLend for each order.
     * @param orderIds Array of order IDs to execute
     */
    function executeOrdersBatch(uint256[] calldata orderIds) external;

    /**
     * @notice Bridge tokens from EVM to HyperCore for multiple orders in a single transaction
     * @dev Only callable by authorized keepers. Must be called after executeOrder for each order.
     * @param orderIds Array of order IDs to bridge tokens for
     */
    function bridgeToHyperCoreBatch(uint256[] calldata orderIds) external;

    /**
     * @notice Place multiple bridged orders on HyperCore's spot order book in a single transaction
     * @dev Only callable by authorized keepers. Must be called after bridgeToHyperCore for each order.
     * @param params Array of PlaceOrderOnHyperCoreParams containing orderId and cloid for each order
     */
    function placeOrdersOnHyperCoreBatch(
        ILimitOrderManager.PlaceOrderOnHyperCoreParams[] calldata params
    ) external;

    /**
     * @notice Report fills for multiple orders in a single transaction
     * @dev Only callable by authorized keepers. Can be called multiple times for partial fills.
     * @param params Array of ReportFillParams containing orderId, baseAmountFilled, and quoteAmountReceived
     */
    function reportFillsBatch(ILimitOrderManager.ReportFillParams[] calldata params) external;

    /**
     * @notice Settle multiple filled orders in a single transaction
     * @dev Only callable by authorized keepers. Transfers funds to users on HyperCore.
     * @param orderIds Array of order IDs to settle
     */
    function settleOrdersBatch(uint256[] calldata orderIds) external;

    // ============ View Functions ============

    /**
     * @notice Get the LimitOrderManager contract address
     * @return The address of the LimitOrderManager contract
     */
    function limitOrderManager() external view returns (ILimitOrderManager);

    /**
     * @notice Check if an address is an authorized keeper
     * @param keeper The address to check
     * @return True if the address is an authorized keeper
     */
    function authorizedKeepers(address keeper) external view returns (bool);
}


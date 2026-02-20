// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Ownable} from '../../dependencies/openzeppelin/contracts/Ownable.sol';
import {ReentrancyGuard} from '../../dependencies/openzeppelin/ReentrancyGuard.sol';
import {ILimitOrderManager} from './interfaces/ILimitOrderManager.sol';
import {ILimitOrderBatchExecutor} from './interfaces/ILimitOrderBatchExecutor.sol';

/**
 * @title LimitOrderBatchExecutor
 * @author HyperLend
 * @notice Handles batch execution of limit order operations
 * @dev This contract calls the main LimitOrderManager contract for each operation.
 *      It must be authorized as a keeper on the LimitOrderManager to execute orders.
 */
contract LimitOrderBatchExecutor is ILimitOrderBatchExecutor, Ownable, ReentrancyGuard {
    // ============ State Variables ============

    /// @notice The LimitOrderManager contract
    ILimitOrderManager public override limitOrderManager;

    /// @notice Mapping from keeper address to their authorization status
    mapping(address => bool) public override authorizedKeepers;

    // ============ Modifiers ============

    modifier onlyKeeper() {
        if (!authorizedKeepers[msg.sender]) {
            revert NotAuthorizedKeeper();
        }
        _;
    }

    // ============ Constructor ============

    /**
     * @notice Initializes the LimitOrderBatchExecutor contract
     * @param _limitOrderManager The LimitOrderManager contract address
     */
    constructor(ILimitOrderManager _limitOrderManager) {
        limitOrderManager = _limitOrderManager;
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function setKeeper(address keeper, bool authorized) external override onlyOwner {
        authorizedKeepers[keeper] = authorized;
        emit KeeperUpdated(keeper, authorized);
    }

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function setLimitOrderManager(ILimitOrderManager newLimitOrderManager) external override onlyOwner {
        if (address(newLimitOrderManager) == address(0)) {
            revert InvalidAddress();
        }
        address oldManager = address(limitOrderManager);
        limitOrderManager = newLimitOrderManager;
        emit LimitOrderManagerUpdated(oldManager, address(newLimitOrderManager));
    }

    // ============ Batch Functions ============

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function executeOrdersBatch(uint256[] calldata orderIds) external override onlyKeeper nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            limitOrderManager.executeOrder(orderIds[i]);
        }
    }

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function bridgeToHyperCoreBatch(uint256[] calldata orderIds) external override onlyKeeper nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            limitOrderManager.bridgeToHyperCore(orderIds[i]);
        }
    }

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function placeOrdersOnHyperCoreBatch(
        ILimitOrderManager.PlaceOrderOnHyperCoreParams[] calldata params
    ) external override onlyKeeper nonReentrant {
        for (uint256 i = 0; i < params.length; i++) {
            limitOrderManager.placeOrderOnHyperCore(params[i].orderId, params[i].cloid);
        }
    }

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function reportFillsBatch(
        ILimitOrderManager.ReportFillParams[] calldata params
    ) external override onlyKeeper {
        for (uint256 i = 0; i < params.length; i++) {
            limitOrderManager.reportFill(
                params[i].orderId,
                params[i].baseAmountFilled,
                params[i].quoteAmountReceived
            );
        }
    }

    /**
     * @inheritdoc ILimitOrderBatchExecutor
     */
    function settleOrdersBatch(uint256[] calldata orderIds) external override onlyKeeper nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            limitOrderManager.settleOrder(orderIds[i]);
        }
    }
}


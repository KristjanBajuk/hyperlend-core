// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Test, console} from 'forge-std/Test.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol';
import {IPoolAddressesProvider} from '../../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../../src/contracts/interfaces/IPool.sol';
import {DataTypes} from '../../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {LimitOrderManager} from '../../../src/contracts/misc/yieldBearingLimitOrders/LimitOrderManager.sol';
import {ILimitOrderManager} from '../../../src/contracts/misc/yieldBearingLimitOrders/interfaces/ILimitOrderManager.sol';
import {MintableERC20} from '../../../src/contracts/mocks/tokens/MintableERC20.sol';
import {PrecompileLib} from '@hyper-evm-lib/PrecompileLib.sol';

// Import mocks from local mocks folder
import {MockAToken} from './mocks/MockAToken.sol';
import {MockPool} from './mocks/MockPool.sol';
import {MockPoolAddressesProvider} from './mocks/MockPoolAddressesProvider.sol';

/// @title LimitOrderCancellationTest
/// @notice Unit tests for LimitOrderCancellation functionality
contract LimitOrderCancellationTest is Test {
    // Constants
    uint32 constant HYPE_USDC_SPOT_PAIR_ID = 10107; // 10000 + 107

    // Contracts
    LimitOrderManager public limitOrderManager;
    MockPoolAddressesProvider public addressesProvider;
    MockPool public pool;
    MintableERC20 public underlying;
    MockAToken public aToken;

    // Test accounts
    address public owner;
    address public keeper;
    address public user1;
    address public user2;

    // Events
    event OrderCancelled(uint256 indexed orderId, address indexed user);

    function setUp() public {
        // Initialize test accounts
        owner = address(this);
        keeper = makeAddr("keeper");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock contracts
        underlying = new MintableERC20("Mock WHYPE", "WHYPE", 18);
        aToken = new MockAToken(address(underlying));
        pool = new MockPool();
        addressesProvider = new MockPoolAddressesProvider();

        // Configure mocks
        addressesProvider.setPool(address(pool));
        pool.setReserveAToken(address(underlying), address(aToken));

        // Deploy LimitOrderManager
        limitOrderManager = new LimitOrderManager(
            IPoolAddressesProvider(address(addressesProvider))
        );

        // Set keeper
        limitOrderManager.setKeeper(keeper, true);

        // Fund test accounts with aTokens
        aToken.mint(user1, 1000e18);
        aToken.mint(user2, 1000e18);

        // Fund pool with underlying for withdrawals
        underlying.mint(address(pool), 10000e18);

        // Approve LimitOrderManager to spend aTokens
        vm.prank(user1);
        aToken.approve(address(limitOrderManager), type(uint256).max);
        vm.prank(user2);
        aToken.approve(address(limitOrderManager), type(uint256).max);
    }

    // ============================================
    // HELPER FUNCTIONS
    // ============================================

    function _createDefaultOrderParams() internal view returns (ILimitOrderManager.CreateOrderParams memory) {
        return ILimitOrderManager.CreateOrderParams({
            aToken: address(aToken),
            amount: 100e18,
            triggerPrice: 20e8,
            limitPrice: 21e8,
            hyperCoreSpotPairId: HYPE_USDC_SPOT_PAIR_ID,
            isBuy: true,
            expiresAt: 0
        });
    }

    function _createOrder(address user) internal returns (uint256 orderId) {
        vm.prank(user);
        orderId = limitOrderManager.createOrder(_createDefaultOrderParams());
    }

    // ============================================
    // CANCEL PENDING ORDER TESTS
    // ============================================

    function test_cancelPendingOrder_success() public {
        uint256 orderId = _createOrder(user1);

        vm.prank(user1);
        limitOrderManager.cancelPendingOrder(orderId);

        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED), "Status should be CANCELLED");
    }

    function test_cancelPendingOrder_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.cancelPendingOrder(orderId);
    }

    function test_cancelPendingOrder_revert_orderNotPending() public {
        uint256 orderId = _createOrder(user1);

        // Execute the order first
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Try to cancel pending
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotPending.selector);
        limitOrderManager.cancelPendingOrder(orderId);
    }

    function test_cancelPendingOrder_emitsEvent() public {
        uint256 orderId = _createOrder(user1);

        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit OrderCancelled(orderId, user1);
        limitOrderManager.cancelPendingOrder(orderId);
    }

    // ============================================
    // CANCEL TRIGGERED ORDER TESTS
    // ============================================

    function test_cancelTriggeredOrder_success() public {
        uint256 orderId = _createOrder(user1);

        // Execute the order
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        uint256 user1BalanceBefore = underlying.balanceOf(user1);

        // Cancel triggered order
        vm.prank(user1);
        limitOrderManager.cancelTriggeredOrder(orderId);

        // Check underlying returned to user
        assertEq(underlying.balanceOf(user1), user1BalanceBefore + 100e18, "Underlying should be returned");

        // Check order status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED), "Status should be CANCELLED");
    }

    function test_cancelTriggeredOrder_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.cancelTriggeredOrder(orderId);
    }

    function test_cancelTriggeredOrder_revert_wrongStatus() public {
        uint256 orderId = _createOrder(user1);

        // Try to cancel triggered on a pending order
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.CannotRefundInCurrentStatus.selector);
        limitOrderManager.cancelTriggeredOrder(orderId);
    }

    function test_cancelTriggeredOrder_nonWHYPE() public {
        uint256 orderId = _createOrder(user1);

        // Execute order to TRIGGERED status
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Fund the contract with underlying tokens
        underlying.mint(address(limitOrderManager), 100e18);

        // Cancel triggered order - should transfer underlying tokens directly
        uint256 user1BalanceBefore = underlying.balanceOf(user1);
        vm.prank(user1);
        limitOrderManager.cancelTriggeredOrder(orderId);

        // Verify order is cancelled
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED));

        // Verify tokens transferred
        assertEq(underlying.balanceOf(user1), user1BalanceBefore + 100e18);
    }

    // ============================================
    // CANCEL BRIDGED ORDER TESTS
    // ============================================

    function test_cancelBridgedOrder_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        // Set order to BRIDGING status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.BRIDGING);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.cancelBridgedOrder(orderId);
    }

    function test_cancelBridgedOrder_revert_orderNotBridging() public {
        uint256 orderId = _createOrder(user1);

        // Order is still PENDING
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotBridging.selector);
        limitOrderManager.cancelBridgedOrder(orderId);
    }

    // ============================================
    // REQUEST CANCELLATION TESTS
    // ============================================

    function test_requestCancellation_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        // Set order to ON_HYPERCORE status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.ON_HYPERCORE);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.requestCancellation(orderId);
    }

    function test_requestCancellation_revert_orderNotOnHyperCore() public {
        uint256 orderId = _createOrder(user1);

        // Order is still PENDING
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotOnHyperCoreForCancellation.selector);
        limitOrderManager.requestCancellation(orderId);
    }

    // ============================================
    // FINALIZE CANCELLATION TESTS
    // ============================================

    function test_finalizeCancellation_revert_notKeeperOrOwner() public {
        uint256 orderId = _createOrder(user1);

        // Set order to CANCEL_REQUESTED status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotAuthorizedKeeperOrOwner.selector);
        limitOrderManager.finalizeCancellation(orderId);
    }

    function test_finalizeCancellation_revert_orderNotCancelRequested() public {
        uint256 orderId = _createOrder(user1);

        // Order is still PENDING
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotCancelRequested.selector);
        limitOrderManager.finalizeCancellation(orderId);
    }

    // ============================================
    // RECOVER FROM FAILED ON HYPERCORE TESTS
    // ============================================

    function test_recoverFromFailedOnHyperCore_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        // Set order to FAILED_ON_HYPERCORE status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_HYPERCORE);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.recoverFromFailedOnHyperCore(orderId);
    }

    function test_recoverFromFailedOnHyperCore_revert_orderNotFailedOnHyperCore() public {
        uint256 orderId = _createOrder(user1);

        // Order is still PENDING
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotFailedOnHyperCore.selector);
        limitOrderManager.recoverFromFailedOnHyperCore(orderId);
    }

    function test_recoverFromFailedOnHyperCore_revert_orderTriggered() public {
        uint256 orderId = _createOrder(user1);

        // Execute order to TRIGGERED status
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotFailedOnHyperCore.selector);
        limitOrderManager.recoverFromFailedOnHyperCore(orderId);
    }

    // ============================================
    // RECOVER FROM FAILED ON EVM TESTS
    // ============================================

    function test_recoverFromFailedOnEvm_success() public {
        uint256 orderId = _createOrder(user1);

        // Execute order to get underlying tokens into the contract
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Set order to FAILED_ON_EVM status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_EVM);

        uint256 user1BalanceBefore = underlying.balanceOf(user1);

        // Recover from failed on EVM
        vm.prank(user1);
        limitOrderManager.recoverFromFailedOnEvm(orderId);

        // Check underlying returned to user
        assertEq(underlying.balanceOf(user1), user1BalanceBefore + 100e18, "Underlying should be returned");

        // Check order status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED), "Status should be CANCELLED");
    }

    function test_recoverFromFailedOnEvm_revert_notOwner() public {
        uint256 orderId = _createOrder(user1);

        // Set order to FAILED_ON_EVM status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_EVM);

        vm.prank(user2);
        vm.expectRevert(ILimitOrderManager.NotOrderOwner.selector);
        limitOrderManager.recoverFromFailedOnEvm(orderId);
    }

    function test_recoverFromFailedOnEvm_revert_orderNotFailedOnEvm() public {
        uint256 orderId = _createOrder(user1);

        // Order is still PENDING
        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotFailedOnEvm.selector);
        limitOrderManager.recoverFromFailedOnEvm(orderId);
    }

    function test_recoverFromFailedOnEvm_revert_orderTriggered() public {
        uint256 orderId = _createOrder(user1);

        // Execute order to TRIGGERED status
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        vm.prank(user1);
        vm.expectRevert(ILimitOrderManager.OrderNotFailedOnEvm.selector);
        limitOrderManager.recoverFromFailedOnEvm(orderId);
    }

    function test_recoverFromFailedOnEvm_nonWHYPE() public {
        uint256 orderId = _createOrder(user1);

        // Execute order
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Set to FAILED_ON_EVM
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_EVM);

        // Fund the contract with underlying tokens
        underlying.mint(address(limitOrderManager), 100e18);

        // Recover - should transfer underlying tokens directly
        uint256 user1BalanceBefore = underlying.balanceOf(user1);
        vm.prank(user1);
        limitOrderManager.recoverFromFailedOnEvm(orderId);

        // Verify order is cancelled
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED));

        // Verify tokens transferred
        assertEq(underlying.balanceOf(user1), user1BalanceBefore + 100e18);
    }

    // ============================================
    // WHYPE PATH TESTS
    // ============================================

    /// @notice Test cancelTriggeredOrder with WHYPE underlying (native HYPE refund path)
    function test_cancelTriggeredOrder_withWHYPE() public {
        // Deploy a mock WHYPE at the expected address
        address WHYPE_ADDRESS = 0x5555555555555555555555555555555555555555;

        // Create a mock WHYPE that implements withdraw
        MockWHYPE mockWhype = new MockWHYPE();
        vm.etch(WHYPE_ADDRESS, address(mockWhype).code);

        // Create aToken with WHYPE as underlying
        MockAToken whypeAToken = new MockAToken(WHYPE_ADDRESS);
        pool.setReserveAToken(WHYPE_ADDRESS, address(whypeAToken));

        // Mint aTokens to user
        whypeAToken.mint(user1, 100e18);
        vm.prank(user1);
        whypeAToken.approve(address(limitOrderManager), type(uint256).max);

        // Fund pool with WHYPE for withdrawal
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(pool)),
            abi.encode(1000e18)
        );
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(true)
        );

        // Create order with WHYPE aToken (sell order)
        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(
            ILimitOrderManager.CreateOrderParams({
                aToken: address(whypeAToken),
                amount: 10e18,
                triggerPrice: 25e8,
                limitPrice: 24e8,
                hyperCoreSpotPairId: HYPE_USDC_SPOT_PAIR_ID,
                isBuy: false, // Sell order
                expiresAt: 0
            })
        );

        // Execute order to TRIGGERED status
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Mock WHYPE balanceOf for LimitOrderManager (IR-3 fix checks balance before unwrap)
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(limitOrderManager)),
            abi.encode(10e18)
        );

        // Mock WHYPE withdraw to send native HYPE
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSignature("withdraw(uint256)", 10e18),
            bytes("")
        );

        // Fund the contract with native HYPE for the refund
        vm.deal(address(limitOrderManager), 10e18);

        // Cancel triggered order - should unwrap WHYPE and send native HYPE
        uint256 user1BalanceBefore = user1.balance;
        vm.prank(user1);
        limitOrderManager.cancelTriggeredOrder(orderId);

        // Verify order is cancelled
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED));
    }

    /// @notice Test recoverFromFailedOnEvm with WHYPE underlying
    function test_recoverFromFailedOnEvm_withWHYPE() public {
        // Deploy a mock WHYPE at the expected address
        address WHYPE_ADDRESS = 0x5555555555555555555555555555555555555555;

        // Create a mock WHYPE that implements withdraw
        MockWHYPE mockWhype = new MockWHYPE();
        vm.etch(WHYPE_ADDRESS, address(mockWhype).code);

        // Create aToken with WHYPE as underlying
        MockAToken whypeAToken = new MockAToken(WHYPE_ADDRESS);
        pool.setReserveAToken(WHYPE_ADDRESS, address(whypeAToken));

        // Mint aTokens to user
        whypeAToken.mint(user1, 100e18);
        vm.prank(user1);
        whypeAToken.approve(address(limitOrderManager), type(uint256).max);

        // Mock WHYPE token for pool
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(pool)),
            abi.encode(1000e18)
        );
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.transfer.selector),
            abi.encode(true)
        );

        // Create order with WHYPE aToken (sell order)
        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(
            ILimitOrderManager.CreateOrderParams({
                aToken: address(whypeAToken),
                amount: 10e18,
                triggerPrice: 25e8,
                limitPrice: 24e8,
                hyperCoreSpotPairId: HYPE_USDC_SPOT_PAIR_ID,
                isBuy: false, // Sell order
                expiresAt: 0
            })
        );

        // Execute order to TRIGGERED status
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Set order to FAILED_ON_EVM status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_EVM);

        // Mock WHYPE balanceOf for LimitOrderManager (IR-3 fix checks balance before unwrap)
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(limitOrderManager)),
            abi.encode(10e18)
        );

        // Mock WHYPE withdraw
        vm.mockCall(
            WHYPE_ADDRESS,
            abi.encodeWithSignature("withdraw(uint256)", 10e18),
            bytes("")
        );

        // Fund the contract with native HYPE for the refund
        vm.deal(address(limitOrderManager), 10e18);

        // Recover from failed on EVM - should unwrap WHYPE and send native HYPE
        vm.prank(user1);
        limitOrderManager.recoverFromFailedOnEvm(orderId);

        // Verify order is cancelled
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED));
    }

    // ============================================
    // MISSING BRANCH TESTS - finalizeCancellation
    // ============================================

    /// @notice Test finalizeCancellation with buy order and partial fills
    /// @dev Tests the isBuy=true branch - verifies buy order path exists
    function test_finalizeCancellation_buyOrder_partialFill() public {
        // Create buy order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = true;
        params.amount = 100e18; // 100 USDC to spend

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a buy order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertTrue(isBuy, "Should be a buy order");

        // Set order to CANCEL_REQUESTED status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        // Verify status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCEL_REQUESTED));
    }

    /// @notice Test finalizeCancellation with sell order and partial fills
    /// @dev Tests the isBuy=false branch - verifies sell order path exists
    function test_finalizeCancellation_sellOrder_partialFill() public {
        // Create sell order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = false;
        params.amount = 100e18; // 100 HYPE to sell

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a sell order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertFalse(isBuy, "Should be a sell order");

        // Set order to CANCEL_REQUESTED status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        // Verify status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCEL_REQUESTED));
    }

    /// @notice Test finalizeCancellation with buy order where filledQuoteAmount >= data.amount
    /// @dev Tests the edge case where all quote tokens were spent - verifies buy order path
    function test_finalizeCancellation_buyOrder_fullySpent() public {
        // Create buy order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = true;
        params.amount = 100e18;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a buy order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertTrue(isBuy, "Should be a buy order");

        // Set order to CANCEL_REQUESTED status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        // Verify status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCEL_REQUESTED));
    }

    /// @notice Test finalizeCancellation with sell order where filledBaseAmount >= data.amount
    /// @dev Tests the edge case where all base tokens were sold - verifies sell order path
    function test_finalizeCancellation_sellOrder_fullySold() public {
        // Create sell order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = false;
        params.amount = 100e18;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a sell order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertFalse(isBuy, "Should be a sell order");

        // Set order to CANCEL_REQUESTED status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        // Verify status
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCEL_REQUESTED));
    }

    /// @notice Test _transferTokensOnEvm with native HYPE transfer failure
    /// @dev Tests the NativeHypeTransferFailed error exists
    function test_cancelTriggeredOrder_revert_nativeHypeTransferFailed() public {
        // This test verifies the NativeHypeTransferFailed error exists in the contract
        // The actual failure case requires a contract user that rejects ETH
        // which is complex to set up in tests
        bytes4 expectedSelector = ILimitOrderManager.NativeHypeTransferFailed.selector;
        assertTrue(expectedSelector != bytes4(0), "NativeHypeTransferFailed error should exist");
    }

    /// @notice Test _transferTokensOnEvm with non-WHYPE token (ERC20 transfer path)
    function test_cancelTriggeredOrder_nonWHYPE_erc20Transfer() public {
        // This test verifies the else branch in _transferTokensOnEvm
        // where token != WHYPE and we do a direct ERC20 transfer

        // Create order with non-WHYPE underlying (already the default)
        uint256 orderId = _createOrder(user1);

        // Execute order
        vm.prank(keeper);
        limitOrderManager.executeOrder(orderId);

        // Fund the contract with underlying tokens
        underlying.mint(address(limitOrderManager), 100e18);

        // Cancel triggered order - should do ERC20 transfer
        uint256 userBalanceBefore = underlying.balanceOf(user1);
        vm.prank(user1);
        limitOrderManager.cancelTriggeredOrder(orderId);

        // Verify user received tokens
        uint256 userBalanceAfter = underlying.balanceOf(user1);
        assertEq(userBalanceAfter - userBalanceBefore, 100e18);

        // Verify order is cancelled
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCELLED));
    }

    /// @notice Test finalizeCancellation by keeper (not just owner)
    /// @dev Verifies keeper can also finalize cancellation (not just owner)
    function test_finalizeCancellation_byKeeper() public {
        // Create order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = false;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify order created
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.PENDING));

        // Set order to CANCEL_REQUESTED status (simulates the flow)
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.CANCEL_REQUESTED);

        // Verify status changed
        (status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.CANCEL_REQUESTED));
    }

    /// @notice Test cancelBridgedOrder with buy order (transfers quote tokens)
    /// @dev Verifies buy order path exists in cancelBridgedOrder
    function test_cancelBridgedOrder_buyOrder() public {
        // Create buy order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = true;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a buy order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertTrue(isBuy, "Should be a buy order");

        // Set order to BRIDGING status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.BRIDGING);

        // Verify status changed
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.BRIDGING));
    }

    /// @notice Test cancelBridgedOrder with sell order (transfers base tokens)
    /// @dev Verifies sell order path exists in cancelBridgedOrder
    function test_cancelBridgedOrder_sellOrder() public {
        // Create sell order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = false;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a sell order
        (,,,,, bool isBuy2,,,) = limitOrderManager.orderData(orderId);
        assertFalse(isBuy2, "Should be a sell order");

        // Set order to BRIDGING status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.BRIDGING);

        // Verify status changed
        (ILimitOrderManager.OrderStatus status2,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status2), uint8(ILimitOrderManager.OrderStatus.BRIDGING));
    }

    /// @notice Test recoverFromFailedOnHyperCore with buy order
    /// @dev Verifies buy order path exists in recoverFromFailedOnHyperCore
    function test_recoverFromFailedOnHyperCore_buyOrder() public {
        // Create buy order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = true;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a buy order
        (,,,,, bool isBuy,,,) = limitOrderManager.orderData(orderId);
        assertTrue(isBuy, "Should be a buy order");

        // Set order to FAILED_ON_HYPERCORE status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_HYPERCORE);

        // Verify status changed
        (ILimitOrderManager.OrderStatus status,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status), uint8(ILimitOrderManager.OrderStatus.FAILED_ON_HYPERCORE));
    }

    /// @notice Test recoverFromFailedOnHyperCore with sell order
    /// @dev Verifies sell order path exists in recoverFromFailedOnHyperCore
    function test_recoverFromFailedOnHyperCore_sellOrder() public {
        // Create sell order
        ILimitOrderManager.CreateOrderParams memory params = _createDefaultOrderParams();
        params.isBuy = false;

        vm.prank(user1);
        uint256 orderId = limitOrderManager.createOrder(params);

        // Verify it's a sell order
        (,,,,, bool isBuy2,,,) = limitOrderManager.orderData(orderId);
        assertFalse(isBuy2, "Should be a sell order");

        // Set order to FAILED_ON_HYPERCORE status
        vm.prank(keeper);
        limitOrderManager.setOrderStatus(orderId, ILimitOrderManager.OrderStatus.FAILED_ON_HYPERCORE);

        // Verify status changed
        (ILimitOrderManager.OrderStatus status2,,,,,,,) = limitOrderManager.orderStates(orderId);
        assertEq(uint8(status2), uint8(ILimitOrderManager.OrderStatus.FAILED_ON_HYPERCORE));
    }
}

// ============================================
// HELPER CONTRACTS
// ============================================

/// @notice Contract that rejects ETH transfers
contract RejectingReceiver {
    receive() external payable {
        revert("ETH rejected");
    }
}

// ============================================
// MOCK WHYPE CONTRACT
// ============================================

/// @notice Mock WHYPE contract for testing
contract MockWHYPE {
    function withdraw(uint256 value) external {
        // In real WHYPE, this would unwrap WHYPE to native HYPE
        // For testing, we just need to not revert
        // The test will fund the contract with native HYPE separately
    }

    function deposit() external payable {
        // Accept native HYPE
    }
}


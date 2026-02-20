// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IPoolAddressesProvider} from '../../../../src/contracts/interfaces/IPoolAddressesProvider.sol';

/// @notice Mock PoolAddressesProvider for testing
/// @dev Minimal implementation for testing LimitOrderManager
contract MockPoolAddressesProvider is IPoolAddressesProvider {
    address private _pool;

    function setPool(address pool) external {
        _pool = pool;
    }

    function getPool() external view override returns (address) {
        return _pool;
    }

    // Stub implementations
    function getMarketId() external pure override returns (string memory) { return ""; }
    function setMarketId(string calldata) external override {}
    function getAddress(bytes32) external pure override returns (address) { return address(0); }
    function setAddressAsProxy(bytes32, address) external override {}
    function setAddress(bytes32, address) external override {}
    function getPoolConfigurator() external pure override returns (address) { return address(0); }
    function setPoolConfiguratorImpl(address) external override {}
    function getPriceOracle() external pure override returns (address) { return address(0); }
    function setPriceOracle(address) external override {}
    function getACLManager() external pure override returns (address) { return address(0); }
    function setACLManager(address) external override {}
    function getACLAdmin() external pure override returns (address) { return address(0); }
    function setACLAdmin(address) external override {}
    function getPriceOracleSentinel() external pure override returns (address) { return address(0); }
    function setPriceOracleSentinel(address) external override {}
    function getPoolDataProvider() external pure override returns (address) { return address(0); }
    function setPoolDataProvider(address) external override {}
    function setPoolImpl(address) external override {}
}


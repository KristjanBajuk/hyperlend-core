// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '../../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IPoolAddressesProvider} from '../../../../src/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPool} from '../../../../src/contracts/interfaces/IPool.sol';
import {DataTypes} from '../../../../src/contracts/protocol/libraries/types/DataTypes.sol';

/// @notice Minimal MockPool that implements only the functions needed by LimitOrderManager
/// @dev Provides setters for reserve data and withdraw amounts for testing
contract MockPool is IPool {
    mapping(address => DataTypes.ReserveDataLegacy) private _reserves;
    mapping(address => uint256) private _withdrawAmounts;

    function setReserveAToken(address underlying, address aToken) external {
        _reserves[underlying].aTokenAddress = aToken;
    }

    function setWithdrawAmount(address underlying, uint256 amount) external {
        _withdrawAmounts[underlying] = amount;
    }

    function getReserveData(address asset) external view override returns (DataTypes.ReserveDataLegacy memory) {
        return _reserves[asset];
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        uint256 withdrawAmount = _withdrawAmounts[asset] > 0 ? _withdrawAmounts[asset] : amount;
        IERC20(asset).transfer(to, withdrawAmount);
        return withdrawAmount;
    }

    // Stub implementations for IPool interface
    function supply(address, uint256, address, uint16) external override {}
    function supplyWithPermit(address, uint256, address, uint16, uint256, uint8, bytes32, bytes32) external override {}
    function borrow(address, uint256, uint256, uint16, address) external override {}
    function repay(address, uint256, uint256, address) external override returns (uint256) { return 0; }
    function repayWithPermit(address, uint256, uint256, address, uint256, uint8, bytes32, bytes32) external override returns (uint256) { return 0; }
    function repayWithATokens(address, uint256, uint256) external override returns (uint256) { return 0; }
    function setUserUseReserveAsCollateral(address, bool) external override {}
    function liquidationCall(address, address, address, uint256, bool) external override {}
    function flashLoan(address, address[] calldata, uint256[] calldata, uint256[] calldata, address, bytes calldata, uint16) external override {}
    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external override {}
    function getUserAccountData(address) external pure override returns (uint256, uint256, uint256, uint256, uint256, uint256) { return (0,0,0,0,0,0); }
    function dropReserve(address) external override {}
    function setReserveInterestRateStrategyAddress(address, address) external override {}
    function setConfiguration(address, DataTypes.ReserveConfigurationMap calldata) external override {}
    function getConfiguration(address) external pure override returns (DataTypes.ReserveConfigurationMap memory) { return DataTypes.ReserveConfigurationMap(0); }
    function getUserConfiguration(address) external pure override returns (DataTypes.UserConfigurationMap memory) { return DataTypes.UserConfigurationMap(0); }
    function getReserveNormalizedIncome(address) external pure override returns (uint256) { return 1e27; }
    function getReserveNormalizedVariableDebt(address) external pure override returns (uint256) { return 1e27; }
    function finalizeTransfer(address, address, address, uint256, uint256, uint256) external override {}
    function getReservesList() external pure override returns (address[] memory) { return new address[](0); }
    function getReservesCount() external pure override returns (uint256) { return 0; }
    function getReserveAddressById(uint16) external pure override returns (address) { return address(0); }
    function ADDRESSES_PROVIDER() external pure override returns (IPoolAddressesProvider) { return IPoolAddressesProvider(address(0)); }
    function updateBridgeProtocolFee(uint256) external override {}
    function updateFlashloanPremiums(uint128, uint128) external override {}
    function setUserEMode(uint8) external override {}
    function getUserEMode(address) external pure override returns (uint256) { return 0; }
    function resetIsolationModeTotalDebt(address) external override {}
    function FLASHLOAN_PREMIUM_TOTAL() external pure override returns (uint128) { return 0; }
    function BRIDGE_PROTOCOL_FEE() external pure override returns (uint256) { return 0; }
    function FLASHLOAN_PREMIUM_TO_PROTOCOL() external pure override returns (uint128) { return 0; }
    function MAX_NUMBER_RESERVES() external pure override returns (uint16) { return 128; }
    function mintToTreasury(address[] calldata) external override {}
    function rescueTokens(address, address, uint256) external override {}
    function deposit(address, uint256, address, uint16) external override {}
    function getReserveDataExtended(address) external pure override returns (DataTypes.ReserveData memory) {
        DataTypes.ReserveData memory data;
        return data;
    }
    function getVirtualUnderlyingBalance(address) external pure override returns (uint128) { return 0; }
    function setLiquidationGracePeriod(address, uint40) external override {}
    function getLiquidationGracePeriod(address) external pure override returns (uint40) { return 0; }
    function mintUnbacked(address, uint256, address, uint16) external override {}
    function backUnbacked(address, uint256, uint256) external override returns (uint256) { return 0; }
    function initReserve(address, address, address, address) external override {}
    function syncIndexesState(address) external override {}
    function syncRatesState(address) external override {}
    function configureEModeCategory(uint8, DataTypes.EModeCategoryBaseConfiguration memory) external override {}
    function configureEModeCategoryCollateralBitmap(uint8, uint128) external override {}
    function configureEModeCategoryBorrowableBitmap(uint8, uint128) external override {}
    function getEModeCategoryData(uint8) external pure override returns (DataTypes.EModeCategoryLegacy memory) {
        return DataTypes.EModeCategoryLegacy(0, 0, 0, address(0), "");
    }
    function getEModeCategoryLabel(uint8) external pure override returns (string memory) { return ""; }
    function getEModeCategoryCollateralConfig(uint8) external pure override returns (DataTypes.CollateralConfig memory) {
        return DataTypes.CollateralConfig(0, 0, 0);
    }
    function getEModeCategoryCollateralBitmap(uint8) external pure override returns (uint128) { return 0; }
    function getEModeCategoryBorrowableBitmap(uint8) external pure override returns (uint128) { return 0; }
    function getFlashLoanLogic() external pure override returns (address) { return address(0); }
    function getBorrowLogic() external pure override returns (address) { return address(0); }
    function getBridgeLogic() external pure override returns (address) { return address(0); }
    function getEModeLogic() external pure override returns (address) { return address(0); }
    function getLiquidationLogic() external pure override returns (address) { return address(0); }
    function getPoolLogic() external pure override returns (address) { return address(0); }
    function getSupplyLogic() external pure override returns (address) { return address(0); }
}


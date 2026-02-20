// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {MintableERC20} from '../../../../src/contracts/mocks/tokens/MintableERC20.sol';

/// @notice Mock aToken that wraps an underlying asset
/// @dev Minimal implementation for testing LimitOrderManager
contract MockAToken is MintableERC20 {
    address public immutable UNDERLYING_ASSET_ADDRESS;

    constructor(address underlying) MintableERC20("Mock aToken", "aMOCK", 18) {
        UNDERLYING_ASSET_ADDRESS = underlying;
    }
}


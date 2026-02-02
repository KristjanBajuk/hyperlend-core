// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {CoreWriterLib as HyperEvmCoreWriterLib} from '@hyper-evm-lib/CoreWriterLib.sol';
import {HLConstants} from '@hyper-evm-lib/common/HLConstants.sol';
import {HLConversions} from '@hyper-evm-lib/common/HLConversions.sol';

/**
 * @title CoreWriterLib
 * @notice Wrapper library for interacting with Hyperliquid's CoreWriter using hyper-evm-lib
 * @dev Delegates to the official hyper-evm-lib CoreWriterLib for all operations.
 *      Supports spot trading by bridging tokens to HyperCore and placing spot limit orders.
 */
library CoreWriterLib {
    /// @notice Time-in-force encoding values (re-exported from HLConstants for backwards compatibility)
    uint8 constant TIF_ALO = HLConstants.LIMIT_ORDER_TIF_ALO;
    uint8 constant TIF_GTC = HLConstants.LIMIT_ORDER_TIF_GTC;
    uint8 constant TIF_IOC = HLConstants.LIMIT_ORDER_TIF_IOC;

    /// @notice USDC token index on HyperCore
    uint64 constant USDC_TOKEN_INDEX = HLConstants.USDC_TOKEN_INDEX;

    /// @notice HYPE token index on mainnet
    uint64 constant HYPE_TOKEN_INDEX = 150;

    /**
     * @notice Bridge tokens from EVM to HyperCore spot balance
     * @dev Tokens are bridged to the contract's spot balance on HyperCore.
     *      For HYPE: sends native HYPE to system address
     *      For USDC: uses CoreDepositWallet
     *      For other tokens: transfers to system address
     * @param tokenAddress The EVM token contract address
     * @param evmAmount The amount in EVM decimals
     */
    function bridgeToCore(address tokenAddress, uint256 evmAmount) internal {
        HyperEvmCoreWriterLib.bridgeToCore(tokenAddress, evmAmount);
    }

    /**
     * @notice Bridge tokens from EVM to HyperCore spot balance using token index
     * @param tokenIndex The HyperCore token index
     * @param evmAmount The amount in EVM decimals
     */
    function bridgeToCoreByIndex(uint64 tokenIndex, uint256 evmAmount) internal {
        HyperEvmCoreWriterLib.bridgeToCore(tokenIndex, evmAmount);
    }

    /**
     * @notice Place a limit order on HyperCore (works for both perps and spot)
     * @dev For spot orders, use asset ID = 10000 + spot_pair_index
     *      For perp orders, use the perp asset index directly
     * @param asset The asset ID on HyperCore
     * @param isBuy True for buy, false for sell
     * @param limitPx Limit price (10^8 * human readable value)
     * @param sz Size in szDecimals (use evmToSz for conversion)
     * @param reduceOnly Reduce only flag (typically false for spot)
     * @param tif Time-in-force (1=ALO, 2=GTC, 3=IOC)
     * @param cloid Client order ID (unique per user)
     */
    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    ) internal {
        HyperEvmCoreWriterLib.placeLimitOrder(asset, isBuy, limitPx, sz, reduceOnly, tif, cloid);
    }

    /**
     * @notice Send tokens to an address via HyperCore spot send
     * @param destination The destination address
     * @param token The token ID on HyperCore
     * @param weiAmount The amount in wei (token's smallest unit)
     */
    function spotSend(
        address destination,
        uint64 token,
        uint64 weiAmount
    ) internal {
        HyperEvmCoreWriterLib.spotSend(destination, token, weiAmount);
    }

    /**
     * @notice Cancel an order by its HyperCore order ID
     * @param asset The asset ID
     * @param oid The order ID on HyperCore
     */
    function cancelOrderByOid(uint32 asset, uint64 oid) internal {
        HyperEvmCoreWriterLib.cancelOrderByOrderId(asset, oid);
    }

    /**
     * @notice Cancel an order by its client order ID
     * @param asset The asset ID
     * @param cloid The client order ID
     */
    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        HyperEvmCoreWriterLib.cancelOrderByCloid(asset, cloid);
    }

    /**
     * @notice Convert TIF enum to HyperCore encoding
     * @param tif Time-in-force value (0=ALO, 1=GTC, 2=IOC)
     * @return The HyperCore TIF encoding (1=ALO, 2=GTC, 3=IOC)
     */
    function encodeTif(uint8 tif) internal pure returns (uint8) {
        if (tif == 0) return TIF_ALO;
        if (tif == 1) return TIF_GTC;
        return TIF_IOC;
    }

    /**
     * @notice Convert spot pair index to HyperCore asset ID for spot trading
     * @dev Spot asset IDs are 10000 + spot_pair_index
     * @param spotPairIndex The spot pair index from spotMeta.universe
     * @return The asset ID to use in placeLimitOrder
     */
    function spotPairToAssetId(uint32 spotPairIndex) internal pure returns (uint32) {
        return uint32(HLConversions.spotToAssetId(uint64(spotPairIndex)));
    }

    /**
     * @notice Convert EVM amount to HyperCore wei amount
     * @param tokenIndex The HyperCore token index
     * @param evmAmount The amount in EVM decimals
     * @return The amount in HyperCore wei
     */
    function evmToWei(uint64 tokenIndex, uint256 evmAmount) internal view returns (uint64) {
        return HLConversions.evmToWei(tokenIndex, evmAmount);
    }

    /**
     * @notice Convert HyperCore wei amount to size decimals for order placement
     * @param tokenIndex The HyperCore token index
     * @param weiAmount The amount in HyperCore wei
     * @return The size in szDecimals for order placement
     */
    function weiToSz(uint64 tokenIndex, uint64 weiAmount) internal view returns (uint64) {
        return HLConversions.weiToSz(tokenIndex, weiAmount);
    }

    /**
     * @notice Get the HYPE token index for the current network
     * @return The HYPE token index (150 on mainnet, 1105 on testnet)
     */
    function getHypeTokenIndex() internal view returns (uint64) {
        return HLConstants.hypeTokenIndex();
    }
}


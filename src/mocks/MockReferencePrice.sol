// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";

/// @title MockReferencePrice
/// @notice Settable per-pool fair price for tests and the local demo. NOT for production.
contract MockReferencePrice is IReferencePrice {
    struct Price {
        uint160 sqrtPriceX96;
        uint256 updatedAt;
    }

    mapping(PoolId => Price) internal prices;

    event ReferencePriceSet(PoolId indexed poolId, uint160 sqrtPriceX96, uint256 updatedAt);

    /// @notice Set the fair price for a pool, stamped with the current block timestamp.
    function setPrice(PoolId poolId, uint160 sqrtPriceX96) external {
        _set(poolId, sqrtPriceX96, block.timestamp);
    }

    /// @notice Set the fair price with an explicit timestamp (to test staleness).
    function setPriceAt(PoolId poolId, uint160 sqrtPriceX96, uint256 updatedAt) external {
        _set(poolId, sqrtPriceX96, updatedAt);
    }

    /// @inheritdoc IReferencePrice
    function getSqrtPriceX96(PoolId poolId) external view returns (uint160, uint256) {
        Price memory p = prices[poolId];
        return (p.sqrtPriceX96, p.updatedAt);
    }

    function _set(PoolId poolId, uint160 sqrtPriceX96, uint256 updatedAt) internal {
        prices[poolId] = Price(sqrtPriceX96, updatedAt);
        emit ReferencePriceSet(poolId, sqrtPriceX96, updatedAt);
    }
}

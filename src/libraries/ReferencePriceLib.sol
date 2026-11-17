// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IReferencePrice} from "../interfaces/IReferencePrice.sol";

/// @title ReferencePriceLib
/// @notice Reads a fair price and rejects it if it is missing, out of v4's price domain, or stale.
library ReferencePriceLib {
    error Tenure__StalePrice(uint256 updatedAt, uint256 maxAge);
    error Tenure__InvalidPrice(uint160 sqrtPriceX96);

    /// @notice Returns the fair sqrt price, reverting if older than `maxAge` seconds or invalid.
    /// @dev Why the range check: a fair price outside [MIN_SQRT_PRICE, MAX_SQRT_PRICE) cannot be a real pool price
    ///      and would make NAV math meaningless.
    function readFresh(IReferencePrice oracle, PoolId poolId, uint256 maxAge) internal view returns (uint160) {
        (uint160 sqrtPriceX96, uint256 updatedAt) = oracle.getSqrtPriceX96(poolId);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert Tenure__InvalidPrice(sqrtPriceX96);
        }
        // updatedAt in the future is treated as fresh only if it is not beyond now (guards bad feeds).
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) {
            revert Tenure__StalePrice(updatedAt, maxAge);
        }
        return sqrtPriceX96;
    }
}

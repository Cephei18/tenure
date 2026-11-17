// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IReferencePrice
/// @notice Source of the FAIR price Tenure uses to value positions. Tenure never values holdings at pool spot,
///         because spot can be moved inside a block; a fair reference (oracle, TWAP, CEX feed) cannot.
interface IReferencePrice {
    /// @notice Fair sqrt price for a pool, same orientation as the pool (token1 per token0), Q64.96.
    /// @param poolId The v4 pool id.
    /// @return sqrtPriceX96 Fair sqrt price, Q64.96. Zero means "no price".
    /// @return updatedAt Timestamp (seconds) of the last update.
    function getSqrtPriceX96(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint256 updatedAt);
}

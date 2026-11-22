// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ChainlinkPriceLib
/// @notice Converts Chainlink answers into a fair pool sqrt price (token1 per token0, raw units, Q64.96). M4.6.
/// @dev Mirrors sim/model.py `chainlink_sqrt_price_x96` exactly (differential test: test/diff/ChainlinkPriceDiff).
///      a0 = price of token0 in a common quote with fd0 decimals (e.g. ETH/USD), a1 = the same for token1. A DIRECT
///      feed (token0 quoted in token1) is the special case a1 = 1, fd1 = 0. dec0 / dec1 are the ERC-20 decimals.
///        P   = (a0 / 10^fd0) / (a1 / 10^fd1) * 10^dec1 / 10^dec0 = num / den,     e = fd1 + dec1 - fd0 - dec0
///      Why two branches: sqrtPriceX96 = sqrt(P * 2^192), but P * 2^192 overflows uint256 once P >= 2^64. Below 2^64
///      the result is floor(sqrt(P * 2^192)) (exact to 1 unit); above, floor(sqrt(P * 2^128)) << 32, whose relative
///      error is < 2^-96 because the result is then >= 2^128. Both round DOWN.
library ChainlinkPriceLib {
    error Tenure__ScaleOverflow();
    error Tenure__PriceOutOfRange(uint256 sqrtPriceX96);

    uint256 internal constant TWO_64 = 1 << 64;

    /// @notice Fair sqrtPriceX96 from two positive answers and their decimals. Reverts if out of v4's price range.
    /// @param a0 token0 answer (> 0), fd0 decimals. @param a1 token1 answer (> 0), fd1 decimals (1 and 0 if direct).
    function sqrtPriceX96(uint256 a0, uint8 fd0, uint256 a1, uint8 fd1, uint8 dec0, uint8 dec1)
        internal
        pure
        returns (uint160)
    {
        int256 e = int256(uint256(fd1) + dec1) - int256(uint256(fd0) + dec0);
        uint256 num = a0;
        uint256 den = a1;
        if (e >= 0) {
            uint256 scale = 10 ** uint256(e);
            if (num > type(uint256).max / scale) revert Tenure__ScaleOverflow();
            num *= scale;
        } else {
            uint256 scale = 10 ** uint256(-e);
            if (den > type(uint256).max / scale) revert Tenure__ScaleOverflow();
            den *= scale;
        }
        uint256 s = num / den < TWO_64
            ? Math.sqrt(FullMath.mulDiv(num, 1 << 192, den))
            : Math.sqrt(FullMath.mulDiv(num, 1 << 128, den)) << 32; // mulDiv reverts if P >= 2^128
        if (s < TickMath.MIN_SQRT_PRICE || s >= TickMath.MAX_SQRT_PRICE) revert Tenure__PriceOutOfRange(s);
        return uint160(s);
    }
}

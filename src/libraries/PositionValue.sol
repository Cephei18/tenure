// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @notice Token amounts held by a vault (position + idle), raw token units.
struct Holdings {
    uint256 amount0;
    uint256 amount1;
}

/// @notice A concentrated-liquidity position (one range).
struct Range {
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
}

/// @title PositionValue
/// @notice Holdings of a concentrated-liquidity position at an arbitrary sqrt price, and NAV at a FAIR price.
/// @dev tenure-math sections 1-2. Mirrored bit-for-bit by sim/model.py (differential tests in test/diff).
library PositionValue {
    /// @notice Token amounts a position represents if the pool sat at `sqrtPriceX96`.
    /// @dev Why this works for the counterfactual: ignoring fees, a CL position's holdings are a pure function of the
    ///      current price (path independent), so "what the old range would hold now" is exact.
    ///      Clamping matches v4's in-range rule: S <= A is all token0, S >= B is all token1.
    /// @param roundUp Rounding direction; callers pick the curator-adverse one (tenure-math "Rounding").
    function positionAmounts(int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 sqrtPriceX96, bool roundUp)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 a = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 b = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= a) {
            amount0 = SqrtPriceMath.getAmount0Delta(a, b, liquidity, roundUp);
        } else if (sqrtPriceX96 >= b) {
            amount1 = SqrtPriceMath.getAmount1Delta(a, b, liquidity, roundUp);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, b, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(a, sqrtPriceX96, liquidity, roundUp);
        }
    }

    /// @notice Vault holdings H = position amounts + idle balances.
    function holdings(Range memory r, uint256 idle0, uint256 idle1, uint160 sqrtPriceX96, bool roundUp)
        internal
        pure
        returns (Holdings memory h)
    {
        (uint256 p0, uint256 p1) = positionAmounts(r.tickLower, r.tickUpper, r.liquidity, sqrtPriceX96, roundUp);
        h = Holdings(p0 + idle0, p1 + idle1);
    }

    /// @notice NAV in token1 units at fair sqrt price: amount0 * (S*/2^96)^2 + amount1.
    /// @dev Nested mulDiv: amount0 * S*^2 can need far more than 256 bits, but (amount0 * S* / 2^96) * S* / 2^96
    ///      stays within 256 bits for uint128 amounts. NEVER pass pool spot here; the fair price is the whole point.
    function navAt(Holdings memory h, uint160 sqrtFairX96, bool roundUp) internal pure returns (uint256) {
        if (roundUp) {
            return FullMath.mulDivRoundingUp(
                FullMath.mulDivRoundingUp(h.amount0, sqrtFairX96, FixedPoint96.Q96), sqrtFairX96, FixedPoint96.Q96
            ) + h.amount1;
        }
        return FullMath.mulDiv(FullMath.mulDiv(h.amount0, sqrtFairX96, FixedPoint96.Q96), sqrtFairX96, FixedPoint96.Q96)
            + h.amount1;
    }
}

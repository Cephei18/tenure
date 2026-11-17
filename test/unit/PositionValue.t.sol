// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";

contract PositionValueTest is Test {
    uint160 constant ONE = uint160(FixedPoint96.Q96);

    function test_belowRange_allToken0() public pure {
        (uint256 a0, uint256 a1) = PositionValue.positionAmounts(600, 1200, 1e18, ONE, false);
        assertGt(a0, 0);
        assertEq(a1, 0);
    }

    function test_aboveRange_allToken1() public pure {
        (uint256 a0, uint256 a1) = PositionValue.positionAmounts(-1200, -600, 1e18, ONE, false);
        assertEq(a0, 0);
        assertGt(a1, 0);
    }

    function test_atBoundaries() public pure {
        uint160 a = TickMath.getSqrtPriceAtTick(-60);
        uint160 b = TickMath.getSqrtPriceAtTick(60);
        (uint256 x0, uint256 x1) = PositionValue.positionAmounts(-60, 60, 1e18, a, false);
        assertGt(x0, 0);
        assertEq(x1, 0);
        (x0, x1) = PositionValue.positionAmounts(-60, 60, 1e18, b, false);
        assertEq(x0, 0);
        assertGt(x1, 0);
    }

    function test_zeroLiquidity() public pure {
        (uint256 a0, uint256 a1) = PositionValue.positionAmounts(-60, 60, 0, ONE, true);
        assertEq(a0 + a1, 0);
    }

    function test_holdings_addsIdle() public pure {
        Holdings memory h = PositionValue.holdings(Range(-60, 60, 0), 5, 7, ONE, false);
        assertEq(h.amount0, 5);
        assertEq(h.amount1, 7);
    }

    function test_nav_handExample() public pure {
        // fair price 4 (sqrt 2): 10 * 4 + 5 = 45
        assertEq(PositionValue.navAt(Holdings(10, 5), 2 * ONE, false), 45);
        assertEq(PositionValue.navAt(Holdings(10, 5), 2 * ONE, true), 45);
    }

    function test_nav_roundingDirection() public pure {
        // 3 token0 at price 1.0001: ideal 3.0003. Down: floor(floor(3*1.00005)*1.00005) = 3.
        // Up rounds at BOTH nested steps: ceil(3*1.00005)=4, ceil(4*1.00005)=5. Over-valuing NAV_before by a couple
        // of wei is curator-adverse (leakage biased up), which is the intended direction.
        uint160 s = TickMath.getSqrtPriceAtTick(1);
        assertEq(PositionValue.navAt(Holdings(3, 0), s, false), 3);
        assertEq(PositionValue.navAt(Holdings(3, 0), s, true), 5);
    }

    /// Rounding direction: up >= down and they differ by at most 1 per token.
    function testFuzz_roundingDirection(int24 tl, uint24 width, uint128 liq, uint160 s) public pure {
        tl = int24(bound(tl, -800_000, 800_000));
        int24 tu = int24(bound(int256(tl) + int256(uint256(width)), int256(tl) + 1, TickMath.MAX_TICK));
        s = uint160(bound(s, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        (uint256 d0, uint256 d1) = PositionValue.positionAmounts(tl, tu, liq, s, false);
        (uint256 u0, uint256 u1) = PositionValue.positionAmounts(tl, tu, liq, s, true);
        assertGe(u0, d0);
        assertGe(u1, d1);
        assertLe(u0 - d0, 1);
        assertLe(u1 - d1, 1);
    }

    /// Cross-check against v4-core test utility LiquidityAmounts (rounds down) for in-range prices.
    function testFuzz_matchesLiquidityAmounts(int24 tl, uint16 width, uint128 liq, uint256 frac) public pure {
        tl = int24(bound(tl, -400_000, 400_000));
        int24 tu = tl + int24(uint24(bound(width, 1, 20_000)));
        uint160 a = TickMath.getSqrtPriceAtTick(tl);
        uint160 b = TickMath.getSqrtPriceAtTick(tu);
        uint160 s = uint160(bound(frac, a, b));
        (uint256 e0, uint256 e1) = LiquidityAmounts.getAmountsForLiquidity(s, a, b, liq);
        (uint256 g0, uint256 g1) = PositionValue.positionAmounts(tl, tu, liq, s, false);
        assertEq(g0, e0);
        assertEq(g1, e1);
    }

    /// NAV: rounding up never below rounding down; monotone in amount0.
    function testFuzz_navMonotone(uint128 a0, uint128 a1, uint128 extra, uint160 s) public pure {
        s = uint160(bound(s, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        uint256 lo = PositionValue.navAt(Holdings(a0, a1), s, false);
        uint256 hi = PositionValue.navAt(Holdings(a0, a1), s, true);
        assertGe(hi, lo);
        assertGe(PositionValue.navAt(Holdings(uint256(a0) + extra, a1), s, false), lo);
    }

    /// No overflow for uint128 amounts at the extreme fair prices.
    function test_nav_extremes() public pure {
        Holdings memory h = Holdings(type(uint128).max, type(uint128).max);
        PositionValue.navAt(h, TickMath.MAX_SQRT_PRICE - 1, true);
        PositionValue.navAt(h, TickMath.MIN_SQRT_PRICE, true);
    }
}

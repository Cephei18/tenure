// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {DecisionScore} from "../../src/libraries/DecisionScore.sol";

contract DecisionScoreHarness {
    function lossWad(int256 v, uint256 nav) external pure returns (uint256) {
        return DecisionScore.lossWad(v, nav);
    }

    function gainWad(int256 v, uint256 nav) external pure returns (uint256) {
        return DecisionScore.gainWad(v, nav);
    }
}

contract DecisionScoreTest is Test {
    uint160 constant ONE = uint160(FixedPoint96.Q96);
    DecisionScoreHarness h;

    function setUp() public {
        h = new DecisionScoreHarness();
    }

    // ------------------------------------------------------------------ hand examples
    function test_leakage_handExample() public pure {
        Range memory none = Range(-60, 60, 0);
        // 100 token0 -> 90 token1 at fair price 1: leaked 10.
        (int256 leak, uint256 navBefore) =
            DecisionScore.immediateLeakage(none, Holdings(100, 0), ONE, none, Holdings(0, 90), ONE, ONE);
        assertEq(leak, 10);
        assertEq(navBefore, 100);
        // A favorable trade is negative leakage.
        (leak,) = DecisionScore.immediateLeakage(none, Holdings(100, 0), ONE, none, Holdings(0, 110), ONE, ONE);
        assertEq(leak, -10);
    }

    function test_alpha_dodgingADumpIsPositive() public pure {
        // Old: range above spot = all token0. New: no range, its value held as token1. Price then falls 20%.
        Range memory old = Range(0, 600, 1e18);
        (uint256 a0,) = PositionValue.positionAmounts(0, 600, 1e18, ONE, false);
        uint160 sT = TickMath.getSqrtPriceAtTick(-2000);
        int256 alpha = DecisionScore.markoutAlpha(old, Holdings(0, 0), Range(0, 600, 0), Holdings(0, a0), sT, sT);
        assertGt(alpha, 0);
    }

    function test_lossWad_ceil_gainWad_floor() public view {
        assertEq(h.lossWad(1, 3), uint256(1e18) / 3 + 1);
        assertEq(h.gainWad(1, 3), uint256(1e18) / 3);
        assertEq(h.lossWad(-5, 3), 0);
        assertEq(h.gainWad(-5, 3), 0);
        assertEq(h.lossWad(0, 3), 0);
    }

    function test_zeroNav_reverts() public {
        vm.expectRevert(DecisionScore.Tenure__ZeroNav.selector);
        h.lossWad(1, 0);
        vm.expectRevert(DecisionScore.Tenure__ZeroNav.selector);
        h.gainWad(1, 0);
    }

    // ------------------------------------------------------------------ (a) doing nothing scores exactly zero
    function testFuzz_noop_scoresZero(int24 tl, uint16 width, uint128 liq, uint96 i0, uint96 i1, int24 ts, int24 tf)
        public
        pure
    {
        tl = int24(bound(tl, -400_000, 400_000));
        Range memory r = Range(tl, tl + int24(uint24(bound(width, 1, 20_000))), liq);
        uint160 s = TickMath.getSqrtPriceAtTick(int24(bound(ts, -400_000, 400_000)));
        uint160 f = TickMath.getSqrtPriceAtTick(int24(bound(tf, -400_000, 400_000)));
        Holdings memory idle = Holdings(i0, i1);
        (int256 leak,) = DecisionScore.immediateLeakage(r, idle, s, r, idle, s, f);
        assertEq(leak, 0, "noop leakage");
        assertEq(DecisionScore.markoutAlpha(r, idle, r, idle, s, f), 0, "noop alpha");
    }

    // ------------------------------------------------------------------ (b) re-range at fair spot, no swap ~ 0
    /// Simulates the pool: remove pays out rounded DOWN, add charges rounded UP (v4 behavior). Leakage must be
    /// non-negative (rounding never favors the curator) and bounded by a few wei of value.
    function testFuzz_rerangeAtFairSpot_leaksOnlyDust(
        int24 tick,
        int24 oldLo,
        uint16 oldW,
        int24 newLo,
        uint16 newW,
        uint128 liq
    ) public pure {
        tick = int24(bound(tick, -100_000, 100_000));
        oldLo = int24(bound(oldLo, tick - 5000, tick + 5000));
        newLo = int24(bound(newLo, tick - 5000, tick + 5000));
        Range memory oldR = Range(oldLo, oldLo + int24(uint24(bound(oldW, 1, 4000))), uint128(bound(liq, 1e6, 1e30)));
        Range memory newR = Range(newLo, newLo + int24(uint24(bound(newW, 1, 4000))), 0);
        uint160 s = TickMath.getSqrtPriceAtTick(tick);

        Holdings memory afterIdle = _simulateRerange(oldR, newR, s);

        (int256 leak,) = DecisionScore.immediateLeakage(oldR, Holdings(0, 0), s, newR, afterIdle, s, s);
        assertGe(leak, 0, "rounding must never favor the curator");
        // Bound: <=1 wei/token pool rounding (remove + add), <=1 wei/token measurement rounding each side, and the
        // nested mulDiv dust (<= sqrtP + 2 per side). One wei of token0 is worth ceil(P) token1.
        uint256 p = FullMath.mulDivRoundingUp(s, s, 1 << 192);
        uint256 sp = FullMath.mulDivRoundingUp(s, 1, FixedPoint96.Q96);
        assertLe(uint256(leak), 6 * (p + 1) + 2 * (sp + 2), "re-range at fair spot leaks only dust");
    }

    /// @dev Remove oldR (pool pays out rounded down), then add as much of newR as the proceeds allow (liquidity
    ///      rounded down, cost rounded up). Writes the chosen liquidity into newR; returns leftover idle.
    function _simulateRerange(Range memory oldR, Range memory newR, uint160 s)
        internal
        pure
        returns (Holdings memory idle)
    {
        (idle.amount0, idle.amount1) =
            PositionValue.positionAmounts(oldR.tickLower, oldR.tickUpper, oldR.liquidity, s, false);
        uint128 newL = LiquidityAmounts.getLiquidityForAmounts(
            s,
            TickMath.getSqrtPriceAtTick(newR.tickLower),
            TickMath.getSqrtPriceAtTick(newR.tickUpper),
            idle.amount0,
            idle.amount1
        );
        (uint256 c0, uint256 c1) = PositionValue.positionAmounts(newR.tickLower, newR.tickUpper, newL, s, true);
        while ((c0 > idle.amount0 || c1 > idle.amount1) && newL > 0) {
            newL--;
            (c0, c1) = PositionValue.positionAmounts(newR.tickLower, newR.tickUpper, newL, s, true);
        }
        newR.liquidity = newL;
        idle.amount0 -= c0;
        idle.amount1 -= c1;
    }

    // ------------------------------------------------------------------ (c) token-order symmetry
    /// Leakage as a FRACTION of NAV must not depend on which token is token0. Flipping orientation swaps the amounts
    /// and inverts the price (tick -> -tick); the value fraction lost is the same up to rounding.
    function testFuzz_tokenOrderSymmetry(int24 tick, uint256 x0, uint256 x1, uint256 y0, uint256 y1) public pure {
        tick = int24(bound(tick, -100_000, 100_000));
        x0 = bound(x0, 1e18, 1e27);
        x1 = bound(x1, 1e18, 1e27);
        y0 = bound(y0, 1e18, 1e27);
        y1 = bound(y1, 1e18, 1e27);
        Range memory none = Range(0, 60, 0);
        uint160 sA = TickMath.getSqrtPriceAtTick(tick);
        uint160 sB = TickMath.getSqrtPriceAtTick(-tick);

        (int256 leakA, uint256 navA) =
            DecisionScore.immediateLeakage(none, Holdings(x0, x1), sA, none, Holdings(y0, y1), sA, sA);
        (int256 leakB, uint256 navB) =
            DecisionScore.immediateLeakage(none, Holdings(x1, x0), sB, none, Holdings(y1, y0), sB, sB);
        int256 fracA = leakA * 1e18 / int256(navA);
        int256 fracB = leakB * 1e18 / int256(navB);
        // Tolerance: 1e4 wad absolute (rounding of ~P wei on NAV >= 1e18) plus 1e-12 relative (fractions can reach
        // -1e9 WAD when holdings grow 1e9x; the tick inversion and wei rounding are ~1e-18 relative).
        uint256 absA = uint256(fracA >= 0 ? fracA : -fracA);
        assertApproxEqAbs(fracA, fracB, 1e4 + absA / 1e12, "leakage fraction invariant to token order");
    }
}

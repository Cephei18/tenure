// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {DecisionScore} from "../../src/libraries/DecisionScore.sol";
import {RiskBudget, BudgetParams, BudgetState, Tier} from "../../src/libraries/RiskBudget.sol";
import {TenureScorer} from "../../src/libraries/TenureScorer.sol";
import {TenureDefaults} from "../utils/TenureDefaults.sol";

/// @notice M4.2c: TenureScorer is the EXTERNAL (linked) library the hook delegates its heavy pure math to. These tests
///         prove each external function is exactly the internal-library math it replaced in the hook (so the
///         differential tests of PositionValue / DecisionScore / RiskBudget still cover the hook), that errors
///         propagate through the DELEGATECALL, and that the hook keeps >= 2,000 B of EIP-170 headroom.
contract TenureScorerTest is Test {
    uint256 constant EIP170 = 24_576;
    uint256 constant HEADROOM = 2_000;

    // ------------------------------------------------------------------ helpers
    function _range(int24 lo, uint24 width, uint128 liq) internal pure returns (Range memory r) {
        int24 tl = int24(bound(int256(lo), -200_000, 200_000)) / 60 * 60;
        int24 tu = tl + int24(uint24(bound(width, 1, 3000))) * 60;
        r = Range(tl, tu, uint128(bound(liq, 0, 1e30)));
    }

    function _price(int24 t) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(int24(bound(int256(t), -200_000, 200_000)));
    }

    struct Case {
        Range oldR;
        Range newR;
        Holdings idleOld;
        Holdings idleNew;
        uint160 s0;
        uint160 s1;
        uint160 fair;
    }

    /// @dev The pre-M4.2c hook formula for "moved" (TenureHook._checkMandate), kept verbatim as the reference.
    function _refMoved(Case memory c, uint256 navBefore) internal pure returns (uint256) {
        if (navBefore == 0) return 0;
        Holdings memory hB = PositionValue.holdings(c.oldR, c.idleOld.amount0, 0, c.s0, true);
        Holdings memory hA = PositionValue.holdings(c.newR, c.idleNew.amount0, 0, c.s1, false);
        uint256 d0 = hA.amount0 > hB.amount0 ? hA.amount0 - hB.amount0 : hB.amount0 - hA.amount0;
        uint256 movedValue = PositionValue.navAt(Holdings(d0, 0), c.fair, true);
        return FullMath.mulDivRoundingUp(movedValue, 1e18, navBefore);
    }

    // ------------------------------------------------------------------ scoring equivalence
    function testFuzz_scoreRebalance_matchesInternalMath(
        int24[2] memory lo,
        uint24[2] memory width,
        uint128[2] memory liq,
        uint128[4] memory idle,
        int24[3] memory ticks
    ) public pure {
        Case memory c = Case(
            _range(lo[0], width[0], liq[0]),
            _range(lo[1], width[1], liq[1]),
            Holdings(bound(idle[0], 0, 1e30), bound(idle[1], 0, 1e30)),
            Holdings(bound(idle[2], 0, 1e30), bound(idle[3], 0, 1e30)),
            _price(ticks[0]),
            _price(ticks[1]),
            _price(ticks[2])
        );
        (int256 leak, uint256 nav, uint256 moved) =
            TenureScorer.scoreRebalance(c.oldR, c.idleOld, c.s0, c.newR, c.idleNew, c.s1, c.fair);
        (int256 refLeak, uint256 refNav) =
            DecisionScore.immediateLeakage(c.oldR, c.idleOld, c.s0, c.newR, c.idleNew, c.s1, c.fair);
        assertEq(leak, refLeak, "leak");
        assertEq(nav, refNav, "navBefore");
        assertEq(moved, _refMoved(c, refNav), "moved");
    }

    function test_scoreRebalance_handExample_roundsMovedUp() public pure {
        // Fair price 1 (tick 0). 100 token0 idle -> 90 token1 idle: leaked 10, moved 100 of NAV 100 = 100%.
        Range memory none = Range(-60, 60, 0);
        uint160 one = TickMath.getSqrtPriceAtTick(0);
        (int256 leak, uint256 nav, uint256 moved) =
            TenureScorer.scoreRebalance(none, Holdings(100, 0), one, none, Holdings(0, 90), one, one);
        assertEq(leak, 10);
        assertEq(nav, 100);
        assertEq(moved, 1e18);
        // 1 of 3 moved: WAD fraction rounds UP (curator-adverse).
        (,, moved) = TenureScorer.scoreRebalance(none, Holdings(1, 2), one, none, Holdings(0, 3), one, one);
        assertEq(moved, uint256(1e18) / 3 + 1);
    }

    function test_scoreRebalance_emptyVault_movedZero() public pure {
        Range memory none = Range(-60, 60, 0);
        uint160 one = TickMath.getSqrtPriceAtTick(0);
        (int256 leak, uint256 nav, uint256 moved) =
            TenureScorer.scoreRebalance(none, Holdings(0, 0), one, none, Holdings(0, 0), one, one);
        assertEq(leak, 0);
        assertEq(nav, 0);
        assertEq(moved, 0);
    }

    function testFuzz_alphaWithFees_matchesInternalMath(
        int24[2] memory lo,
        uint24[2] memory width,
        uint128[2] memory liq,
        uint128[8] memory amt,
        int24[2] memory ticks
    ) public pure {
        Range memory oldR = _range(lo[0], width[0], liq[0]);
        Range memory newR = _range(lo[1], width[1], liq[1]);
        Holdings memory idleOld = Holdings(bound(amt[0], 0, 1e30), bound(amt[1], 0, 1e30));
        Holdings memory feesCf = Holdings(bound(amt[2], 0, 1e30), bound(amt[3], 0, 1e30));
        Holdings memory idleNew = Holdings(bound(amt[4], 0, 1e30), bound(amt[5], 0, 1e30));
        Holdings memory feesNew = Holdings(bound(amt[6], 0, 1e30), bound(amt[7], 0, 1e30));
        (uint160 sT, uint160 fT) = (_price(ticks[0]), _price(ticks[1]));
        assertEq(
            TenureScorer.alphaWithFees(oldR, idleOld, feesCf, newR, idleNew, feesNew, sT, fT),
            DecisionScore.markoutAlphaWithFees(oldR, idleOld, feesCf, newR, idleNew, feesNew, sT, fT)
        );
    }

    function testFuzz_windowFees_matchesEstimateFees(
        uint256[4] memory g,
        uint256[4] memory inside,
        uint128 liq,
        bool valid,
        bool cf
    ) public pure {
        Holdings memory got = TenureScorer.windowFees(g, inside, liq, valid, cf);
        uint256 dI0;
        uint256 dI1;
        uint256 dG0;
        uint256 dG1;
        unchecked {
            (dI0, dI1, dG0, dG1) = (inside[0] - inside[2], inside[1] - inside[3], g[0] - g[2], g[1] - g[3]);
        }
        Holdings memory want = DecisionScore.estimateFees(dI0, dI1, dG0, dG1, liq, valid, cf);
        assertEq(got.amount0, want.amount0, "fees0");
        assertEq(got.amount1, want.amount1, "fees1");
    }

    function test_windowFees_wrapsAccumulators() public pure {
        // Accumulators wrap mod 2^256 by design: then = max, now = 9 => delta 10 per unit of liquidity (X128).
        uint256 q128 = 1 << 128;
        uint256[4] memory g = [uint256(9 * q128), 9 * q128, type(uint256).max - q128 + 1, type(uint256).max - q128 + 1];
        Holdings memory f = TenureScorer.windowFees(g, g, 1, true, false);
        assertEq(f.amount0, 10);
        assertEq(f.amount1, 10);
    }

    // ------------------------------------------------------------------ budget equivalence
    function _state(uint256 budget, uint256 cumW, uint256 cumV, bool frozen)
        internal
        pure
        returns (BudgetState memory s)
    {
        BudgetParams memory p = TenureDefaults.budgetParams();
        s.cumAlphaWad = bound(cumW, 0, 1e18);
        s.cumAlphaValue = bound(cumV, 0, 1e30);
        s.bMax = RiskBudget.bMaxFor(s.cumAlphaWad, p);
        s.budget = bound(budget, 0, s.bMax);
        s.tier = frozen ? Tier.FROZEN : RiskBudget.tierFor(s.budget, s.bMax, p);
        s.lastBlock = 100;
    }

    function _eq(BudgetState memory a, BudgetState memory b) internal pure {
        assertEq(a.budget, b.budget, "budget");
        assertEq(a.bMax, b.bMax, "bMax");
        assertEq(a.lastBlock, b.lastBlock, "lastBlock");
        assertEq(uint8(a.tier), uint8(b.tier), "tier");
        assertEq(a.cumAlphaWad, b.cumAlphaWad, "cumAlphaWad");
        assertEq(a.cumAlphaValue, b.cumAlphaValue, "cumAlphaValue");
    }

    function testFuzz_applyMarkout_matchesChargeCredit(
        uint256 budget,
        uint256 cumW,
        uint256 cumV,
        bool frozen,
        int128 alpha,
        uint128 nav
    ) public pure {
        BudgetParams memory p = TenureDefaults.budgetParams();
        BudgetState memory s = _state(budget, cumW, cumV, frozen);
        uint256 navBefore = bound(nav, 1, type(uint128).max);
        (BudgetState memory got, uint256 lossW, uint256 gainW) = TenureScorer.applyMarkout(s, p, alpha, navBefore);

        BudgetState memory want = _state(budget, cumW, cumV, frozen);
        uint256 wantLoss;
        uint256 wantGain;
        if (alpha < 0) {
            wantLoss = DecisionScore.lossWad(-int256(alpha), navBefore);
            RiskBudget.charge(want, p, wantLoss, uint256(-int256(alpha)));
        } else {
            wantGain = DecisionScore.gainWad(alpha, navBefore);
            RiskBudget.credit(want, p, wantGain, uint256(int256(alpha)));
        }
        _eq(got, want);
        assertEq(lossW, wantLoss, "lossW");
        assertEq(gainW, wantGain, "gainW");
        if (alpha < 0) assertEq(gainW, 0);
        if (alpha >= 0) assertEq(lossW, 0);
    }

    function testFuzz_chargeLeak_matchesCharge(
        uint256 budget,
        uint256 cumW,
        uint256 cumV,
        bool frozen,
        int128 leak,
        uint128 nav
    ) public pure {
        BudgetParams memory p = TenureDefaults.budgetParams();
        BudgetState memory s = _state(budget, cumW, cumV, frozen);
        uint256 navBefore = bound(nav, 1, type(uint128).max);
        (BudgetState memory got, uint256 lossW) = TenureScorer.chargeLeak(s, p, leak, navBefore);

        BudgetState memory want = _state(budget, cumW, cumV, frozen);
        uint256 wantLoss = DecisionScore.lossWad(leak, navBefore);
        if (wantLoss != 0) RiskBudget.charge(want, p, wantLoss, uint256(int256(leak)));
        _eq(got, want);
        assertEq(lossW, wantLoss);
    }

    function test_chargeLeak_negativeLeak_isFree() public pure {
        BudgetParams memory p = TenureDefaults.budgetParams();
        BudgetState memory s = _state(p.bMax0, 0, 0, false);
        (BudgetState memory got, uint256 lossW) = TenureScorer.chargeLeak(s, p, -5, 100);
        assertEq(lossW, 0);
        assertEq(got.budget, p.bMax0);
    }

    function test_errorsPropagateThroughDelegatecall() public {
        BudgetParams memory p = TenureDefaults.budgetParams();
        BudgetState memory s = _state(p.bMax0, 0, 0, false);
        vm.expectRevert(DecisionScore.Tenure__ZeroNav.selector);
        this.callChargeLeak(s, p, 1, 0);
    }

    function callChargeLeak(BudgetState memory s, BudgetParams memory p, int256 leak, uint256 nav) external pure {
        TenureScorer.chargeLeak(s, p, leak, nav);
    }

    // ------------------------------------------------------------------ ticks
    function testFuzz_tickAt_tickDistance(uint160 a, uint160 b) public pure {
        a = uint160(bound(a, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        b = uint160(bound(b, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        int256 ta = TickMath.getTickAtSqrtPrice(a);
        int256 tb = TickMath.getTickAtSqrtPrice(b);
        assertEq(TenureScorer.tickAt(a), ta);
        assertEq(TenureScorer.tickDistance(a, b), uint256(ta > tb ? ta - tb : tb - ta));
        assertEq(TenureScorer.tickDistance(a, b), TenureScorer.tickDistance(b, a));
    }

    // ------------------------------------------------------------------ size guard (M4.2c)
    /// @dev Under the deploy profile (via-IR, what actually ships) the hook must keep >= 2,000 B of EIP-170 headroom.
    ///      The default profile (no via-IR) is test-only and known to exceed 24 KB, so it only logs the size.
    function test_hookSize_headroomUnderDeployProfile() public {
        uint256 size = vm.getDeployedCode("TenureHook.sol:TenureHook").length;
        emit log_named_uint("TenureHook runtime size (B)", size);
        if (keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("default")))) == keccak256("deploy")) {
            assertLe(size + HEADROOM, EIP170, "hook needs >= 2,000 B EIP-170 headroom");
        }
        uint256 lib = vm.getDeployedCode("TenureScorer.sol:TenureScorer").length;
        emit log_named_uint("TenureScorer runtime size (B)", lib);
        assertLe(lib, EIP170, "scorer library must be deployable");
    }
}

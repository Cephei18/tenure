// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PositionValue, Holdings, Range} from "../../src/libraries/PositionValue.sol";
import {DecisionScore} from "../../src/libraries/DecisionScore.sol";
import {RiskBudget, BudgetParams, BudgetState, Tier} from "../../src/libraries/RiskBudget.sol";
import {TenureDefaults} from "../utils/TenureDefaults.sol";

/// @title Slow-bleed proof (pure libraries)
/// @notice A poisoned curator makes 200 small, individually "valid" bad rebalances: each swaps 10% of NAV of token0
///         into token1 at 0.5% below the fair price (an attacker is on the other side). Each action leaks ~0.05% of
///         NAV - far under a static per-action cap of 1% - so static limits allow every one of them. Tenure measures
///         the leakage, drains the risk budget, tightens the mandate in RESTRICTED, and freezes the curator.
contract SlowBleedTest is Test {
    uint256 constant ACTIONS = 200;
    uint256 constant BLOCKS_PER_ACTION = 10;
    uint256 constant WAD = 1e18;

    // Static guard (what Arrakis-style limits look like): max 1% of NAV lost per action, max 15% of NAV moved.
    uint256 constant STATIC_MAX_LEAK_WAD = 1e16;
    uint256 constant MAX_MOVE_WAD = 15e16;
    // What the poisoned curator wants to do each action
    uint256 constant WANT_MOVE_WAD = 10e16;
    uint256 constant BAD_PRICE_DISCOUNT_WAD = 5e15; // 0.5% worse than fair

    int24 constant FAIR_TICK = 76_012; // ~2000 token1 per token0
    Range NONE = Range(0, 60, 0);

    struct Run {
        Holdings h;
        uint256 nav;
        uint256 allowed;
        uint256 frozenAt; // action index at which FROZEN was reached (0 = never)
        BudgetState s;
    }

    uint160 fair;
    uint256 price; // WAD, token1 per token0

    function test_slowBleed_staticCapsVsTenure() public {
        BudgetParams memory p = TenureDefaults.budgetParams();
        fair = TickMath.getSqrtPriceAtTick(FAIR_TICK);
        price = FullMath.mulDiv(FullMath.mulDiv(1e18, fair, FixedPoint96.Q96), fair, FixedPoint96.Q96);

        // 500 token0 + 1,000,000 token1 (18 decimals both, raw units)
        Holdings memory start = Holdings(500e18, 1_000_000e18);
        uint256 nav0 = PositionValue.navAt(start, fair, false);

        Run memory st; // static caps only
        Run memory tn; // Tenure
        st.h = start;
        tn.h = start;
        st.nav = nav0;
        tn.nav = nav0;
        tn.s = RiskBudget.init(p, 1);

        string memory csv =
            "action,block,static_nav,tenure_nav,budget_wad,bmax_wad,tier,static_allowed,tenure_allowed\n";
        console2.log("action | static NAV (token1) | tenure NAV (token1) | budget %% bMax | tier");

        for (uint256 i = 1; i <= ACTIONS; ++i) {
            uint256 blk = 1 + i * BLOCKS_PER_ACTION;
            _stepStatic(st);
            bool ok = _stepTenure(tn, p, blk, i);
            st.nav = PositionValue.navAt(st.h, fair, false);
            tn.nav = PositionValue.navAt(tn.h, fair, false);
            csv = string.concat(csv, _row(i, blk, st, tn, ok));
            if (i % 10 == 0 || i == tn.frozenAt) _logRow(i, st, tn);
        }

        vm.writeFile("docs/results/slow_bleed.csv", csv);

        uint256 lossStatic = nav0 - st.nav;
        uint256 lossTenure = nav0 - tn.nav;
        console2.log("--------------------------------------------------------------");
        console2.log("static caps: actions allowed", st.allowed, "/ 200");
        console2.log("tenure     : actions allowed", tn.allowed, "/ 200");
        console2.log("tenure FROZEN at action", tn.frozenAt);
        console2.log("loss static (bps of NAV)", lossStatic * 10_000 / nav0);
        console2.log("loss tenure (bps of NAV)", lossTenure * 10_000 / nav0);

        // ---- the claims
        assertEq(st.allowed, ACTIONS, "static caps allow every small bad action");
        assertGt(tn.frozenAt, 0, "Tenure reaches FROZEN");
        assertLt(tn.frozenAt, ACTIONS / 2, "...well before the bleed finishes");
        assertEq(uint256(tn.s.tier), uint256(Tier.FROZEN), "and stays frozen");
        // Bounded: sum of charged fractions <= initial budget + refill until frozen + one overdraw action.
        uint256 bound = p.bMax0 + p.refillRate * tn.frozenAt * BLOCKS_PER_ACTION + STATIC_MAX_LEAK_WAD;
        assertLe(lossTenure * WAD / nav0, bound, "Tenure loss bounded by the budget");
        assertLt(lossTenure * 4, lossStatic, "Tenure loses < 1/4 of what static caps lose");
    }

    /// @dev Static caps only: every action passes the per-action checks, so every action executes.
    function _stepStatic(Run memory st) internal view {
        (Holdings memory afterS, int256 leak, uint256 navBefore) = _badRebalance(st.h, WANT_MOVE_WAD);
        assertLe(DecisionScore.lossWad(leak, navBefore), STATIC_MAX_LEAK_WAD, "each action within static cap");
        assertLe(WANT_MOVE_WAD, MAX_MOVE_WAD, "within static move cap");
        st.h = afterS;
        st.allowed++;
    }

    /// @dev Tenure: refill, gate by tier, tier-dependent mandate (RESTRICTED quarters max move), measure, charge.
    function _stepTenure(Run memory tn, BudgetParams memory p, uint256 blk, uint256 i) internal view returns (bool) {
        RiskBudget.refill(tn.s, p, blk);
        if (tn.s.tier == Tier.FROZEN) return false;
        uint256 maxMove = tn.s.tier == Tier.RESTRICTED ? MAX_MOVE_WAD / 4 : MAX_MOVE_WAD;
        uint256 move = WANT_MOVE_WAD < maxMove ? WANT_MOVE_WAD : maxMove;
        (Holdings memory afterT, int256 leak, uint256 navBefore) = _badRebalance(tn.h, move);
        tn.h = afterT;
        RiskBudget.charge(tn.s, p, DecisionScore.lossWad(leak, navBefore), leak > 0 ? uint256(leak) : 0);
        tn.allowed++;
        if (tn.s.tier == Tier.FROZEN && tn.frozenAt == 0) tn.frozenAt = i;
        return true;
    }

    function _logRow(uint256 i, Run memory st, Run memory tn) internal pure {
        console2.log(
            string.concat(
                _pad(vm.toString(i), 6),
                " | ",
                _pad(vm.toString(st.nav / 1e18), 19),
                " | ",
                _pad(vm.toString(tn.nav / 1e18), 19),
                " | ",
                _pad(vm.toString(tn.s.budget * 100 / tn.s.bMax), 13),
                " | ",
                _tierName(tn.s.tier)
            )
        );
    }

    /// @dev Swap `moveWad` of NAV worth of token0 into token1 at (1 - discount) * fair. Returns new holdings and the
    ///      measured immediate leakage (via the real DecisionScore).
    function _badRebalance(Holdings memory h, uint256 moveWad)
        internal
        view
        returns (Holdings memory afterH, int256 leak, uint256 navBefore)
    {
        uint256 nav = PositionValue.navAt(h, fair, false);
        uint256 priceWad = price;
        uint256 sell0 = FullMath.mulDiv(FullMath.mulDiv(nav, moveWad, WAD), WAD, priceWad);
        if (sell0 > h.amount0) sell0 = h.amount0;
        uint256 got1 = FullMath.mulDiv(FullMath.mulDiv(sell0, priceWad, WAD), WAD - BAD_PRICE_DISCOUNT_WAD, WAD);
        afterH = Holdings(h.amount0 - sell0, h.amount1 + got1);
        (leak, navBefore) = DecisionScore.immediateLeakage(NONE, h, fair, NONE, afterH, fair, fair);
        // The curator keeps re-buying token0 at fair from "the market" off-pool so it can keep bleeding: model the
        // re-acquisition at fair price (no extra loss) to keep the token0 inventory available.
        uint256 rebuy1 = FullMath.mulDiv(sell0, priceWad, WAD);
        if (afterH.amount1 >= rebuy1) afterH = Holdings(afterH.amount0 + sell0, afterH.amount1 - rebuy1);
    }

    function _row(uint256 i, uint256 blk, Run memory st, Run memory tn, bool ok) internal pure returns (string memory) {
        return string.concat(
            vm.toString(i),
            ",",
            vm.toString(blk),
            ",",
            vm.toString(st.nav),
            ",",
            vm.toString(tn.nav),
            ",",
            vm.toString(tn.s.budget),
            ",",
            vm.toString(tn.s.bMax),
            ",",
            _tierName(tn.s.tier),
            ",1,",
            ok ? "1" : "0",
            "\n"
        );
    }

    function _tierName(Tier t) internal pure returns (string memory) {
        return t == Tier.FULL ? "FULL" : t == Tier.RESTRICTED ? "RESTRICTED" : "FROZEN";
    }

    function _pad(string memory s, uint256 w) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= w) return s;
        bytes memory out = new bytes(w);
        uint256 padN = w - b.length;
        for (uint256 i; i < w; ++i) {
            out[i] = i < padN ? bytes1(" ") : b[i - padN];
        }
        return string(out);
    }
}

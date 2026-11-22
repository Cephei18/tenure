// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionValue, Holdings, Range} from "./PositionValue.sol";
import {DecisionScore} from "./DecisionScore.sol";
import {RiskBudget, BudgetParams, BudgetState} from "./RiskBudget.sol";

/// @title TenureScorer
/// @notice EXTERNAL (linked) library holding the hook's heaviest pure math, so TenureHook stays well under the
///         EIP-170 size limit (M4.2c). Every function is `external pure`: it is executed by DELEGATECALL from the hook,
///         touches no storage and makes no authorization decisions. All state and access control stay in the hook.
/// @dev Thin wrappers over the internal libraries (PositionValue, DecisionScore, RiskBudget), which remain the single
///      source of truth and keep their exact differential tests. Rounding is therefore unchanged (curator-adverse,
///      tenure-math "Rounding"). Linking: forge links it automatically in tests and in `forge script`/`forge create`
///      deployments (`--libraries src/libraries/TenureScorer.sol:TenureScorer:<addr>` for manual deploys).
library TenureScorer {
    uint256 internal constant WAD = 1e18;

    /// @notice Immediate leakage (tenure-math 3) plus the value converted between tokens (mandate "moved").
    /// @dev "Moved" = |change in total token0 holdings| valued at the fair price, as a WAD fraction of NAV_before,
    ///      rounded up. Re-ranging without a swap converts nothing (tokens just move between position and idle),
    ///      so it is never "moved" (ACCEPTED decision). Returns movedW = 0 when NAV_before is 0 (empty vault).
    /// @return leak Signed leakage, token1 units (positive = value lost).
    /// @return navBefore NAV(H_before) at the fair price, rounded up.
    /// @return movedW Value converted between tokens, WAD of NAV_before, rounded up.
    function scoreRebalance(
        Range memory oldRange,
        Holdings memory idleOld,
        uint160 spotBefore,
        Range memory newRange,
        Holdings memory idleNew,
        uint160 spotAfter,
        uint160 sqrtFairX96
    ) external pure returns (int256 leak, uint256 navBefore, uint256 movedW) {
        (leak, navBefore) = DecisionScore.immediateLeakage(
            oldRange, idleOld, spotBefore, newRange, idleNew, spotAfter, sqrtFairX96
        );
        if (navBefore == 0) return (leak, 0, 0);
        Holdings memory hB = PositionValue.holdings(oldRange, idleOld.amount0, 0, spotBefore, true);
        Holdings memory hA = PositionValue.holdings(newRange, idleNew.amount0, 0, spotAfter, false);
        uint256 d0 = hA.amount0 > hB.amount0 ? hA.amount0 - hB.amount0 : hB.amount0 - hA.amount0;
        uint256 movedValue = PositionValue.navAt(Holdings(d0, 0), sqrtFairX96, true);
        movedW = FullMath.mulDivRoundingUp(movedValue, WAD, navBefore);
    }

    /// @notice Markout alpha including LP fees (tenure-math 4 + 4b). See DecisionScore.markoutAlphaWithFees.
    function alphaWithFees(
        Range memory oldRange,
        Holdings memory idleOld,
        Holdings memory feesCf,
        Range memory newRange,
        Holdings memory idleNew,
        Holdings memory feesNew,
        uint160 spotT,
        uint160 sqrtFairT
    ) external pure returns (int256) {
        return DecisionScore.markoutAlphaWithFees(
            oldRange, idleOld, feesCf, newRange, idleNew, feesNew, spotT, sqrtFairT
        );
    }

    /// @notice Fees a hypothetical position earned over the window (tenure-math 4b), from raw accumulator readings.
    /// @dev Deltas are taken mod 2^256 like v4. `insideValid` = both ticks initialized at the reading.
    /// @param g [globalNow0, globalNow1, globalThen0, globalThen1] fee growth globals (X128).
    /// @param inside [insideNow0, insideNow1, insideThen0, insideThen1] fee growth inside the range (X128).
    function windowFees(
        uint256[4] memory g,
        uint256[4] memory inside,
        uint128 liquidity,
        bool insideValid,
        bool counterfactual
    ) external pure returns (Holdings memory) {
        return DecisionScore.estimateFees(
            DecisionScore.feeGrowthDelta(inside[0], inside[2]),
            DecisionScore.feeGrowthDelta(inside[1], inside[3]),
            DecisionScore.feeGrowthDelta(g[0], g[2]),
            DecisionScore.feeGrowthDelta(g[1], g[3]),
            liquidity,
            insideValid,
            counterfactual
        );
    }

    /// @notice Charge an immediate leak to the budget (tenure-math 5-7). No-op for leak <= 0.
    /// @return b Updated budget state.
    /// @return lossW Loss as WAD of NAV_before, rounded up.
    function chargeLeak(BudgetState memory b, BudgetParams memory p, int256 leak, uint256 navBefore)
        external
        pure
        returns (BudgetState memory, uint256 lossW)
    {
        lossW = DecisionScore.lossWad(leak, navBefore);
        if (lossW != 0) RiskBudget.charge(b, p, lossW, uint256(leak));
        return (b, lossW);
    }

    /// @notice Apply a settled markout: negative alpha charges the budget, positive alpha credits reputation only.
    /// @return b Updated budget state.
    /// @return lossW Loss as WAD of NAV_before, rounded up (0 if alpha >= 0).
    /// @return gainW Gain as WAD of NAV_before, rounded down (0 if alpha < 0).
    function applyMarkout(BudgetState memory b, BudgetParams memory p, int256 alpha, uint256 navBefore)
        external
        pure
        returns (BudgetState memory, uint256 lossW, uint256 gainW)
    {
        if (alpha < 0) {
            lossW = DecisionScore.lossWad(-alpha, navBefore);
            RiskBudget.charge(b, p, lossW, uint256(-alpha));
        } else {
            gainW = DecisionScore.gainWad(alpha, navBefore);
            RiskBudget.credit(b, p, gainW, uint256(alpha));
        }
        return (b, lossW, gainW);
    }

    /// @notice Tick of a sqrt price (TickMath.getTickAtSqrtPrice), kept out of the hook for size.
    function tickAt(uint160 sqrtPriceX96) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    /// @notice |tick(a) - tick(b)|: how far two sqrt prices are apart, in ticks.
    function tickDistance(uint160 a, uint160 b) external pure returns (uint256) {
        int256 ta = TickMath.getTickAtSqrtPrice(a);
        int256 tb = TickMath.getTickAtSqrtPrice(b);
        return uint256(ta > tb ? ta - tb : tb - ta);
    }
}

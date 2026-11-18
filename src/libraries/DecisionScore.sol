// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PositionValue, Holdings, Range} from "./PositionValue.sol";

/// @title DecisionScore
/// @notice Scores a curator decision (a rebalance) in value terms at a FAIR price. tenure-math sections 3-5.
/// @dev Every rounding choice is curator-adverse: value before / counterfactual rounded UP, value after / new rounded
///      DOWN, losses as a fraction rounded UP, gains as a fraction rounded DOWN. Mirrors sim/model.py exactly.
library DecisionScore {
    using SafeCast for uint256;

    error Tenure__ZeroNav();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Immediate leakage L_imm = NAV(H_before) - NAV(H_after), both at the same fair price.
    /// @dev Positive = value lost during the session (bad swap, sandwiched remove/add, rebalancing while spot is off
    ///      fair). A pure re-range at a fair spot leaks only rounding dust. Spot may differ before/after because the
    ///      session itself can move the pool. An exact no-op (nothing changed) is not a decision and scores exactly 0.
    /// @return leakage Signed leakage in token1 units.
    /// @return navBefore NAV of H_before (rounded up) - the denominator for the loss fraction.
    function immediateLeakage(
        Range memory oldRange,
        Holdings memory idleOld,
        uint160 spotBefore,
        Range memory newRange,
        Holdings memory idleNew,
        uint160 spotAfter,
        uint160 sqrtFairX96
    ) internal pure returns (int256 leakage, uint256 navBefore) {
        Holdings memory hBefore = PositionValue.holdings(oldRange, idleOld.amount0, idleOld.amount1, spotBefore, true);
        navBefore = PositionValue.navAt(hBefore, sqrtFairX96, true);
        if (_sameRange(oldRange, newRange) && _sameIdle(idleOld, idleNew) && spotBefore == spotAfter) {
            return (0, navBefore);
        }
        Holdings memory hAfter = PositionValue.holdings(newRange, idleNew.amount0, idleNew.amount1, spotAfter, false);
        leakage = navBefore.toInt256() - PositionValue.navAt(hAfter, sqrtFairX96, false).toInt256();
    }

    /// @notice Markout alpha after the window: value of what the curator chose minus value of doing nothing.
    /// @dev H_new(T) = holdings(newRange at S_T) + idleNew; H_cf(T) = holdings(oldRange at S_T) + idleOld. Both valued
    ///      at fair S*_T. The counterfactual is exact because CL holdings are path independent (fees: see
    ///      markoutAlphaWithFees). Negative alpha = the decision destroyed value; being picked off shows up here because the
    ///      new range sits where spot diverged from fair.
    function markoutAlpha(
        Range memory oldRange,
        Holdings memory idleOld,
        Range memory newRange,
        Holdings memory idleNew,
        uint160 spotT,
        uint160 sqrtFairT
    ) internal pure returns (int256 alpha) {
        if (_sameRange(oldRange, newRange) && _sameIdle(idleOld, idleNew)) return 0;
        Holdings memory hNew = PositionValue.holdings(newRange, idleNew.amount0, idleNew.amount1, spotT, false);
        Holdings memory hCf = PositionValue.holdings(oldRange, idleOld.amount0, idleOld.amount1, spotT, true);
        alpha = PositionValue.navAt(hNew, sqrtFairT, false).toInt256()
            - PositionValue.navAt(hCf, sqrtFairT, true).toInt256();
    }

    /// @notice Fee-growth delta between two snapshots of a v4 accumulator. Accumulators are uint256 that wrap by
    ///         design, so the delta is taken mod 2^256 (unchecked), exactly as v4 does.
    function feeGrowthDelta(uint256 nowX128, uint256 thenX128) internal pure returns (uint256 d) {
        unchecked {
            d = nowX128 - thenX128;
        }
    }

    /// @notice Fees a hypothetical position (range, liquidity) earned between the record and settlement.
    ///         tenure-math section 4b (M3.3).
    /// @dev Exact when the range's fee-growth-inside is trustworthy: `insideValid` (both ticks initialized at
    ///      settlement) and the inside delta <= the global delta for both tokens (an inside delta above the global
    ///      one can only come from a tick that was cleared and re-initialized in between). Otherwise a
    ///      curator-adverse fallback: the NEW position gets 0, the COUNTERFACTUAL gets liquidity * global delta (as if
    ///      always in range: an upper bound). New fees round down, counterfactual fees round up.
    /// @param dInside0 Fee growth inside the range over the window, token0 (X128 per unit liquidity).
    /// @param dGlobal0 Global fee growth over the window, token0.
    /// @param counterfactual True for the old range (H_cf), false for the new range (H_new).
    function estimateFees(
        uint256 dInside0,
        uint256 dInside1,
        uint256 dGlobal0,
        uint256 dGlobal1,
        uint128 liquidity,
        bool insideValid,
        bool counterfactual
    ) internal pure returns (Holdings memory f) {
        if (liquidity == 0) return f;
        bool ok = insideValid && dInside0 <= dGlobal0 && dInside1 <= dGlobal1;
        if (counterfactual) {
            (uint256 d0, uint256 d1) = ok ? (dInside0, dInside1) : (dGlobal0, dGlobal1);
            f.amount0 = FullMath.mulDivRoundingUp(d0, liquidity, Q128);
            f.amount1 = FullMath.mulDivRoundingUp(d1, liquidity, Q128);
        } else if (ok) {
            f.amount0 = FullMath.mulDiv(dInside0, liquidity, Q128);
            f.amount1 = FullMath.mulDiv(dInside1, liquidity, Q128);
        }
    }

    /// @notice Markout alpha including LP fees: each side's estimated fees are added to its idle holdings.
    /// @dev Why: without fees, honest liquidity provision scores as pure impermanent loss vs. staying idle, so an
    ///      honest curator would bleed budget for doing its job. A no-op decision still scores exactly 0.
    function markoutAlphaWithFees(
        Range memory oldRange,
        Holdings memory idleOld,
        Holdings memory feesCf,
        Range memory newRange,
        Holdings memory idleNew,
        Holdings memory feesNew,
        uint160 spotT,
        uint160 sqrtFairT
    ) internal pure returns (int256) {
        if (_sameRange(oldRange, newRange) && _sameIdle(idleOld, idleNew)) return 0;
        return markoutAlpha(
            oldRange,
            Holdings(idleOld.amount0 + feesCf.amount0, idleOld.amount1 + feesCf.amount1),
            newRange,
            Holdings(idleNew.amount0 + feesNew.amount0, idleNew.amount1 + feesNew.amount1),
            spotT,
            sqrtFairT
        );
    }

    /// @notice max(0, lossValue) as a WAD fraction of navRef, rounded UP (never under-charge the curator).
    function lossWad(int256 lossValue, uint256 navRef) internal pure returns (uint256) {
        if (navRef == 0) revert Tenure__ZeroNav();
        if (lossValue <= 0) return 0;
        return FullMath.mulDivRoundingUp(uint256(lossValue), WAD, navRef);
    }

    /// @notice max(0, gainValue) as a WAD fraction of navRef, rounded DOWN (never over-credit reputation).
    function gainWad(int256 gainValue, uint256 navRef) internal pure returns (uint256) {
        if (navRef == 0) revert Tenure__ZeroNav();
        if (gainValue <= 0) return 0;
        return FullMath.mulDiv(uint256(gainValue), WAD, navRef);
    }

    function _sameRange(Range memory a, Range memory b) private pure returns (bool) {
        return a.tickLower == b.tickLower && a.tickUpper == b.tickUpper && a.liquidity == b.liquidity;
    }

    function _sameIdle(Holdings memory a, Holdings memory b) private pure returns (bool) {
        return a.amount0 == b.amount0 && a.amount1 == b.amount1;
    }
}

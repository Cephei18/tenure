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
    ///      at fair S*_T. The counterfactual is exact because CL holdings are path independent (fees ignored until
    ///      stretch S1). Negative alpha = the decision destroyed value; being picked off shows up here because the
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

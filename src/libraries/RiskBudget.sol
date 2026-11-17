// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Autonomy tier. Ordered by decreasing autonomy.
enum Tier {
    FULL,
    RESTRICTED,
    FROZEN
}

/// @notice Configuration of the leaky bucket and reputation. All fractions are WAD of NAV.
struct BudgetParams {
    uint256 bMax0; // starting (and minimum) bucket size
    uint256 bMaxCap; // reputation can grow bMax up to this
    uint256 refillRate; // WAD per block
    uint256 fullThreshold; // budget/bMax >= this => FULL
    uint256 restrictedThreshold; // budget/bMax >= this => RESTRICTED, else FROZEN
    uint256 restoreWad; // guardian restore() sets budget = bMax * restoreWad (must land in RESTRICTED)
    uint256 k; // bMax = bMax0 + k * cumAlphaWad
    uint256 cap0; // starting deposit cap, token1 units
    uint256 capMax; // deposit cap ceiling
    uint256 m; // depositCap = cap0 + m * cumAlphaValue (m in WAD)
}

/// @notice Per-vault budget state.
struct BudgetState {
    uint256 budget; // WAD of NAV
    uint256 bMax; // WAD of NAV
    uint256 lastBlock;
    Tier tier;
    uint256 cumAlphaWad; // net cumulative positive alpha, as WAD fractions of NAV
    uint256 cumAlphaValue; // net cumulative positive alpha, token1 units
}

/// @title RiskBudget
/// @notice Leaky-bucket risk budget that maps measured losses to autonomy tiers, plus pool-native reputation.
/// @dev tenure-math sections 6-7. Pure functions over memory structs; mirrored exactly by sim/model.py.
///      Design choices (docs/MATH.md):
///      - FROZEN is sticky: no refill while frozen; only guardian restore() leaves it, landing in RESTRICTED.
///      - Positive alpha never refills spent budget. It grows bMax and the budget by the same delta, so the deficit
///        (bMax - budget) is unchanged and the tier cannot drop merely because bMax grew.
///      - Losses decay reputation first (net alpha), then drain the budget, floored at zero.
library RiskBudget {
    error Tenure__InvalidBudgetParams();

    uint256 internal constant WAD = 1e18;

    /// @notice Reverts unless params are internally consistent.
    function validate(BudgetParams memory p) internal pure {
        if (
            p.bMax0 == 0 || p.bMax0 > p.bMaxCap || p.restrictedThreshold == 0
                || p.restrictedThreshold >= p.fullThreshold || p.fullThreshold > WAD
                || p.restoreWad < p.restrictedThreshold || p.restoreWad >= p.fullThreshold || p.cap0 > p.capMax
        ) revert Tenure__InvalidBudgetParams();
    }

    /// @notice Fresh state: full bucket of bMax0, FULL tier.
    function init(BudgetParams memory p, uint256 blockNumber) internal pure returns (BudgetState memory s) {
        s.budget = p.bMax0;
        s.bMax = p.bMax0;
        s.lastBlock = blockNumber;
        s.tier = Tier.FULL;
    }

    /// @notice Tier for a budget level. ratio is floored (curator-adverse).
    function tierFor(uint256 budget, uint256 bMax, BudgetParams memory p) internal pure returns (Tier) {
        uint256 ratio = budget * WAD / bMax;
        if (ratio >= p.fullThreshold) return Tier.FULL;
        if (ratio >= p.restrictedThreshold) return Tier.RESTRICTED;
        return Tier.FROZEN;
    }

    /// @notice bMax implied by net cumulative positive alpha, capped.
    function bMaxFor(uint256 cumAlphaWad, BudgetParams memory p) internal pure returns (uint256) {
        uint256 b = p.bMax0 + FullMath.mulDiv(p.k, cumAlphaWad, WAD);
        return b < p.bMaxCap ? b : p.bMaxCap;
    }

    /// @notice Deposit cap implied by net cumulative positive alpha (token1 units), capped.
    function depositCap(BudgetState memory s, BudgetParams memory p) internal pure returns (uint256) {
        uint256 c = p.cap0 + FullMath.mulDiv(p.m, s.cumAlphaValue, WAD);
        return c < p.capMax ? c : p.capMax;
    }

    /// @notice Time-based refill (floor), capped at bMax. No-op while FROZEN except advancing lastBlock.
    function refill(BudgetState memory s, BudgetParams memory p, uint256 blockNumber) internal pure {
        if (blockNumber <= s.lastBlock) return;
        if (s.tier == Tier.FROZEN) {
            s.lastBlock = blockNumber;
            return;
        }
        uint256 b = s.budget + p.refillRate * (blockNumber - s.lastBlock);
        s.budget = b < s.bMax ? b : s.bMax;
        s.lastBlock = blockNumber;
        s.tier = tierFor(s.budget, s.bMax, p);
    }

    /// @notice Charge a measured loss. Decays reputation, then drains the budget (floored at 0). FROZEN stays FROZEN.
    function charge(BudgetState memory s, BudgetParams memory p, uint256 lossWad, uint256 lossValue) internal pure {
        s.cumAlphaWad = _satSub(s.cumAlphaWad, lossWad);
        s.cumAlphaValue = _satSub(s.cumAlphaValue, lossValue);
        s.bMax = bMaxFor(s.cumAlphaWad, p);
        uint256 b = s.budget < s.bMax ? s.budget : s.bMax;
        s.budget = _satSub(b, lossWad);
        if (s.tier != Tier.FROZEN) s.tier = tierFor(s.budget, s.bMax, p);
    }

    /// @notice Credit positive alpha to reputation. Never refills spent budget (deficit preserved).
    function credit(BudgetState memory s, BudgetParams memory p, uint256 gainWad, uint256 gainValue) internal pure {
        s.cumAlphaWad += gainWad;
        s.cumAlphaValue += gainValue;
        uint256 newBMax = bMaxFor(s.cumAlphaWad, p);
        if (s.tier != Tier.FROZEN) {
            s.budget += newBMax - s.bMax; // bMax is non-decreasing here because cumAlphaWad only grew
            s.bMax = newBMax;
            s.tier = tierFor(s.budget, s.bMax, p);
        } else {
            s.bMax = newBMax;
        }
    }

    /// @notice Guardian restore: autonomy is re-earned, so land at restoreWad of bMax (RESTRICTED), not FULL.
    function restore(BudgetState memory s, BudgetParams memory p, uint256 blockNumber) internal pure {
        s.budget = FullMath.mulDiv(s.bMax, p.restoreWad, WAD);
        s.lastBlock = blockNumber;
        s.tier = tierFor(s.budget, s.bMax, p);
    }

    function _satSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BudgetParams} from "../../src/libraries/RiskBudget.sol";

/// @dev Default params; MUST equal sim/model.py BudgetParams() defaults (the budget vectors use them).
library TenureDefaults {
    function budgetParams() internal pure returns (BudgetParams memory) {
        return BudgetParams({
            bMax0: 2e16,
            bMaxCap: 10e16,
            refillRate: uint256(2e16) / 7200,
            fullThreshold: 5e17,
            restrictedThreshold: 2e17,
            restoreWad: 35e16,
            k: 5e17,
            cap0: 100_000e18,
            capMax: 10_000_000e18,
            m: 50e18
        });
    }
}

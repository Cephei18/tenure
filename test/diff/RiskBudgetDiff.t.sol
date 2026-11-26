// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RiskBudget, BudgetParams, BudgetState, Tier} from "../../src/libraries/RiskBudget.sol";
import {TenureDefaults} from "../utils/TenureDefaults.sol";
import {VectorReader} from "./VectorReader.sol";

/// @notice Differential: RiskBudget op sequences must reproduce sim/model.py state after EVERY op.
contract RiskBudgetDiffTest is VectorReader {
    function test_diff_budgetSequences() public view {
        string memory j = _load("budget");
        uint256 n = _count(j);
        uint256 checked;
        uint256 customParams;
        for (uint256 i; i < n; ++i) {
            // Optional per-case params (tier-boundary cases with non-round thresholds); default params otherwise.
            BudgetParams memory p = TenureDefaults.budgetParams();
            if (vm.keyExistsJson(j, _key(i, "params"))) {
                p = _params(j, i);
                RiskBudget.validate(p);
                customParams++;
            }
            BudgetState memory s = RiskBudget.init(p, _u(j, i, "startBlock"));
            for (uint256 o;; ++o) {
                string memory base = string.concat("ops[", vm.toString(o), "].");
                if (!vm.keyExistsJson(j, _key(i, string.concat(base, "kind")))) break;
                _apply(j, i, base, s, p);
                _check(j, i, base, s, p);
                checked++;
            }
        }
        assertGe(checked, 200, "at least 200 budget states checked");
        assertGe(customParams, 2, "tier-boundary cases with non-round thresholds are present");
    }

    function _params(string memory j, uint256 i) internal pure returns (BudgetParams memory) {
        return BudgetParams({
            bMax0: _u(j, i, "params.bMax0"),
            bMaxCap: _u(j, i, "params.bMaxCap"),
            refillRate: _u(j, i, "params.refillRate"),
            fullThreshold: _u(j, i, "params.fullThreshold"),
            restrictedThreshold: _u(j, i, "params.restrictedThreshold"),
            restoreWad: _u(j, i, "params.restoreWad"),
            k: _u(j, i, "params.k"),
            cap0: _u(j, i, "params.cap0"),
            capMax: _u(j, i, "params.capMax"),
            m: _u(j, i, "params.m")
        });
    }

    function _apply(string memory j, uint256 i, string memory base, BudgetState memory s, BudgetParams memory p)
        internal
        pure
    {
        uint256 kind = _u(j, i, string.concat(base, "kind"));
        uint256 blk = _u(j, i, string.concat(base, "block"));
        uint256 a = _u(j, i, string.concat(base, "a"));
        uint256 b = _u(j, i, string.concat(base, "b"));
        if (kind == 0) {
            RiskBudget.refill(s, p, blk);
        } else if (kind == 1) {
            RiskBudget.refill(s, p, blk);
            RiskBudget.charge(s, p, a, b);
        } else if (kind == 2) {
            RiskBudget.refill(s, p, blk);
            RiskBudget.credit(s, p, a, b);
        } else {
            RiskBudget.restore(s, p, blk);
        }
    }

    function _check(string memory j, uint256 i, string memory base, BudgetState memory s, BudgetParams memory p)
        internal
        pure
    {
        assertEq(s.budget, _u(j, i, string.concat(base, "budget")), _msg(string.concat(base, "budget"), i));
        assertEq(s.bMax, _u(j, i, string.concat(base, "bMax")), _msg(string.concat(base, "bMax"), i));
        assertEq(s.lastBlock, _u(j, i, string.concat(base, "lastBlock")), _msg(string.concat(base, "lastBlock"), i));
        assertEq(uint256(s.tier), _u(j, i, string.concat(base, "tier")), _msg(string.concat(base, "tier"), i));
        assertEq(s.cumAlphaWad, _u(j, i, string.concat(base, "cumAlphaWad")), _msg("cumAlphaWad", i));
        assertEq(s.cumAlphaValue, _u(j, i, string.concat(base, "cumAlphaValue")), _msg("cumAlphaValue", i));
        assertEq(RiskBudget.depositCap(s, p), _u(j, i, string.concat(base, "depositCap")), _msg("depositCap", i));
    }
}

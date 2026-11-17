// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RiskBudget, BudgetParams, BudgetState, Tier} from "../../src/libraries/RiskBudget.sol";
import {TenureDefaults} from "../utils/TenureDefaults.sol";

contract RiskBudgetHarness {
    function validate(BudgetParams memory p) external pure {
        RiskBudget.validate(p);
    }
}

contract RiskBudgetTest is Test {
    BudgetParams p;

    function setUp() public {
        p = TenureDefaults.budgetParams();
    }

    function _fresh() internal view returns (BudgetState memory) {
        return RiskBudget.init(p, 100);
    }

    // ------------------------------------------------------------------ params
    function test_defaultsValid() public {
        new RiskBudgetHarness().validate(p);
    }

    function test_invalidParams_revert() public {
        RiskBudgetHarness h = new RiskBudgetHarness();
        BudgetParams memory bad = p;
        bad.restoreWad = 5e17; // would restore straight into FULL
        vm.expectRevert(RiskBudget.Tenure__InvalidBudgetParams.selector);
        h.validate(bad);
        bad = TenureDefaults.budgetParams();
        bad.bMax0 = 0;
        vm.expectRevert(RiskBudget.Tenure__InvalidBudgetParams.selector);
        h.validate(bad);
        bad = TenureDefaults.budgetParams();
        bad.restrictedThreshold = bad.fullThreshold;
        vm.expectRevert(RiskBudget.Tenure__InvalidBudgetParams.selector);
        h.validate(bad);
    }

    // ------------------------------------------------------------------ tiers
    function test_tierThresholdsExact() public view {
        uint256 b = p.bMax0;
        assertEq(uint256(RiskBudget.tierFor(b, b, p)), uint256(Tier.FULL));
        assertEq(uint256(RiskBudget.tierFor(b / 2, b, p)), uint256(Tier.FULL));
        assertEq(uint256(RiskBudget.tierFor(b / 2 - 1, b, p)), uint256(Tier.RESTRICTED));
        assertEq(uint256(RiskBudget.tierFor(b / 5, b, p)), uint256(Tier.RESTRICTED));
        assertEq(uint256(RiskBudget.tierFor(b / 5 - 1, b, p)), uint256(Tier.FROZEN));
        assertEq(uint256(RiskBudget.tierFor(0, b, p)), uint256(Tier.FROZEN));
    }

    function test_sequence_FULL_RESTRICTED_FROZEN_restore() public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, p.bMax0 * 6 / 10, 0);
        assertEq(uint256(s.tier), uint256(Tier.RESTRICTED));
        RiskBudget.charge(s, p, p.bMax0 * 25 / 100, 0);
        assertEq(uint256(s.tier), uint256(Tier.FROZEN));
        RiskBudget.restore(s, p, 500);
        assertEq(uint256(s.tier), uint256(Tier.RESTRICTED));
        assertEq(s.budget, p.bMax0 * 35 / 100);
        assertEq(s.lastBlock, 500);
    }

    function test_refill_floorRate_andRestrictedRecoversToFull() public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, p.bMax0 * 6 / 10, 0);
        uint256 b0 = s.budget;
        RiskBudget.refill(s, p, 110);
        assertEq(s.budget, b0 + 10 * p.refillRate);
        RiskBudget.refill(s, p, 1_000_000);
        assertEq(s.budget, s.bMax);
        assertEq(uint256(s.tier), uint256(Tier.FULL));
    }

    function test_refill_sameOrPastBlock_noop() public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, 1e15, 0);
        uint256 b0 = s.budget;
        RiskBudget.refill(s, p, 100);
        RiskBudget.refill(s, p, 50);
        assertEq(s.budget, b0);
        assertEq(s.lastBlock, 100);
    }

    function test_credit_keepsDeficit_growsCaps() public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, 1e15, 0);
        uint256 deficit = s.bMax - s.budget;
        RiskBudget.credit(s, p, 1e16, 1000e18);
        assertEq(s.bMax, p.bMax0 + 1e16 * p.k / 1e18);
        assertEq(s.bMax - s.budget, deficit, "alpha never refills spent budget");
        assertEq(RiskBudget.depositCap(s, p), p.cap0 + 1000 * p.m);
    }

    function test_reputation_capped() public view {
        BudgetState memory s = _fresh();
        RiskBudget.credit(s, p, 1e30, 1e40);
        assertEq(s.bMax, p.bMaxCap);
        assertEq(RiskBudget.depositCap(s, p), p.capMax);
    }

    function test_losses_decayReputation() public view {
        BudgetState memory s = _fresh();
        RiskBudget.credit(s, p, 2e16, 100);
        RiskBudget.charge(s, p, 5e15, 40);
        assertEq(s.cumAlphaWad, 15e15);
        assertEq(s.cumAlphaValue, 60);
        assertLe(s.budget, s.bMax);
    }

    // ------------------------------------------------------------------ fuzz invariants
    /// budget never exceeds bMax, never underflows, bMax within [bMax0, bMaxCap], FROZEN sticky without restore.
    function testFuzz_randomWalkInvariants(uint256 seed) public view {
        BudgetState memory s = _fresh();
        uint256 blk = 100;
        for (uint256 i; i < 60; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            blk += seed % 3000;
            Tier before = s.tier;
            uint256 op = (seed >> 16) % 10;
            if (op < 5) {
                RiskBudget.refill(s, p, blk);
                RiskBudget.charge(s, p, (seed >> 32) % 1e16, (seed >> 96) % 1e21);
            } else if (op < 9) {
                RiskBudget.refill(s, p, blk);
                RiskBudget.credit(s, p, (seed >> 32) % 1e15, (seed >> 96) % 1e21);
            } else {
                RiskBudget.refill(s, p, blk);
            }
            if (before == Tier.FROZEN) assertEq(uint256(s.tier), uint256(Tier.FROZEN), "frozen is sticky");
            if (s.tier == Tier.FROZEN && seed % 4 == 0) RiskBudget.restore(s, p, blk);
            assertLe(s.budget, s.bMax, "budget <= bMax");
            assertGe(s.bMax, p.bMax0);
            assertLe(s.bMax, p.bMaxCap);
            assertLe(RiskBudget.depositCap(s, p), p.capMax);
        }
    }

    /// Refill alone, for any duration, never lifts FROZEN.
    function testFuzz_refillNeverLiftsFrozen(uint256 loss, uint64 blocks) public view {
        BudgetState memory s = _fresh();
        loss = bound(loss, p.bMax0 * 81 / 100, 10e18); // pushes below 20%
        RiskBudget.charge(s, p, loss, 0);
        assertEq(uint256(s.tier), uint256(Tier.FROZEN));
        uint256 b = s.budget;
        RiskBudget.refill(s, p, uint256(s.lastBlock) + blocks);
        assertEq(uint256(s.tier), uint256(Tier.FROZEN));
        assertEq(s.budget, b);
    }

    /// Charge never underflows: huge losses floor the budget at 0.
    function testFuzz_chargeFloorsAtZero(uint256 loss) public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, loss, loss);
        if (loss >= p.bMax0) assertEq(s.budget, 0);
        else assertEq(s.budget, p.bMax0 - loss);
    }

    /// Tier is monotonic in budget: more budget never means a worse tier.
    function testFuzz_tierMonotonic(uint256 b1, uint256 b2, uint256 bMax) public view {
        bMax = bound(bMax, 1, 1e18);
        b1 = bound(b1, 0, bMax);
        b2 = bound(b2, b1, bMax);
        assertLe(uint256(RiskBudget.tierFor(b2, bMax, p)), uint256(RiskBudget.tierFor(b1, bMax, p)));
    }
}

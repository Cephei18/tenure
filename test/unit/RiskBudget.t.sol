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

    function test_credit_scalesBudgetProportionally_growsCaps() public view {
        BudgetState memory s = _fresh();
        RiskBudget.charge(s, p, 1e15, 0);
        uint256 b0 = s.budget;
        uint256 m0 = s.bMax;
        RiskBudget.credit(s, p, 1e16, 1000e18);
        assertEq(s.bMax, p.bMax0 + 1e16 * p.k / 1e18);
        assertEq(s.budget, b0 * s.bMax / m0, "budget scaled by bMax'/bMax (floor)");
        assertEq(RiskBudget.depositCap(s, p), p.cap0 + 1000 * p.m);
    }

    function test_credit_atThreshold_keepsTier() public view {
        BudgetState memory s = _fresh();
        s.budget = p.bMax0 / 2; // exactly on the FULL threshold
        for (uint256 g = 1; g < 8; ++g) {
            RiskBudget.credit(s, p, g, 1);
            assertEq(uint256(s.tier), uint256(Tier.FULL), "a 1-wei floor never demotes");
        }
    }

    function test_kAboveOne_reverts() public {
        RiskBudgetHarness h = new RiskBudgetHarness();
        BudgetParams memory q = TenureDefaults.budgetParams();
        q.k = 1e18;
        h.validate(q); // k == 1 is the boundary and allowed
        q.k = 1e18 + 1;
        vm.expectRevert(RiskBudget.Tenure__ReputationGainTooHigh.selector);
        h.validate(q);
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
                Tier t0 = s.tier;
                RiskBudget.credit(s, p, (seed >> 32) % 1e15, (seed >> 96) % 1e21);
                assertEq(uint256(s.tier), uint256(t0), "success never changes the tier");
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

    /// Positive-alpha settle never changes the tier; budget/bMax preserved within 1 wei, rounded down.
    function testFuzz_creditKeepsTierAndRatio(uint256 budget, uint256 cum, uint256 gainWad, uint256 k) public view {
        BudgetParams memory q = p;
        q.k = bound(k, 0, 1e18);
        BudgetState memory s = RiskBudget.init(q, 100);
        s.cumAlphaWad = bound(cum, 0, 1e18);
        s.bMax = RiskBudget.bMaxFor(s.cumAlphaWad, q);
        s.budget = bound(budget, 0, s.bMax);
        s.tier = RiskBudget.tierFor(s.budget, s.bMax, q);
        gainWad = bound(gainWad, 0, 1e18);
        Tier t0 = s.tier;
        uint256 b0 = s.budget;
        uint256 m0 = s.bMax;
        RiskBudget.credit(s, q, gainWad, gainWad);
        assertEq(uint256(s.tier), uint256(t0), "tier unchanged");
        if (t0 == Tier.FROZEN) {
            assertEq(s.budget, b0, "frozen budget untouched");
        } else {
            // b1/m1 <= b0/m0  and  b0/m0 - b1/m1 < 1/m1   <=>   b1*m0 <= b0*m1 < (b1+1)*m0
            assertLe(s.budget * m0, b0 * s.bMax, "never rounds up");
            assertLt(b0 * s.bMax, (s.budget + 1) * m0, "within 1 wei");
        }
        assertLe(s.budget, s.bMax);
    }

    /// Pump bound: an attacker who pays the vault X (manufactured alpha, as gainWad of NAV) gains at most X of
    /// extra allowed loss before FROZEN. "Allowed loss" is measured exactly (binary search for the largest loss
    /// that still leaves the curator un-frozen), so no discretization tolerance is needed. Net value never rises.
    function testFuzz_pumpNeverProfitable(uint256 pumpWad, uint256 k, uint256 preLoss, uint256 cum) public view {
        BudgetParams memory q = p;
        q.k = bound(k, 0, 1e18);
        pumpWad = bound(pumpWad, 1, 2e17);
        BudgetState memory base = RiskBudget.init(q, 100);
        RiskBudget.credit(base, q, bound(cum, 0, 1e17), 0); // some prior honest reputation
        RiskBudget.charge(base, q, bound(preLoss, 0, base.bMax * 79 / 100), 0); // anywhere above FROZEN
        vm.assume(base.tier != Tier.FROZEN);

        BudgetState memory pumped = _copy(base);
        RiskBudget.credit(pumped, q, pumpWad, 0);

        uint256 allowed0 = _maxLossBeforeFrozen(base, q);
        uint256 allowed1 = _maxLossBeforeFrozen(pumped, q);
        assertLe(allowed1, allowed0 + pumpWad, "pumping never increases net extractable value");
    }

    /// Same bound, measured as a realistic slow bleed: many small charges until FROZEN. The bleed overshoots by at
    /// most one step on each side, so the bound holds up to one step of granularity.
    function testFuzz_pumpNeverProfitable_slowBleed(uint256 pumpWad, uint256 k) public view {
        BudgetParams memory q = p;
        q.k = bound(k, 0, 1e18);
        pumpWad = bound(pumpWad, 1, 2e17);
        uint256 step = 1e14;
        BudgetState memory base = RiskBudget.init(q, 100);
        BudgetState memory pumped = RiskBudget.init(q, 100);
        RiskBudget.credit(pumped, q, pumpWad, 0);
        uint256 n0 = _bleedSteps(base, q, step);
        uint256 n1 = _bleedSteps(pumped, q, step);
        assertLe(n1 * step, n0 * step + pumpWad + step, "slow bleed: extra loss <= pump (+1 step granularity)");
    }

    function _maxLossBeforeFrozen(BudgetState memory s, BudgetParams memory q) internal pure returns (uint256 lo) {
        uint256 hi = s.budget + 1; // a loss >= budget always freezes (budget floors at 0)
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            BudgetState memory t = _copy(s);
            RiskBudget.charge(t, q, mid, 0);
            if (t.tier == Tier.FROZEN) hi = mid;
            else lo = mid;
        }
    }

    function _bleedSteps(BudgetState memory s, BudgetParams memory q, uint256 step) internal pure returns (uint256 n) {
        while (s.tier != Tier.FROZEN) {
            RiskBudget.charge(s, q, step, 0);
            ++n;
        }
    }

    function _copy(BudgetState memory s) internal pure returns (BudgetState memory t) {
        t = BudgetState(s.budget, s.bMax, s.lastBlock, s.tier, s.cumAlphaWad, s.cumAlphaValue);
    }
}

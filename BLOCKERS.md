# BLOCKERS

Tasks the loop could not finish. Each entry: task id, approaches tried, error, hypothesis.

## M3.3 Fees in alpha — BLOCKED on an existing gas assertion (needs a human decision)
Status: implementation complete and preserved on local branch `wip/m3.3-fees` (commit 88e6d2f). `main` is at the
last green state (M3.2).
What works on the branch: Python model first (fee_growth_delta, fee_amounts, estimate_fees, markout_alpha_fees),
240 new vectors (test/vectors/fees.json, existing vectors unchanged), DecisionScore.feeGrowthDelta /
estimateFees / markoutAlphaWithFees with an exact differential test, hook fee-growth snapshots per record,
fee-aware settle, fee-inclusive H_before/H_after and NAV (fixes a real masking bug: fees collected during a
rebalance used to hide an equal-sized leak). Full suite: 148 pass, 1 fails.
Failing test: TenureHookScoring.t.sol::test_gas_afterSwap_dueRecords
  `assertLt(g1 - g0, 150_000, "one settlement is cheap")` -> 191,924 >= 150,000.
  Swap gas: 0 due 117,777 / 1 due 309,701 / 3 due 423,186 (was 116,727 / 245,603 / 318,743).
Approaches tried:
  1. StateLibrary.getFeeGrowthInside + getTickLiquidity per range: +68k for the first settlement.
  2. One getTickInfo per tick (gross liquidity + fee growth outside in one call), slot0/globals read once, fee
     growth inside derived locally: +64k. Saved only ~4k.
  3. Costed struct packing (RebalanceRecord 8 -> 5 slots, BudgetState 6 -> 2): ~15-20k at best; the gap is 42k.
Hypothesis: the extra cost is inherent cold storage: 6 fee-growth snapshot slots + 4 ticks x 3 words + 2 globals
(~45k of cold reads). Measuring fees cannot avoid reading them. Settlements after the first in the same swap
cost ~57k each, so it is the cold first read that dominates.
Decision needed (pick one):
  (a) Re-baseline the guard to ~220k for one fee-aware settlement (I tried; auto mode correctly refused to loosen
      a test without you). M5.4 then caps auto-settle at 1/swap and adds settleMany for keepers.
  (b) Keep 150k and make auto-settle fee-unaware (worse: alpha would then differ by who settles - rejected).
  (c) Do the struct packing (approach 3) AND accept a smaller re-baseline (~175k).
Recommendation: (a). To resume: `git merge wip/m3.3-fees` (or cherry-pick 88e6d2f), change the bound, finish the
500-block honest-curator acceptance test (not yet written), MATH.md section, PROGRESS entry.
Impact on later tasks: M4.2 run A ("honest stays FULL") likely needs fees; M4.1 does not.

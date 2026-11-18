# Tenure threat model

Each entry: the threat, what Tenure does about it, and the test that proves it. M5.2 extends this file with the
remaining attacks (oracle staleness and manipulation, window gaming, bypass attempts, reentrancy).

## 1. Fee masking: hiding a leak behind collected LP fees (fixed in M3.3)

**Threat.** Removing a v4 position collects its uncollected fees into the vault's idle balance. Before M3.3 the
hook valued `H_before` as position principal + idle balances only, but `H_after` saw those collected fees as idle.
So every rebalance showed a negative leak of about the accrued fees. A poisoned curator could leak value up to the
accrued fees in the same rebalance (for example by swapping at a manipulated price) and be charged nothing.

**Fix.** `H_before` and `H_after` (and the vault's NAV used for share pricing) include the uncollected fees owed
on the vault's position, computed exactly as v4 pays them: `L * (feeGrowthInside - feeGrowthInsideLast) / 2^128`
(`libraries/FeesOwed.sol`, used by both the hook and the vault).

**Tests** (`test/TenureHookFees.t.sol`):
- `test_collectedFees_doNotMaskLeakage`: after fees accrue, a rebalance that changes nothing economically
  (same range, same L, fair spot, no swap) scores a leak in [0, 10] wei, never negative.
- `test_smallLeak_chargedDespiteCollectedFees`: a real leak smaller than the accrued fees is charged
  (`lossWad > 0`). Before the fix it scored <= 0.
- `test_feesNew_equalsV4FeesOwed_forKeptPosition`: the fee figure the hook uses equals v4's own owed fees.

A related estimator bug was found by the 500-block honest-curator run: a range abandoned before its markout
settled was credited 0 fees (its ticks were cleared), while the counterfactual got the global upper bound, so an
honest curator that re-centers more often than the markout window bled budget. The hook now snapshots the
range's fee growth at the moment the vault leaves it and compares both sides over the observed interval
(`test_abandonedRange_creditedExactFeesUntilExit`, `test_acceptance_honestStaysFull_500Blocks`).

## 2. The real attack on a poisoned curator: park, then follow (found in M4.1)

**Finding.** A poisoned curator that simply "follows the market" (re-centers on pool spot) gives an attacker
nothing. To pull spot away from fair, the attacker must trade through the vault's existing range, and the vault
earns on the way out what it loses on the way back. The push and the arbitrage back cancel, minus fees.

**The working attack** alternates two decisions, each individually inside the static mandate (width bounds,
distance of range center from fair, no swap, cooldown):
1. When spot equals fair, the curator "anticipates a move" and parks its range away from the price
   (`PoisonedCurator`, `parkOffset = 1500` ticks).
2. The attacker pushes spot cheaply through the thin third-party liquidity (the vault is no longer there).
3. The curator "follows the market" and re-centers on the manipulated spot.
4. The attacker arbitrages spot back to fair through the vault's freshly placed range, buying the vault's token0
   below the fair price.

**Measured** (one round, `test/scenario/ScenarioActors.t.sol::test_attacker_profitsFromPoisonedPlacement`;
pool with 2e23 full-range third-party liquidity, vault of 40k + 40k at price 1, push of 400 ticks):
attacker profit **+421.9 tokens** at the fair price, vault loss **524.1 tokens** (~0.65% of NAV per round).

**Why static caps don't stop it.** No single action breaks a per-action rule, and no transaction is a theft.
**What Tenure does.** A pure re-range at a manipulated spot leaks ~0 immediately (both snapshots are taken at the
same spot), so immediate leakage alone does not catch it. The markout does: after W blocks the new range is
valued at the fair price against the counterfactual of keeping the old range, and the arbitrage that bought the
vault's token0 below fair shows up as negative alpha. That drains the risk budget, so the curator steps down
FULL -> RESTRICTED -> FROZEN after a bounded number of rounds (headline scenario, M4.2). Any swap the curator
makes at the manipulated spot is additionally caught as immediate leakage.

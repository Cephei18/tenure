# PROGRESS

Append-only log written by the loop. Newest at the bottom.

## 2026-11-18T04:00Z — M0.1 Verify scaffold — DONE
What: Merged uniswapfoundation/v4-template (1fbf955) with the kit. Deps added as git submodules pinned to the
template's commits (forge-std 8bbcf6e, hookmate 33408fb, uniswap-hooks v1.1.0 e59fe72). Removed Counter example
hook/test/deploy script after a green build. Created src/{libraries,interfaces,mocks}, sim/, docs/results, test/vectors.
Files: foundry.toml (fs_permissions), .gitignore (docs/ un-ignored), .gitattributes (LF), folders.
Tests: 0 added / 6 passing (template EasyPosm tests). `forge fmt --check` clean.
Notes for human: template README moved to docs/TEMPLATE_README.md. Repo is LF-only via .gitattributes.

## 2026-11-18T04:20Z — M0.2 Reference price — DONE
What: IReferencePrice (fair sqrtPriceX96 + updatedAt per PoolId), MockReferencePrice (settable, emits event),
ReferencePriceLib.readFresh (reverts Tenure__StalePrice / Tenure__InvalidPrice; rejects future timestamps).
Files: src/interfaces/IReferencePrice.sol, src/libraries/ReferencePriceLib.sol, src/mocks/MockReferencePrice.sol, test/unit/ReferencePrice.t.sol
Tests: 7 added / 13 passing. foundry.toml [fuzz] runs=256 with fixed seed.
Notes for human: none

## 2026-11-18T05:00Z — M1.1 Python reference model — DONE
What: sim/model.py integer layer (exact ports of TickMath.getSqrtPriceAtTick, SqrtPriceMath amount deltas,
FullMath mulDiv/up) + Fraction ideal layer. Holdings, NAV at fair price, leakage, markout alpha, loss/gain WAD,
leaky-bucket budget with tiers, reputation (bMax + deposit cap).
Files: sim/model.py, sim/test_model.py
Tests: 39 python tests passing; forge suite unchanged (13).
Notes for human: spec choices (also in docs/MATH.md later):
  1. restore() lands budget at restore_wad=35% of bMax (spec's bMax/2 would be exactly 50% = FULL under the >= rule).
  2. Positive alpha grows bMax AND budget by the same delta, so the spent deficit is unchanged (no refill by alpha),
     and the tier can't drop because bMax grew. While FROZEN, budget is untouched.
  3. Losses decay reputation (cumAlpha -= loss, floored at 0) before charging the budget.
  4. No refill while FROZEN (sticky).

## 2026-11-18T05:30Z — M1.2 Test vectors — DONE
What: sim/gen_vectors.py writes 6 vector files (240 cases each; budget = 12 sequences x 25 ops = 300 states),
seed 0x7E2A, numbers as decimal strings. Freshness test guards against stale vectors.
Files: sim/gen_vectors.py, sim/test_vectors_fresh.py, sim/conftest.py, sim/README.md, test/vectors/*.json
Tests: 40 python passing; forge 13 passing.
Notes for human: none

## 2026-11-18T06:00Z — M1.3 PositionValue library — DONE
What: PositionValue.positionAmounts/holdings/navAt using v4-core TickMath + SqrtPriceMath + FullMath; Holdings and
Range structs. Differential tests match Python vectors EXACTLY (0 wei) for 240 holdings + 240 NAV cases; fuzz
cross-check vs v4-core LiquidityAmounts; rounding-direction fuzz.
Files: src/libraries/PositionValue.sol, test/unit/PositionValue.t.sol, test/diff/{VectorReader.sol,PositionValueDiff.t.sol}
Tests: 13 added / 26 passing. pytest 40 passing.
Notes for human: navAt(roundUp) rounds at both nested mulDiv steps, so it can overshoot by ~sqrtP+1 wei — curator-adverse, intended.

## 2026-11-18T06:45Z — M1.4 DecisionScore library — DONE
What: immediateLeakage (from raw range/idle/spot snapshots; returns NAV_before), markoutAlpha, lossWad (ceil),
gainWad (floor). Exact no-op short-circuit => doing nothing scores exactly 0 (mirrored in model.py score_leakage /
markout_alpha; vectors include 8 no-op cases each). Leakage vectors now carry spotBefore/spotAfter separately.
Files: src/libraries/DecisionScore.sol, test/unit/DecisionScore.t.sol, test/diff/DecisionScoreDiff.t.sol, sim/model.py, sim/gen_vectors.py, test/vectors/*
Tests: 10 added / 36 forge passing; 40 pytest passing. Diff tests exact (0 wei) on 720 cases; mutation check
(flipping one rounding flag) makes test_diff_alpha fail as expected.
Notes for human: property (c) is checked as "leakage FRACTION of NAV is invariant under token-order flip".

## 2026-11-18T07:15Z — M1.5 RiskBudget library — DONE
What: RiskBudget (Tier enum, BudgetParams, BudgetState): validate, init, tierFor, bMaxFor, depositCap, refill,
charge, credit, restore. Differential test replays 12x25 op sequences from budget.json and checks the full state
after all 300 ops (all tiers + restore covered). Fuzz: budget<=bMax, floor at 0, bMax bounds, tier monotonic,
refill never lifts FROZEN, random-walk stickiness.
Files: src/libraries/RiskBudget.sol, test/unit/RiskBudget.t.sol, test/diff/RiskBudgetDiff.t.sol, test/utils/TenureDefaults.sol
Tests: 14 added / 50 forge passing; 40 pytest.
Notes for human: test/utils/TenureDefaults.sol must stay equal to sim/model.py BudgetParams defaults.

## 2026-11-18T07:45Z — M1.6 Slow-bleed proof — DONE
What: 200 poisoned rebalances (each swaps 10% of NAV at 0.5% below fair => ~5 bps leak, under a 1%/action static
cap). Static caps allow 200/200 and lose 951 bps. Tenure: FULL -> RESTRICTED (~action 25, mandate move cap /4) ->
FROZEN at action 57; loss 174 bps, bounded by bMax0 + refill + one overdraw.
Files: test/scenario/SlowBleed.t.sol, docs/results/slow_bleed.csv
Tests: 1 added / 51 forge passing.
Notes for human: the poisoned curator is modeled as re-buying token0 at fair off-pool so its inventory doesn't run
out (keeps the bleed rate constant; makes the static-cap loss conservative rather than inflated).

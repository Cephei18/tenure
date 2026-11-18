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

## 2026-11-18T09:00Z — M2.1 TenureHook skeleton + M2.2 Measured sessions — DONE (one commit; same files)
What: TenureHook on OZ BaseHook (beforeAdd/RemoveLiquidity + afterSwap; no return-delta perms), owner-set
registerPool(key, vault, oracle, maxOracleAge). Transient session flag per pool (REBALANCE / PRORATA).
beginRebalance snapshots old range (liquidity read from PoolManager), vault token balances, spot and FRESH fair price
before unlock; beforeAdd records the single new range from the PoolManager callback params; endRebalance re-reads
the position, rejects orphaned liquidity, updates the tracked range. Pro-rata sessions may only scale the current
range. Third-party LPs unaffected. Salt must be 0 for vault positions.
Files: src/TenureHook.sol, test/TenureHook.t.sol, test/utils/{TenureTestBase.sol,TestActors.sol}
Tests: 22 added / 73 passing.
Notes for human: forge 1.8.5 clears transient storage between top-level calls inside a test, so in-tx session
behavior is tested through single vault calls (beginAndRead/beginThen). Recorded in CLAUDE.md Learnings.

## 2026-11-18T10:30Z — M2.3 Mandate enforcement — DONE
What: Mandate{minWidth,maxWidth,maxCenterDist (vs FAIR tick),maxMoveWad,cooldown} + oracle staleness, enforced at
endRebalance/beginRebalance; RESTRICTED doubles minWidth & cooldown and halves maxMove. "Moved" = value converted
between tokens (|delta total token0| at fair) - re-ranging without a swap moves ~0. Timelocked
propose/execute/cancel with events. registerPool now takes PoolSettings (oracle age, window W, maxSettleDev, mandate,
budget params). Hook source also contains the M2.4/M2.5 logic (scoring, records, settle, afterSwap, safe mode,
restore) - tested in the next two tasks.
Files: src/TenureHook.sol, test/TenureHookMandate.t.sol, test/utils/{HookFixture.sol,TestActors.sol,TenureTestBase.sol}, foundry.toml
Tests: 20 added / 93 passing.
Notes for human: optimizer enabled (runs 200). TenureHook is 26KB without via-IR, 21KB with it: added
[profile.deploy] via_ir=true for anvil/testnet; default profile stays non-IR for fast tests.

## 2026-11-18T11:15Z — M2.4 Scoring + records — DONE
What: endRebalance scores immediate leakage via DecisionScore, charges RiskBudget, stores RebalanceRecord, emits
RebalanceScored. settle(id) after W blocks (TooEarly / AlreadySettled / UnknownRecord / SpotOffFair / stale oracle)
computes markout alpha == library value on the stored record; alpha<0 charges + decays reputation, alpha>0 grows
bMax & deposit cap without refilling the deficit. afterSwap settles <= 3 due records per swap (scan <= 6), never
reverts the trader (stale/broken oracle, spot off fair, open vault session => skip).
Files: test/TenureHookScoring.t.sol, snapshots/TenureHook.json
Tests: 16 added / 109 passing. Gas: swap 117,755 (0 due) / 247,995 (1 due) / 322,432 (3 due).
Notes for human: the poisoned-placement test is the core attack (place liquidity at manipulated spot, attacker
arbs back): no theft tx, but negative alpha is charged. Honest LP-ing also pays a small IL charge in alpha until
fees are counted (stretch S1); the refill rate must cover that - tune in the M4 scenario.

## 2026-11-18T12:00Z — M2.5 Freeze + safe mode — DONE
What: FROZEN blocks beginRebalance (Tenure__Frozen); sticky under any amount of refill; safe-mode session (remove
only, must end with zero liquidity) and pro-rata (withdrawals) allowed in every tier; guardian requestRestore ->
timelock (blocks) -> restore lands RESTRICTED at 35% of bMax; TierChanged events FULL->RESTRICTED->FROZEN;
settlements keep applying while frozen; setGuardian owner-only.
Files: test/TenureHookFreeze.t.sol (+ tests switched to vm.getBlockNumber/getBlockTimestamp)
Tests: 12 added / 121 passing under BOTH the default and the via-IR deploy profile.
Notes for human: via-IR caches block.number inside a test function, so tests must use vm.getBlockNumber() /
vm.getBlockTimestamp() (recorded in Learnings).

## 2026-11-18T14:45Z — M2.6 Proportional budget scaling + pump bound — DONE
What: positive alpha now scales the budget by bMax'/bMax (floor) instead of adding the new headroom, so
budget/bMax is preserved and success never changes the tier. k <= 1e18 enforced (Tenure__ReputationGainTooHigh).
Model updated first, vectors regenerated (budget.json changed), then RiskBudget.sol. Pump-bound argument in
docs/MATH.md (new file; M6.2 extends it).
Files: sim/model.py, sim/test_model.py, test/vectors/budget.json, src/libraries/RiskBudget.sol,
test/unit/RiskBudget.t.sol, test/TenureHook.t.sol, test/TenureHookScoring.t.sol, docs/MATH.md,
.claude/skills/tenure-math/SKILL.md, CLAUDE.md
Tests: 6 added / 127 passing (default profile). `FOUNDRY_PROFILE=deploy forge build` OK. sim: 43 passed.
Decisions made:
- The task says "enforce k <= 1e18 in the constructor", but the hook constructor takes no budget params: k is a
  per-pool BudgetParams field set in registerPool. Enforced in RiskBudget.validate, which registerPool calls;
  tested at both library and hook level.
- credit() keeps the current tier instead of recomputing it. With floor scaling, a curator exactly on a threshold
  could otherwise lose a tier to a 1-wei rounding artifact, contradicting "success never changes tier".
- Two old tests asserted the old additive rule (deficit preserved): test_credit_keepsDeficit_growsCaps (unit,
  sim) and the deficit assertion in test_goodExit_positiveAlpha_growsReputationOnly. They were REPLACED with the
  new rule's assertions (spec change, not weakening).
- Pump test measures "extractable value" as the exact largest loss that leaves the curator un-frozen (binary
  search). A slow-bleed variant allows one 0.01% step of granularity; the exact one has no tolerance.
  Mutation-checked: the exact test fails for k in [2e18, 3e18].
Notes for human: the pump test is at RiskBudget level (pay X = credit X). A hook/vault-level version (attacker
literally trades value into the vault) fits better in M5.2 once CuratedVault exists.

## 2026-11-18T15:40Z — M3.1 CuratedVault — DONE
What: src/CuratedVault.sol: ERC20 shares priced at NAV at the FAIR price (deposit value rounded down, NAV rounded
up); deposit guard (|spot - fair| <= maxDepositDeviation ticks, fresh oracle); deposit cap = hook.depositCap
(reputation); withdrawals pro-rata IN KIND with no tier check, no oracle read and no price (work when FROZEN,
with a stale oracle, and at a manipulated spot); curator-only rebalance (begin -> unlock(remove all, swap, add)
-> end); enterSafeMode (curator or owner); owner can replace the curator.
Files: src/CuratedVault.sol, test/CuratedVault.t.sol, test/utils/VaultFixture.sol, CLAUDE.md
Tests: 18 added / 145 passing. `FOUNDRY_PROFILE=deploy forge build` OK. CuratedVault 16.4KB.
Decisions made:
- Inflation defense = 1e6 dead shares minted to 0xdEaD on the first deposit (Uniswap v2 style), plus
  ZeroShares/minShares checks. Chosen over ERC4626 virtual offsets because withdrawals are pro-rata in kind by
  real supply; a virtual offset would not absorb a donation there. Test: attacker loses ~all of a 20k donation,
  victim loses < 0.01%.
- Deposits stay idle until the curator's next measured rebalance (no unmeasured liquidity change at deposit).
- Withdraw removes floor(L * shares / supply) in a hook pro-rata session; fees collected by that removal are
  shared pro-rata like idle balances (principal = callerDelta - feesAccrued goes to the withdrawer in full).
- rebalance(params) was implemented here because the tier tests need measured rebalances; M3.2 adds the
  end-to-end reconciliation test and any hardening.
- ERC20 currencies only (native ETH reverts in the constructor) for the MVP.
Notes for human: shares/NAV use hook views (currentRange, settingsOf, configs) so the vault and the hook agree on
the position; the vault recomputes NAV with its own rounding direction rather than calling hook.navOf (which
always rounds down).

## 2026-11-18T16:10Z — M3.2 rebalance(params) — DONE
What: end-to-end test (deposit -> rebalance with swap -> market swaps through the range -> re-range -> settle
via settle() and via afterSwap -> partial withdraw with live position -> safe mode -> full exit). A per-token
ledger checks after every step that the vault's idle balance == deposits - withdrawals + net PoolManager flows
(measured independently as the PoolManager's token-balance change), and every user receives exactly the returned
amounts; after safe mode, withdrawals equal floor(idle * shares / supply) exactly. Also: FROZEN curator's vault
rebalance reverts with Tenure__Frozen while safe mode + withdraw still work; an unfundable rebalance reverts
atomically (no position change, no record, no open session).
Files: test/CuratedVaultE2E.t.sol (rebalance itself landed in M3.1)
Tests: 3 added / 148 passing. Deploy build: src/ unchanged since M3.1 (deploy build OK there); test-only task.
Decisions made: an unfundable rebalance surfaces the token's own balance-underflow panic rather than a custom
error (the vault does not pre-compute amounts; the PoolManager/settle path is the source of truth).
Notes for human: none

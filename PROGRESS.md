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

## 2026-11-18T17:20Z — M3.3 Fees in alpha — BLOCKED
What: implemented end to end (model, vectors, library, hook, vault NAV) but it breaks an existing gas guard
(afterSwap with one due record: 191,924 > 150,000). Loosening that assertion is a test weakening, so the work is
saved on local branch `wip/m3.3-fees` and main is back at M3.2. Details + recommendation in BLOCKERS.md.
Decisions made (on the branch): fee estimates are exact when the range's ticks are initialized at settlement and
inside <= global growth; otherwise curator-adverse fallback (new range -> 0, counterfactual -> L * global delta).
H_before/H_after and NAV include uncollected fees on the vault position (fixes leak masking by collected fees).
Notes for human: please choose (a)/(b)/(c) in BLOCKERS.md. I recommend (a).

## 2026-11-18T18:05Z — M4.1 Scenario actors — DONE
What: test/scenario/ScenarioActors.sol: Market (seeded random walk of the FAIR tick + noise trade + arbitrage
of spot back to fair), HonestCurator (re-centers on fair when drift > threshold, refuses to act when spot is off
fair), PoisonedCurator (honest until poison(); then parks the range away from the price when spot == fair and
re-centers on the manipulated spot otherwise - every action inside the static mandate), Attacker (push spot off
fair, arbitrage back; profit measured at the fair price). All curator actions go through the real CuratedVault.
Files: test/scenario/ScenarioActors.sol, test/scenario/ScenarioActors.t.sol, test/utils/VaultFixture.sol
Tests: 5 added / 153 passing. `FOUNDRY_PROFILE=deploy forge build` OK.
Decisions made:
- A poisoned curator that only "follows spot" gives the attacker nothing: the push trades through the vault's
  existing range and loses what the arb-back gains. The realistic exploit needs asymmetry, so the poisoned policy
  alternates "park away" (lets the attacker push cheaply) and "follow spot" (gets arbitraged). One round: attacker
  +422 tokens, vault -524 (pool with 2e23 full-range third-party liquidity; VaultFixture depth is now overridable).
- Honest curator stays FULL over 200 blocks of a +-30 tick/step walk WITHOUT fees in alpha (M3.3 blocked).
Notes for human: none

## Handoff — 2026-11-18T18:10Z
Where I stopped: after M4.1 (commit 9584ee4). main is green: 153 tests, sim 43 passed, deploy build OK.
Done this session: M2.6, M3.1, M3.2, M4.1. Blocked: M3.3 (see BLOCKERS.md; work on branch wip/m3.3-fees).
Next: M4.2 headline scenario. Building blocks are ready in test/scenario/ScenarioActors.sol:
  - Use VaultFixture with _thirdPartyLiquidity() = 2e23 (as ScenarioActorsTest does) so attacks pay.
  - Run A: HonestCurator + Market (seeded). Without fees it stayed FULL for 200 blocks of a +-30 tick walk;
    check 500+ blocks before relying on it - if A dips below FULL, that is the M3.3 decision biting.
  - Runs B/C: PoisonedCurator poisoned at block N; per round: act (parks away) -> roll cooldown ->
    attacker.push(-400) -> act (follows spot) -> attacker.arbBack(). Run B = "static caps only": same vault but
    a hook registered with a huge budget (bMax0 = bMaxCap = 1e18) so tiers never bind, or count rounds the
    static mandate allows; Run C = normal Tenure params. Record per-block NAV, budget, tier to
    docs/results/headline.csv (fs_permissions already allow ./docs/results).
Half-understood: positive-alpha settlements now scale the budget proportionally (M2.6); a poisoned curator that
alternates park/follow may score positive alpha on some "park" records - harmless for tiers (credit never changes
tier) but visible in the CSV.

## 2026-11-18T19:30Z — M3.3 Fees in alpha — DONE (blocker resolved: option (a), human decision)
What: merged wip/m3.3-fees. Holdings/NAV include uncollected fees (fixes leak masking); markout credits each side
the fees its range earned (exact when readable; curator-adverse fallback otherwise). New in this step: when the
vault abandons a range before its markout settles, the hook snapshots that range's fee growth at the exit point
and compares both sides over [t, exit]. Gas bound on afterSwap-with-one-due-record raised per the decision.
Files: src/TenureHook.sol, src/CuratedVault.sol, src/libraries/DecisionScore.sol, sim/*, test/vectors/fees.json,
test/TenureHookFees.t.sol (new), test/TenureHookScoring.t.sol, test/diff/DecisionScoreDiff.t.sol,
test/CuratedVault.t.sol, snapshots/TenureHook.{default,deploy}.json, docs/MATH.md, docs/THREAT_MODEL.md (new),
.claude/skills/tenure-math/SKILL.md (section 4b), CLAUDE.md, PLAN.md (M5.4), BLOCKERS.md
Tests: 8 added / 161 passing. sim 47 passed. Deploy profile compiled (gas test run under it).
Gas (afterSwap overhead, one due record): default 193,854 / deploy 192,771 -> bound 213,240 (higher + 10%).
Decisions made:
- Acceptance run: seeded Market (fair walk +-40 ticks/block, noise trades up to 2,000 tokens, arbitrage to fair),
  HonestCurator re-centering beyond 120 ticks, default budget (bMax0 2%, refill 2%/7200 blocks): 19 decisions,
  FULL in all 500 blocks, minimum budget ratio 94.1%. The refill rate was NOT tuned.
- The first run of that test failed (dropped to RESTRICTED). Diagnosis: the fee-free alpha of each re-center was
  ~+-20 tokens, but ranges abandoned before settlement were credited 0 fees (ticks cleared) while the
  counterfactual got the global upper bound (~300 tokens). That was an estimator bug in my M3.3 code, so I fixed
  the measurement (exit snapshot) instead of tuning the refill rate, which would only have hidden it.
- test_withdraw_inEveryTier first leak resized 4,000 -> 3,000 tokens: with fees no longer masking part of the
  leak, the old size jumped straight past RESTRICTED. The test still walks FULL -> RESTRICTED -> FROZEN.
Notes for human: the counterfactual fallback (old range abandoned -> L_old * global fee growth) is deliberately
pessimistic for the curator; documented in docs/MATH.md as a known limitation.
- Contract size: with the fee code TenureHook hit 24,979 B under via-IR (over EIP-170). Fixed without changing
  behavior: removed the unused hook.navOf (the vault prices shares with its own nav(bool)), and moved fees-owed
  (new src/libraries/FeesOwed.sol) and the spot/fair deviation check into the vault. Now 24,460 B (116 B headroom)
  at the normal 200 runs. M5.4 adds code: it must make room (lower deploy optimizer_runs or move views out).

## 2026-11-18T21:00Z — M4.2 Headline scenario test — DONE
What: test/scenario/Headline.t.sol runs one seeded market (fair walk +-20 ticks/block, noise trades, arbitrage)
three times from the same clean state (vm.snapshotState/revertToState), 600 blocks each, poison at block 100,
default budget (2% of NAV):
  A honest + Tenure:          FULL in all 600 blocks (asserted every block), final NAV 81,521 tokens
  B poisoned + static caps:   25 attack rounds, -4,197 tokens vs A (~5% of NAV), attacker +1,563
  C poisoned + Tenure:        RESTRICTED at block 160, FROZEN at 170 after 3 rounds -> safe mode,
                              -1,261 vs A (includes fees forgone while idle), attacker +625
Per-block NAV, budget ratio and tier for all runs: docs/results/headline.csv (600 rows).
Files: test/scenario/Headline.t.sol (new), test/scenario/ScenarioActors.sol, test/utils/VaultFixture.sol,
test/TenureHookFees.t.sol, docs/THREAT_MODEL.md, docs/results/headline.csv
Tests: 1 added / 162 passing. `FOUNDRY_PROFILE=deploy forge build` OK.
Decisions made:
- Run B = the same hook with bMax0 = bMaxCap = 100% of NAV, so only the static mandate binds.
- The attacker strikes only when the curator is out of cooldown (otherwise it pays for pushes that capture
  nothing). Attacker profit is summed per round at that round's fair price (its 10M-token inventory is not
  marked to the random walk).
- PoisonedCurator now re-balances inventory (swap <= 5% of NAV toward 50/50 at fair, inside the 20% move cap) when
  it parks. Without it the bleed decays geometrically and run B looked harmless. This changed the M4.1 per-round
  vault loss from 524.1 to 446.0 tokens (attacker profit unchanged at 421.9); THREAT_MODEL updated.
- Simulation test pauses gas metering (3 x 600 blocks exceeds the 2^30 per-test gas limit); the CSV is streamed
  with vm.writeLine (string.concat accumulation is quadratic in memory gas).
- VaultFixture._vaultSettings is now `view` (run B switches params via a storage flag).
Notes for human: loss(C) vs loss(B) is 3.3x at 600 blocks and widens linearly with run length (C is frozen).
"Loss vs A" counts A's fee income, so C's figure includes ~430 blocks of forgone fees, not only attack damage.

## Handoff — 2026-11-18T21:15Z
Where I stopped: after M4.2 (commit 02166b6). main is green: 162 tests, sim 47 passed, deploy build OK.
Done since the last handoff: M3.3 (merged, exit-snapshot fix, gas bound per human decision), M4.2.
Next: M4.3 charts. docs/results/headline.csv columns: block, navA, ratioA, tierA, navB, ratioB, tierB, navC,
ratioC, tierC (NAV in token1 wei at the fair price; ratio = budget/bMax in WAD; tier 0 FULL / 1 RESTRICTED /
2 FROZEN). Plot NAV for A/B/C (or NAV minus A to remove the market walk - clearer), budget ratio for C with the
50% / 20% thresholds and tier changes marked (C: RESTRICTED at 160, FROZEN at 170), poison at block 100.
docs/results/slow_bleed.csv exists from M1.6.
Watch out: TenureHook is 24,460 B under the deploy profile (limit 24,576). Any hook change (M5.4!) must re-check
`FOUNDRY_PROFILE=deploy forge build --sizes`; options are in foundry.toml.

## 2026-11-18T22:00Z — M4.2b Seed sweep — DONE
What: headline runner moved into abstract HeadlineBase (Headline.t.sol); test/scenario/Sweep.t.sol runs A/B/C
over 20 seeds. _runBC asserts B and C have identical curator and attacker codehash and identical hook settings
except bMax0/bMaxCap. Per-seed rows: docs/results/sweep.csv; summary table + interpretation: docs/RESULTS.md.
Results (median / worst): B loss vs A 6,450 / 7,435; C loss vs A 3,729 / 4,520; attacker profit B 1,586 vs C 650;
C frozen on 20/20 seeds, 60-76 blocks after poison; A FULL in every block of every seed (min ratio 83.1%).
Acceptance: A FULL on every seed (asserted); C worst (4,520) < B median (6,450).
Files: test/scenario/Headline.t.sol, test/scenario/Sweep.t.sol (new), test/scenario/ScenarioActors.sol,
docs/RESULTS.md (new), docs/results/sweep.csv, CLAUDE.md
Tests: 1 added / 163 passing. `FOUNDRY_PROFILE=deploy forge build` OK.
Decisions made:
- "Loss vs A" is reported as specified, but RESULTS.md explains it mixes attack damage with market divergence
  (B and C share most of it; the B - C gap is stable at 2,571-2,938 tokens). Attacker profit is given as the
  cleaner damage measure.
- Seeds: keccak256("tenure-sweep", k), k = 0..19. Headline seed 0x7e2a is unchanged.
Notes for human: the first sweep run printed identical numbers for every seed - vm.revertToState was resetting
the test contract's `seed` variable. Fixed (seed set after each revert) and guarded by an assertion that
different seeds produce different markets. On 5 seeds C goes FULL -> FROZEN without a sampled RESTRICTED block
(two markouts settle in one block).

## Handoff — 2026-11-18T22:10Z
Where I stopped: after M4.2b (commit 9385ac5). main is green: 163 tests, sim 47, deploy build OK.
Next: M4.2c contract-size headroom (need >= 2,000 B under 24,576; now 24,460 B = 116 B headroom).
What I already measured (deploy profile, before FeesOwed/navOf removal, hook was 24,979 B): optimizer_runs 200 ->
100 saved ~430 B, 100 -> 30 saved only ~70 B more. So runs alone cannot reach 2 KB; plan on moving code out:
  - candidates: the fee-window logic (_windowFees/_exitedFees/_fees/_insideGrowth + windowFees view) and
    _checkMandate/_score math into an external library with `public` functions, or a separate stateless
    "TenureScorer" contract the hook calls (simpler to deploy than a linked library: no link step in
    deployCodeTo). External calls add gas to settle: re-measure test_gas_afterSwap_dueRecords under BOTH
    profiles; if it exceeds 213,240, record it under Decisions made (the task allows it) - do NOT loosen it
    silently.
  - Check `FOUNDRY_PROFILE=deploy forge build --sizes` after each step (a full via-IR build takes ~4 min).
Then: M4.3 charts (CSV layouts are in the M4.2 handoff above), M4.4 demo script, M5.x hardening.

## 2026-11-22T14:05Z — M4.2c Contract size headroom — DONE
What: the hook's heaviest pure math moved into a new EXTERNAL (linked) library, src/libraries/TenureScorer.sol:
scoreRebalance (immediate leakage + "moved" fraction), alphaWithFees, windowFees (fee estimate from raw
accumulators), chargeLeak, applyMarkout, tickAt, tickDistance. All `external pure` thin wrappers over the existing
internal libraries (which stay the single source of truth with their differential tests); all state and
authorization stay in the hook. Deploy profile sizes: TenureHook 24,460 -> 21,907 B (2,669 B headroom),
TenureScorer 6,302 B, CuratedVault 16,395 B (unchanged).
Linking: forge links the library automatically for deployCodeTo/vm.getCode in tests and for forge script.
New script/DeployTenureHook.s.sol (HookMiner CREATE2, asserts the mined address == deployed address) dry-runs
in memory and was broadcast to a fresh anvil: hook deployed, runtime 21,907 B, owner() reads back.
Files: src/libraries/TenureScorer.sol (new), src/TenureHook.sol, test/unit/TenureScorer.t.sol (new),
script/DeployTenureHook.s.sol (new), snapshots/TenureHook.{default,deploy}.json, foundry.toml, CLAUDE.md, PLAN.md
Tests: 12 added / 175 passing (default profile) and 175 passing under FOUNDRY_PROFILE=deploy. forge fmt OK.
Scenario CSVs (headline, sweep, slow_bleed) regenerate byte-identical -> refactor is behavior-preserving.
Decisions made:
- Gas increase (external DELEGATECALLs + ABI encoding of structs), afterSwap overhead vs 0 due records:
    one settlement   default 193,854 -> 205,734 (+11,880)   deploy 192,771 -> 202,553 (+9,782)
    three            default 294,138 -> 333,434              deploy 290,762 -> 322,690
  Both stay under the existing bounds (213,240 for one; 400,000 for three); no assertion was changed.
  Headroom on the one-settlement bound is now ~7.5k (default) / ~10.7k (deploy): M5.4 should claw gas back
  (struct packing, fewer external hops) before adding anything to afterSwap.
- TenureScorer.test_hookSize_headroomUnderDeployProfile asserts size + 2,000 <= 24,576 when
  FOUNDRY_PROFILE=deploy (the default, non-IR profile is test-only, ~28 KB, and only logs its size).
- Scripts must not import v4-core PoolManager.sol (pins solc =0.8.26); use hookmate's V4PoolManagerDeployer.
Notes for human: deploy the hook with FOUNDRY_PROFILE=deploy; forge script deploys TenureScorer automatically
(one extra tx). To reuse one library across deployments pass
`--libraries src/libraries/TenureScorer.sol:TenureScorer:<addr>`.

## 2026-11-22T14:06Z — M4.3 Charts — DONE
What: sim/plot_results.py renders three PNGs from the committed CSVs into docs/results/:
- headline.png: runs B and C on the same axes as "NAV minus honest run A" (removes the shared market walk), with
  poison (block 100), C RESTRICTED (160) and C FROZEN -> safe mode (170) marked; second panel: budget/bMax for A
  and C with the 50% / 20% tier thresholds. End values labeled directly (B -4,197, C -1,261).
- sweep.png: per-seed B vs C loss as a dumbbell chart sorted by B loss, with B median (6,450) and C worst (4,520)
  marked - the M4.2b acceptance claim is visible at a glance.
- slow_bleed.png: cumulative loss, static cap vs Tenure, RESTRICTED at action 22, FROZEN at 57.
docs/RESULTS.md embeds all three; sim/README.md documents the command.
Files: sim/plot_results.py (new), sim/test_plot_results.py (new), docs/results/{headline,sweep,slow_bleed}.png,
docs/RESULTS.md, sim/README.md, PLAN.md
Tests: 2 added / sim 49 passed (python -m pytest sim -q). No Solidity change (forge suite unchanged: 175).
Decisions made:
- Fixed categorical colors by entity (A blue, B orange, C aqua) from the dataviz default palette; one y-axis per
  panel (no dual axes); tier marks are read from the CSV, not hard-coded (a test asserts poison < RESTRICTED <=
  FROZEN and that A has no tier marks).
- Labels floor to whole tokens so they match RESULTS.md (B median 6,450.58 -> 6,450).
Notes for human: after any scenario change, rerun forge test (rewrites the CSVs) then python sim/plot_results.py.

## 2026-11-22T16:11Z — M4.4 Local demo script — DONE
What: two-part anvil demo of scenario C (poisoned curator + Tenure), documented in docs/DEMO.md.
- script/Demo.s.sol (FOUNDRY_PROFILE=deploy, chain 31337 only) deploys everything for real: PoolManager
  (hookmate pinned bytecode), mock tokens, TenureHook via HookMiner CREATE2 (+ auto-linked TenureScorer), mock
  oracle, 1:1 pool with 2e23 full-range third-party liquidity (DemoLiquidity), CuratedVault + 40k/40k deposit,
  the scenario actors from test/scenario (seeded Market 0x7e2a, PoisonedCurator, Attacker) and a DemoDirector.
- script/demo/DemoActors.sol: DemoDirector.tick() = one scenario block (mirrors HeadlineBase's per-block body and
  _attackStep); status()/note() give readable log lines; owns the vault only to enter safe mode once FROZEN.
- script/demo.sh: deploy, then one tick() transaction per block (anvil mines one block per tx, so cooldowns and
  the 50-block markout window are real blocks), then the depositor withdraws everything while FROZEN.
- script/base/TenureHookDeployer.sol: shared HookMiner deployment (DeployTenureHook now uses it).
Result on a fresh anvil (run twice, identical): poisoned at tick 20, 3 attack rounds (attacker +613), FULL ->
FROZEN at tick 80 (budget 55.8% -> 2.9% when markouts settled), safe mode, all 110 ticks succeeded, depositor
redeemed all shares while FROZEN (2,564.74 token0 + 77,071.60 token1). ~1.5 min with a warm build.
Files: script/Demo.s.sol, script/demo.sh, script/demo/DemoActors.sol, script/base/TenureHookDeployer.sol (new),
script/DeployTenureHook.s.sol, docs/DEMO.md (new), PLAN.md
Tests: 0 added / 175 passing (default). Demo verified end-to-end on anvil (acceptance). forge fmt OK.
Decisions made:
- A single forge script cannot replay a multi-block scenario (its simulation runs every tx in one block; vm.roll
  does not move a live chain), hence script + per-block transactions from bash.
- demo.sh sends ticks with a fixed 25M gas limit and checks every receipt. The first run used cast's gas
  estimate and 3 of 110 ticks reverted on-chain silently (cast send exits 0 on a reverted receipt); the curator's
  try/catch makes eth_estimateGas unreliable. The script now aborts on any failed tx and asserts ticks == TICKS.
- POISON_AT defaults to 20 (not 100) to keep the demo short; numbers therefore differ slightly from the
  600-block headline, shape identical.
- No Foundry test runs the demo: under the default (non-IR) profile the hook is over EIP-170, so a CREATE2
  deploy inside a test would fail; the acceptance is the live anvil run. Demo.s.sol keeps its deployments in
  storage so it still compiles under the default profile (stack-too-deep otherwise).
Notes for human: run `anvil` then `bash script/demo.sh` (Git Bash on Windows). Good material for the video.

## 2026-11-22T16:28Z — M4.6 Chainlink reference price — DONE
What: src/ChainlinkReferencePrice.sol implements IReferencePrice from Chainlink feeds, outside the hook. Two
modes per pool: token0/USD + token1/USD, or one direct token0/token1 feed (feed1 = 0). Conversion in
src/libraries/ChainlinkPriceLib.sol: P = a0*10^(fd1+dec1) / (a1*10^(fd0+dec0)); sqrtPriceX96 =
floor(sqrt(P*2^192)) for P < 2^64, else floor(sqrt(P*2^128)) << 32 (relative error < 2^-96); range-checked.
Staleness: returns the OLDER feed's updatedAt; the hook enforces maxOracleAge. Non-positive answers and incomplete
rounds (updatedAt == 0 or answeredInRound < roundId) revert. Feeds are set once per pool (owner), never replaced.
AggregatorV3Interface vendored (interface only) in src/interfaces/. Model first: sim/model.py
chainlink_sqrt_price_x96 + ideal layer; 240 vectors (test/vectors/chainlink.json; earlier vector files unchanged).
Files: src/ChainlinkReferencePrice.sol, src/libraries/ChainlinkPriceLib.sol, src/interfaces/AggregatorV3Interface.sol,
test/ChainlinkReferencePrice.t.sol, test/diff/ChainlinkPriceDiff.t.sol, test/utils/MockAggregator.sol,
sim/model.py, sim/test_model.py, sim/gen_vectors.py, sim/test_vectors_fresh.py, test/vectors/chainlink.json,
sim/README.md, docs/MATH.md, docs/THREAT_MODEL.md (section 3), PLAN.md
Tests: 16 added / 191 passing. sim 53 passed. Deploy build OK: ChainlinkReferencePrice 2,987 B; hook unchanged
(21,907 B). forge fmt OK.
Acceptance: unit + fuzz vs mock aggregators incl. decimals 6/8/18 (parity fuzz: equal USD prices + equal token
decimals => exactly Q96 for every feed-decimals combination; token-decimals fuzz checks the floor bracket),
stale (older feed wins; ReferencePriceLib.readFresh reverts Tenure__StalePrice), negative/zero answers,
incomplete rounds; differential: all 240 vectors exact through the adapter with mock feeds, including the
27 revert cases.
Decisions made:
- Feeds immutable per pool (owner could otherwise choose the scoring price). Decimals capped at 36.
- An invalid answer REVERTS rather than returning 0: readFresh reverts either way, and afterSwap's try/catch
  skips settlement, so swaps are never blocked.
- No feed-vs-TWAP deviation guard yet (listed as residual risk in THREAT_MODEL section 3).
Notes for human: for a testnet deploy, use real Chainlink feed addresses for the chain (e.g. ETH/USD and USDC/USD
on Unichain Sepolia / Base Sepolia, if available) and pass token decimals explicitly to setFeeds.

## 2026-11-22T17:18Z — M5.4 Settlement gas — DONE
What: per-pool PoolSettings.autoSettlePerSwap (0 = off: keepers settle, swappers pay nothing; 1 = on), validated
at registerPool (> 1 reverts Tenure__InvalidSettings). afterSwap auto-settle capped at ONE record per swap
(MAX_AUTO_SETTLE 3 -> 1); the scan still skips past keeper-settled records so the pointer never stalls.
New permissionless settleMany(id, ids): skips unknown / settled / not-due ids, reverts only on a stale oracle or
spot off fair (shared _settlementPrices with settle). Gas: BudgetState is now written once per settle/score
(_refilledMem keeps the refill's TierChanged event). README.md (new, stub until M6.1) explains the cost model.
Gas (afterSwap overhead vs nothing due):  default / deploy
  1 due, auto on:   205,734 -> 204,822   /  202,553 -> 201,514   (bound 213,240 unchanged)
  3 due, auto on:   333,434 -> 139,155   /  322,690 -> 134,747   (now settles 1; bound tightened 400k -> 213,240)
  3 due, auto OFF:  -2,798 (no settlement) / -2,815
Files: src/TenureHook.sol, test/TenureHookKeepers.t.sol (new), test/TenureHookScoring.t.sol,
test/utils/TenureTestBase.sol, script/Demo.s.sol, snapshots/TenureHook.{default,deploy}.json, README.md (new),
CLAUDE.md, PLAN.md
Tests: 8 added / 199 passing in BOTH profiles. Scenario CSVs (headline, sweep, slow_bleed) byte-identical, so
RESULTS.md, charts and the demo numbers stand. forge fmt OK.
Decisions made:
- test_afterSwap_boundedPerSwap rewritten for the plan's new cap (exactly one settlement per swap, checked on each
  of 5 swaps); this tightens the old "3 per swap" bound, it does not relax it. The 3-due gas bound was tightened
  from 400,000 to the one-settlement bound 213,240.
- The first cap-1 version stalled the settle pointer behind keeper-settled records (caught by
  test_afterSwap_skipsManuallySettled); fixed in the hook, test unchanged.
- Gas reduction is small (~1k): the cost is cold fee-growth reads that fee-aware markouts need (BLOCKERS M3.3
  analysis still holds). Struct packing was not done: it would touch every record/budget read for ~15-20k
  (estimated in M3.3) and the hook has no size headroom left for it.
- Size: settleMany pushed the hook to 22,728 B (1,848 B headroom, guard FAILED under deploy). Deduplicating the
  settle/settleMany price checks brought it to 22,528 B (2,048 B headroom, guard passes by 48 B).
Notes for human: the hook is at the size limit of our own 2,000 B guard. M4.5a must keep the receiver outside
the hook (planned) and move RiskBudget.refill (or similar) into TenureScorer before adding any hook code.

## Handoff — 2026-11-22T17:18Z
Where I stopped: after M5.4 (commit c5da1d5). main is green in BOTH profiles: 199 tests; sim 53 passed;
deploy build OK (TenureHook 22,528 B, TenureScorer 6,302 B, CuratedVault 16,395 B, ChainlinkReferencePrice 2,987 B).
Not pushed (per instructions): origin/main is at 647affa; local main is 7 commits ahead.
Done this session (plan reorder first, commit 504c3fc): M4.2c (linked TenureScorer), M4.3 (charts), M4.4 (anvil
demo), M4.6 (Chainlink adapter), M5.4 (settlement gas, settleMany, README cost model stub).
Next: M4.5a Reactive settlement, then M4.5b, M5.1, M5.2, M5.3, M6.x.
For M4.5a:
  - Needs network: forge install Reactive-Network/reactive-lib and reactive-test-lib at EXACT commits (record
    them in foundry.lock + CLAUDE.md Learnings); read their sources under lib/ before calling anything.
  - The receiver must be a SEPARATE contract calling hook.settleMany(id, ids) (already permissionless, skips
    settled/not-due ids). The pool sets autoSettlePerSwap = 0 (test: TenureHookKeepers gas_afterSwap_autoSettleOff
    already shows zero settlement overhead for swappers).
  - SIZE: the hook has only 48 B above our 2,000 B guard. Do NOT add hook code; if anything must change in the
    hook, first move RiskBudget.refill into TenureScorer (external) and re-measure both gas profiles.
  - [H] items still open: Reactive callback proxy addresses + Lasna funds (needed only for testnet, not for tests).
Watch out:
  - Any test that wraps a call in vm.expectRevert must build its args first (bit me again in M4.6).
  - FOUNDRY_PROFILE=deploy builds take 4-10 min after a default build (shared cache); run them in background.
  - demo.sh uses a fixed 25M gas limit on purpose (gas estimation + curator try/catch silently reverted ticks).

## 2026-11-22T18:06Z — M4.5a Reactive settlement — DONE
What: keeper-free markout settlement via the Reactive Network, adding ZERO bytes to TenureHook (human decision).
- Dependencies: the human's message said reactive-lib / reactive-test-lib were installed, but lib/ did not contain
  them; the task itself says to install them pinned, so I ran forge install at the then-current upstream HEADs:
  reactive-lib f6990ce3526928d039fec78855b2004ff8d65c9f, reactive-test-lib 2ff9b2a68ca9956306ec943c10d1c757c1dd1956
  (commit 0d9a004; foundry.lock keys normalized to forward slashes; remappings reactive-lib/, reactive-test-lib/).
- src/reactive/TenureReactiveReceiver.sol (AbstractCallback): settleMany(rvmId, poolId, ids), authorizedSenderOnly
  (callback proxy) + rvmIdOnly (deployer = RC deployer), forwards to hook.settleMany. 1,209 B.
- src/reactive/TenureSettlerRC.sol (AbstractReactive): subscribes to RebalanceScored + MarkoutSettled (topic1 =
  poolId) and a cron topic; queues record ids due after delayBlocks; on cron sends up to 8 due ids in one callback
  (gas 150k + 300k/record); re-sends an unsettled id at most once per delayBlocks; MarkoutSettled drops ids
  settled by any path; ignores other pools/contracts/chains. 3,437 B.
- test/HookSizeFrozen.t.sol pins the hook runtime size: default 29,180 B, deploy 22,528 B.
Files: src/reactive/*, test/reactive/ReactiveSettlement.t.sol, test/HookSizeFrozen.t.sol, docs/THREAT_MODEL.md
(section 4), PLAN.md
Tests: 10 added / 209 passing in BOTH profiles (reactive-test-lib simulator for all Reactive tests). forge fmt OK.
Deploy sizes: TenureHook 22,528 (unchanged), CuratedVault 16,433 (M5.4 struct change, untouched here).
Decisions made:
- Due-ness in the RC uses a delay in the blocks of the notifications it sees; cron blocks are Reactive-chain
  blocks, so on a real deployment delayBlocks must be set conservatively (>= W origin blocks in Reactive-chain
  time). Early is harmless (hook skips not-due ids); the [H] question to the Reactive dev chat still stands.
- Cron topic is a constructor parameter (the test lib's cron topics are mock values; use the network's on Lasna).
- The relay is a liveness aid only: no trust is needed for correctness (THREAT_MODEL section 4).
Notes for human: please double-check the pinned commits are the versions you intended (lib/ was empty when this
run started).

## 2026-11-22T18:19Z — M4.5b Cross-chain freeze propagation — IMPLEMENTED, deploy-profile verification PENDING (task left [ ])
What: freeze propagation lands in CuratedVault, not the hook (human decision). CuratedVault: freezeReceiver
(owner-set via setFreezeReceiver; 0 = disabled), relayFrozen flag set only by relayFreeze() from that receiver
(idempotent), cleared only by clearRelayFreeze() from hook.guardian(); rebalance reverts Tenure__RelayFrozen while
set; deposits, withdrawals and safe mode unaffected. src/reactive/TenureFreezeReceiver.sol (AbstractCallback, only
freeze(rvmId, vault, srcChain, srcPool)); src/reactive/TenureFreezeRC.sol (TierChanged on both endpoints; relays
only transitions INTO FROZEN, once per episode; resets when that side leaves FROZEN).
Files: src/CuratedVault.sol, src/reactive/TenureFreezeRC.sol, src/reactive/TenureFreezeReceiver.sol,
test/reactive/FreezePropagation.t.sol, docs/THREAT_MODEL.md (section 5)
Tests: 9 added / 218 passing under the DEFAULT profile (includes HookSizeFrozen: hook unchanged at 29,180 B).
NOT YET RUN: FOUNDRY_PROFILE=deploy forge build --sizes and FOUNDRY_PROFILE=deploy forge test - the background
run was killed by Claude Code because the machine was critically low on memory (not a test failure). Per the
rules the task stays [ ] until that passes.
Acceptance status: invariant test (receiver as msg.sender reverts on every vault/hook admin and curator function;
every non-freeze payload via the proxy fails; vault accepts relayFreeze only from its own receiver); A->B with a
real hook driven to FROZEN by measured leaks; B->A via a TierChanged-shaped emitter standing in for chain B's
hook; duplicates relayed once per episode; replayed callbacks idempotent and can never unfreeze; withdrawals and
safe mode work while relay-frozen; THREAT_MODEL section 5 (trust model, replays, no echo, compromised relay =
can only freeze an honest curator, no fund loss).
Decisions made:
- "Local guardian" = the hook's guardian (CuratedVault has none of its own); it already restores FROZEN tiers.
- Chain B's hook is a TierEmitter mock in tests (one EVM cannot host two chains' hooks at the flag address);
  chain B's vault is a real CuratedVault on a second pool of the same hook binary.
Notes for human: run `FOUNDRY_PROFILE=deploy forge build --sizes` (expect TenureHook 22,528 B) and
`FOUNDRY_PROFILE=deploy forge test` (expect 218 passing); if both pass, mark M4.5b [x].

## Handoff — 2026-11-22T18:19Z
Where I stopped: M4.5b implemented and committed; only its deploy-profile verification is pending (see above).
main: default profile 218 tests green; sim 53 (unchanged this session). Not pushed.
Done since the last handoff: deps pinned (reactive-lib f6990ce, reactive-test-lib 2ff9b2a: lib/ did NOT contain
them at the start of this run, so they were installed per the plan), M4.5a (Reactive settlement), M4.5b (above).
TenureHook bytecode is unchanged by both (pinned in test/HookSizeFrozen.t.sol: default 29,180 / deploy 22,528).
Next: verify M4.5b under the deploy profile, then M5.1 invariants, M5.2 attack tests, M5.3 gas report, M6.x.
Watch out: deploy-profile builds are memory-hungry on this machine; run them alone (close other heavy apps).

## 2026-11-23 — M5.3 Gas report — DONE
What: test/GasReport.t.sol measures under isolation (each call its own tx): swaps (hookless baseline, Tenure nothing
due, autoSettle=0 with records due, autoSettle=1 settling one), full CuratedVault rebalance vs the same moves on a
hookless pool (PlainVault mirror), begin/endRebalance (gasleft() inside an instrumented ProbeVault on a second Tenure
pool), settleMany 1/5, deposit, withdraw, deployment of TenureHook (CREATE2 at a mined flag address)/CuratedVault/
TenureScorer. Snapshots: snapshots/GasReport.{default,deploy}.json. Table + method + USD (10 gwei, $3k): docs/GAS.md.
Files: test/GasReport.t.sol, docs/GAS.md, snapshots/GasReport.default.json, snapshots/GasReport.deploy.json
Tests: 11 added / 229 passing (default profile). GasReport.t.sol: 11/11 passing under FOUNDRY_PROFILE=deploy.
Headline (deploy): swap +17,205 over hookless; rebalance 849,110 vs 311,210 without hook (overhead 537,900, ~$16);
begin 175,042 / end 394,345; settleMany 1 = 184,507, 5 = 512,375; deposit 221,046; withdraw 174,970;
deploy hook 4.99M, vault 4.22M, scorer 1.57M.
Decisions made:
- Measured the vault's 3rd rebalance (steady state); a first-ever re-range costs ~100k more once (fresh snapshot slots).
- Verified snapshotGasLastCall includes intrinsic gas and applies refunds (probe test); documented in GAS.md.
- Overhead is mostly by-design storage (13 fresh slots per rebalance: 8-slot record + fee snapshots). Optimizations
  (transient pending snapshot ~40-45k, record packing) recorded in GAS.md, NOT implemented (hook size headroom 48 B).
Notes for human: the full suite under FOUNDRY_PROFILE=deploy was NOT run (memory; still pending from M4.5b) - only
GasReport.t.sol was. Gas figures pin the current code; re-run the command in GAS.md after any hook change.

## 2026-11-23 — Deploy-profile verification (closes M4.5b) + GAS.md follow-ups — DONE
What:
- FOUNDRY_PROFILE=deploy forge test (FULL suite): 229 passed, 0 failed (incl. FreezePropagation 9/9,
  ReactiveSettlement 9/9, HookSizeFrozen). Nothing needed fixing. forge build --sizes (deploy): TenureHook 22,528 B
  (2,048 B under EIP-170), CuratedVault 17,076 B, TenureScorer 6,302 B. M4.5b acceptance met -> marked [x].
- GAS.md: "auto-settle off, records due" (113,808) < "auto-settle on, nothing due" (116,310) is NOT an artifact:
  same setUp/pool state; the 2,502 gap is entirely inside afterSwap (10,931 vs 13,433): with auto=1 the hook must
  cold-load the oldest record's blockNumber to see it is not due; with auto=0 it returns before touching records.
  Added a same-state control (auto=0, nothing due = 113,808, asserted equal to records due) to GasReport.t.sol.
- GAS.md "Cost in context": 537,900 gas/rebalance = $16.14 mainnet vs ~$0.016 on a 1s-block L2 (0.01 gwei assumed),
  against ~3.5% of NAV saved per attack (RESULTS.md sweep); table for $100k/$1M/$10M vaults incl. yearly overhead
  at 4 rebalances/day (mainnet $23.6k/yr: bad for small vaults, fine for large; L2 negligible).
Files: docs/GAS.md, test/GasReport.t.sol, snapshots/GasReport.{default,deploy}.json, PLAN.md
Tests: 229 passing under BOTH default and deploy profiles. fmt clean.
Also fixed: one em dash in this file had been written as a cp1252 byte (0x97) by the M5.3 entry; now UTF-8.
Notes for human: the L2 gas price (0.01 gwei) is an illustrative assumption; adjust to the target chain.

## 2026-11-25 — M5.2 (part): markout window gaming — DONE (M5.2 itself stays open)
What:
- W audit: `PoolSettings.window` is per pool, set by the owner once in registerPool, no setter; the curator cannot
  touch it. Neither a constant nor curator-changeable, so per the request no code change (it cannot change at all,
  so there is nothing to timelock). src/ untouched; hook size unchanged.
- test/attacks/WindowGaming.t.sol (new, first file of the M5.2 attack suite): same attack struck inside vs after W
  from one snapshot. Push -90 (<= maxSettleDev): damage 8.56 tokens; charged 17.29 inside W vs 80,002 wei after W;
  100% realized after grading. Push -400 + partial arb to -100: damage 445.99; charged 484.52 vs 461.73; 13.09
  (2.9%) realized after grading. Grading at -400 reverts SpotOffFair(400,100). 20 repeated -90 rounds (swapless
  park): vault -57.75 (~0.07% NAV), tier FULL, budget untouched; attacker -50.57 (fees exceed take in this pool).
- docs/THREAT_MODEL.md section 6 records W ownership, the table, the limits (maxSettleDev binds; the mandate
  distance rule does not bind this variant; the next rebalance ends exposure but never re-grades the escaped loss;
  holding spot off fair for W blocks is unmodeled) and the planned fix.
- PLAN.md: M5.2 progress note; Part 2 added as M5.5 Lifetime grading, gated on the [H] testnet deploy.
Files: test/attacks/WindowGaming.t.sol, docs/THREAT_MODEL.md, PLAN.md, PROGRESS.md, CLAUDE.md
Tests: 4 added / 233 passing (default). WindowGaming 4/4 under FOUNDRY_PROFILE=deploy. fmt clean.
Decisions made:
- Measured the escape as "damage realized after grading" and "charge inside W minus charge after W", not
  "damage - charged": the curator-adverse fee rule makes the charge exceed the damage inside W.
- The repeated test uses a test-local SwaplessPoisonedCurator: the stock PoisonedCurator's inventory-swap park is
  charged as leakage in this thin pool and FROZEN after one round, which hides the window effect.
Notes for human: the testnet deploy is not done (only anvil broadcasts), so M5.5 was NOT started. The
  repeated-campaign attacker loss is specific to this pool (0.3% fee, 2e23 third-party L); say "grading gap", not
  "profitable attack", in the pitch.

## 2026-11-25 — M5.1 Invariant tests + M5.2 Attack tests (rest) — DONE
What:
- test/invariant/TenureInvariants.t.sol: TenureHandler (deposit, withdraw, random curator decisions, swaps up to
  400 ticks off fair, fair moves, blocks with/without oracle refresh, settleAll, safe mode, guardian restore,
  simulated bank run). 7 invariants: bank run always succeeds, withdraw <= pro-rata (2 wei slack), no orphaned
  vault liquidity, budget/bMax/deposit-cap bounds, FROZEN only lifted by guardian, no session left open, withdrawals
  never blocked. In-tx properties latched in ghost flags. One full-depth campaign (256 x 500 = 128,000 calls)
  passed with 0 reverts; checked-in depth 100 (inline forge-config). Smoke test proves the handler reaches FROZEN,
  stale oracle, restore, bank run.
- test/attacks/OracleAttacks.t.sol (4), BypassAttacks.t.sol (6), Reentrancy.t.sol (3; callback token etched over
  currency0). Results in THREAT_MODEL.md sections 7-10.
Findings:
- Settling at an off-fair spot can only grade a curator BETTER (LP holdings at any spot, valued at fair, >= those at
  fair): honest curators cannot be griefed; an accomplice can INFLATE alpha: +40.08 tokens for 36.11 cost, bMax
  +12.5% (bounded < 0.1% NAV per record, capped by bMaxCap). Candidate fix (value hypothetical holdings at fair)
  recorded for M5.5; it would also close the window-gaming leg.
- settle() runs mid-session (no session check); reachable only via a callback token; strips the curator's fee
  credit (+108.32 -> -2 wei), never helps it. Not fixed (48 B hook headroom), documented.
Files: test/invariant/TenureInvariants.t.sol, test/attacks/{OracleAttacks,BypassAttacks,Reentrancy}.t.sol,
docs/THREAT_MODEL.md, PLAN.md
Tests: 248 passing (default). Deploy profile: see the M7.1 entry.

## 2026-11-25 — M7.1 Testnet deploy scripts + runbook (no broadcast) — DONE
What:
- deployments/config.json: every value with an official source URL (research by a subagent from
  developers.uniswap.org, dev.reactive.network, docs.chain.link); unconfirmed = TODO. EIP-55 checked.
- script/DeployUnichainSepolia.s.sol (scorer linked, hook mined, pool A demo + DemoDirector with mock oracle, pool B
  tWETH/tUSDC on live Chainlink ETH/USD / USDC/USD, both Reactive receivers funded, freeze receiver wired to both
  vaults), script/DeployLasna.s.sol (TenureSettlerRC + TenureFreezeRC, deployer must equal the Unichain deployer:
  RVM id), script/demo_testnet.sh. Real broadcasts write deployments/<chainId>.json; simulations write
  *.dryrun.json (git-ignored). foundry.toml: read-write fs permission for ./deployments.
- BUG FIXED: forge 1.8.5 does not route `new X{salt}` through the CREATE2 factory when the script runs against a
  forked live chain (with or without --broadcast; --always-use-create-2-factory did not help). The hook landed at a
  script-derived address -> HookAddressNotValid. The pre-existing DeployTenureHook.s.sol had the same bug (only
  ever run on anvil/in-memory). TenureHookDeployer now calls the factory explicitly (salt ++ initcode).
- Verified: live dry run Unichain Sepolia (41,524,085 gas, SIMULATION COMPLETE); live dry run Lasna stops at
  OutOfFunds (burner has 0 lREACT: expected); anvil fork of 1301: full broadcast + 26 demo ticks, 0 failures; anvil
  fork of Lasna: both RCs deployed, live system contract accepted 3 + 2 subscriptions; plain anvil: both scripts;
  script/demo.sh still FROZEN after 3 rounds.
- Read-only: burner balance 0 on Unichain Sepolia, Ethereum Sepolia and Lasna. Funding estimate in docs/DEPLOY.md:
  0.03 ETH Unichain, 15 lREACT, 0.25 Sepolia ETH total.
Files: deployments/config.json, script/{DeployUnichainSepolia,DeployLasna}.s.sol, script/demo_testnet.sh,
script/base/TenureHookDeployer.sol, docs/DEPLOY.md, foundry.toml, .gitignore
Notes for human: follow the "Human checklist" at the top of docs/DEPLOY.md. Open items: verifier URL, Sepolia
faucet/RPC, Reactive per-tx billing and RC top-up, sequencer feed (unused).

## 2026-11-25 — M6.1 README — DONE
What: root README rewritten: pitch, headline chart, 3 key numbers (20/20 FROZEN in 60-76 blocks; attacker profit
-59%; ~2,770 tokens / 3.5% NAV kept), four layers, why-a-hook, sponsor integrations, GAS.md summary, threat model
summary incl. window gaming (small, unprofitable gap) and alpha inflation, limitations, how to run.
Files: README.md

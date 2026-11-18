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

# PLAN — Tenure

Legend: `[ ]` todo · `[x]` done · `[!]` blocked (see BLOCKERS.md) · `[H]` human-only, skip it
The loop takes the FIRST `[ ]` task, top to bottom. Each task must meet its acceptance criteria before `[x]`.
Order is deliberate: the most impressive, most novel part (the measurement engine) is built and proven first,
as pure libraries with heavy tests, before any vault plumbing.

---

## M0 — Foundation (small, do fast)
- [x] **M0.1 Verify scaffold.** Confirm the repo builds from the v4-template (`forge build`, `forge test`). Remove the
  template's example hook/tests only after the build is green. Create `src/libraries`, `src/interfaces`, `src/mocks`,
  `sim/`, `docs/`. Create `PROGRESS.md` and `BLOCKERS.md` if missing.
  _Accept:_ clean build, template tests either passing or intentionally removed, folders exist, committed.
- [x] **M0.2 Reference price.** `IReferencePrice` (returns fair `sqrtPriceX96` for a PoolKey/PoolId, plus `updatedAt`)
  and `MockReferencePrice` (settable per pool). Staleness check helper.
  _Accept:_ unit tests for set/get and staleness revert.

## M1 — Measurement engine (THE CORE — most impressive, build first)
- [x] **M1.1 Python reference model.** `sim/model.py`: holdings(range, L, sqrtP) using exact CL formulas, NAV at fair
  price, immediate leakage, markout alpha, loss, budget update, tier. Pure Python ints / Fractions, no floats in core.
  `sim/test_model.py` with hand-checked examples (in-range, below range, above range, full range).
  _Accept:_ `python -m pytest sim -q` passes.
- [x] **M1.2 Test vectors.** `sim/gen_vectors.py` writes `test/vectors/*.json` (>= 200 random cases per function,
  realistic tick ranges, edge cases at range boundaries and extreme prices). Deterministic seed.
  _Accept:_ vectors generated and committed; generator documented in sim/README.md.
- [x] **M1.3 PositionValue library.** `holdings(...)` and `navAt(...)` in Solidity using v4-core math
  (SqrtPriceMath / TickMath; periphery LiquidityAmounts only if it exists in lib/). Overflow-safe NAV via nested mulDiv.
  _Accept:_ unit + fuzz tests; differential test vs JSON vectors (exact match or documented <= 1 wei rounding, always
  rounding against the curator).
- [x] **M1.4 DecisionScore library.** `immediateLeakage(...)`, `markoutAlpha(...)`, `lossFraction(...)` as WAD of NAV.
  _Accept:_ differential tests vs vectors; fuzz property tests: (a) doing nothing scores zero leakage and zero alpha;
  (b) a rebalance at fair spot with no swap has ~0 leakage; (c) leakage is invariant to which token denominates
  holdings order (token0/token1 swap symmetry check where applicable).
- [x] **M1.5 RiskBudget library.** Leaky bucket with refill rate, `B_max`, tier thresholds, reputation growth of
  `B_max` and deposit cap from cumulative positive alpha, caps. Pure functions over a struct.
  _Accept:_ unit + fuzz: budget never exceeds B_max, never underflows (floors at 0), tier monotonic in budget,
  refill can never lift FROZEN without guardian (frozen is sticky), differential vs Python.
- [x] **M1.6 Slow-bleed proof (pure-library simulation).** A Foundry test that runs 200 simulated rebalances where each
  leaks a small amount (each individually within a static per-action cap) and shows: static cap allows all of them;
  RiskBudget reaches FROZEN after N actions; total loss bounded. Print a table with console.log.
  _Accept:_ test passes and prints the comparison; numbers written to `docs/results/slow_bleed.csv` via vm.writeFile.

## M2 — The hook
- [x] **M2.1 TenureHook skeleton.** Permissions: beforeAddLiquidity, beforeRemoveLiquidity, afterSwap (+ whatever is
  needed). Address mining in tests per the v4-hook-dev skill. Vault registration per pool (owner-set for MVP).
  _Accept:_ permissions/address test runs FIRST and passes; hook deploys in test harness with a real PoolManager.
- [x] **M2.2 Measured sessions.** `beginRebalance` / `endRebalance` using a transient-storage session flag;
  before{Add,Remove}Liquidity revert with `Tenure__NoSession` for the registered vault outside a session; other LPs
  unaffected. Holdings snapshots read independently from the PoolManager (StateLibrary) + token balances; handle
  mid-unlock deltas correctly (see skill).
  _Accept:_ tests: vault modify outside session reverts; inside session succeeds; third-party LP unaffected;
  session cannot be left open across transactions.
- [x] **M2.3 Mandate enforcement.** Range width bounds, max distance of range center from fair price, max fraction of
  NAV moved, cooldown, oracle staleness. Tier-dependent limits (RESTRICTED tightens). Timelocked mandate updates
  (propose -> wait -> execute) with events.
  _Accept:_ one test per rule (pass and fail case); timelock tests.
- [x] **M2.4 Scoring + records.** endRebalance computes immediate leakage, charges RiskBudget, stores RebalanceRecord,
  emits `RebalanceScored`. `settle(id)` after W blocks computes alpha, updates budget + reputation, emits
  `MarkoutSettled`. afterSwap settles up to N due records (bounded loop, gas-tested).
  _Accept:_ tests for settle timing (too early reverts), idempotency (can't settle twice), afterSwap auto-settle,
  gas snapshot for afterSwap with 0/1/N due records.
- [x] **M2.5 Freeze + safe mode.** FROZEN blocks curator rebalances except `enterSafeMode` (full-range or idle).
  Guardian `restore()` after a timelock. Events.
  _Accept:_ tests for each transition FULL->RESTRICTED->FROZEN->restored.

- [x] **M2.6 Proportional budget scaling + pump bound.** When bMax grows from positive alpha, scale budget by
  bMax_new / bMax_old (floor) so budget/bMax is unchanged; success never changes tier, only time refill or guardian
  restore does. Enforce k <= 1e18 in RiskBudget.validate at registerPool (Tenure__ReputationGainTooHigh); BudgetParams
  are per pool, not constructor args. Update sim/model.py first,
  regenerate vectors, then RiskBudget.sol.
  _Accept:_ fuzz: tier never changes on a positive-alpha settle; ratio preserved within 1 wei (rounded down);
  registerPool reverts for k > 1e18; a test shows pumping alpha by paying the vault X never increases the attacker's
  net extractable value; differential tests pass; docs/MATH.md has the pump-bound argument.

## M3 — The vault
- [x] **M3.1 CuratedVault.** Two-token vault, one curated position per pool for MVP. Shares priced at NAV at FAIR price
  (Gamma lesson). Deposit guard: revert if pool spot deviates from fair price beyond a threshold. Deposit cap from the
  hook's reputation state. Withdrawals ALWAYS open, pro-rata, even when FROZEN.
  _Accept:_ tests: first-depositor inflation attack fails; deposit at manipulated spot reverts; withdraw works in
  every tier; deposit cap enforced and grows with reputation.
- [x] **M3.2 rebalance(params).** Curator-only. begin -> unlock(remove, add) -> end. Settles deltas correctly.
  _Accept:_ end-to-end test: deposit, rebalance, swap, settle, withdraw; balances reconcile to the wei.
- [x] **M3.3 Fees in alpha.** Include LP fees earned by the new position (fee growth inside the range) in H_new,
  and fees the old position would have earned in H_cf where computable; otherwise document the approximation.
  _Accept:_ in a seeded honest-curator scenario with normal swap flow, the honest curator's budget never drops
  below the FULL threshold over 500 blocks; differential tests updated; Python model updated first.

## M4 — The demo (this is what wins — make it undeniable)
- [x] **M4.1 Scenario actors.** Solidity test actors: `HonestCurator` (tracks fair price), `PoisonedCurator` (after a
  "poison" event, places ranges skewed off fair price within static caps), `Attacker` (trades against mispriced
  liquidity, arbitrage profit), `Market` (moves fair price along a seeded path).
- [x] **M4.2 Headline scenario test.** Same seeded market, three runs: (A) honest curator + Tenure: builds budget,
  deposit cap grows; (B) poisoned curator + static caps only: slow bleed succeeds; (C) poisoned curator + Tenure:
  budget drains, tiers step down, frozen, loss bounded. Print a clear comparison table; write
  `docs/results/headline.csv` (per-block NAV, budget, tier for each run).
  _Accept:_ test passes; loss(C) << loss(B); numbers in docs/results.
  Run A (honest) must stay in FULL for the entire run.
- [x] **M4.2b Seed sweep.** Run the headline scenario A/B/C over 20 seeds. Runs B and C must use identical
  attacker and curator code, differing only in whether Tenure's budget is active (assert this in code).
  Report per run: median and worst-case vault loss, attacker profit, blocks from attack start to RESTRICTED and
  to FROZEN, and A's minimum budget ratio. Write docs/results/sweep.csv and a summary table in docs/RESULTS.md.
  _Accept:_ A stays FULL on every seed; C's worst-case loss is below B's median loss, or the result is reported
  honestly in RESULTS.md with an explanation if not.
- [x] **M4.2c Contract size headroom.** Get the hook at least 2,000 bytes under 24,576 in the deploy profile.
  Use EXTERNAL library functions (linked at deploy) for the heaviest pure math; keep all state and authorization
  in the hook; linking must work in tests and scripts. _Accept:_ size report shows >= 2,000 bytes headroom; full suite and
  gas assertions still pass (re-measure afterSwap gas under BOTH profiles against the 213,240 bound; any gas
  increase is recorded under Decisions made).
- [x] **M4.3 Charts.** `sim/plot_results.py` (matplotlib) -> `docs/results/headline.png`, `slow_bleed.png`,
  `sweep.png`. Headline: runs B and C on the same axes with tier changes marked, readable at a glance; budget over
  time. Sweep: per-seed B vs C loss, sorted.
  _Accept:_ PNGs generated from the CSVs.
- [x] **M4.4 Local demo script.** `script/Demo.s.sol` runnable on anvil that deploys everything and replays scenario C
  with readable logs. `docs/DEMO.md` with exact commands.
  _Accept:_ runs end-to-end on a fresh anvil.
- [x] **M4.6 Chainlink reference price.** ChainlinkReferencePrice implementing IReferencePrice using
  AggregatorV3Interface (vendor only the interface, pinned). Convert the feed answer + decimals for both
  tokens into a fair sqrtPriceX96; staleness from updatedAt; revert on non-positive answers or incomplete
  rounds. Lives outside the hook. _Accept:_ unit + fuzz tests against a mock aggregator, including decimals
  combinations (6/8/18), stale and negative answers; differential check vs sim/model.py conversion.
- [x] **M5.4 Settlement gas.** (Moved up: M4.5a depends on settleMany and autoSettlePerSwap = 0.)
  Cap afterSwap auto-settle at 1 record per swap (config param, per pool), and allow auto-settle count = 0 per pool (opt-out: swappers pay nothing extra; settlement is then done by
  keepers). Keep settle() permissionless, add settleMany(ids) for keepers. Try to reduce the fee-aware
  settlement cost raised in M3.3 (e.g. pack RebalanceRecord / BudgetState). _Accept:_ gas snapshot shows
  afterSwap overhead with 0 and 1 due records, and with auto-settle = 0; README explains the cost model.
- [x] **M4.5a Reactive settlement.** reactive-lib f6990ce and reactive-test-lib 2ff9b2a are pinned in lib/.
  HUMAN DECISION: Reactive integration adds ZERO bytes to TenureHook. TenureReactiveReceiver (destination side,
  separate contract, AbstractCallback) accepts callbacks only from the callback proxy with our RVM ID and calls the
  existing permissionless hook.settleMany(id, ids). TenureSettlerRC (Reactive side, AbstractReactive) subscribes to
  RebalanceScored, MarkoutSettled (prunes records settled any other way) and cron; tracks pending records; emits the
  settleMany callback once records are due (delay in Reactive-chain blocks; the hook still enforces true due-ness).
  Pools using Reactive set autoSettlePerSwap = 0.
  _Accept:_ reactive-test-lib tests: scored rebalance -> no callback before the delay -> callback after it ->
  record settled; unauthorized callbacks revert (wrong sender, wrong RVM ID); a failed callback is retried; a
  test asserts TenureHook runtime size is unchanged (both profiles); docs/THREAT_MODEL.md covers the relay.
- [ ] **M4.5b Cross-chain freeze propagation.** Lands in CuratedVault, NOT the hook: a relayed-freeze flag, set
  only by the vault's authorized freeze receiver, blocks curator rebalance. TenureFreezeRC subscribes to TierChanged
  for the same curator's pools on chains A and B; on FROZEN on one side it calls the freeze receiver on the other.
  SAFETY INVARIANT: the relay path can only freeze; clearing the flag stays with the local guardian (hook guardian);
  withdrawals stay open regardless. _Accept:_ tests prove the invariant (every non-freeze action via the receiver
  reverts), freeze propagates A->B and B->A, duplicate/replayed callbacks are harmless, withdrawals work while
  relay-frozen, TenureHook size unchanged; docs/THREAT_MODEL.md: relay trust model, replays, compromised relay
  worst case (can only freeze an honest curator; no fund loss).
- [H] Ask Reactive dev chat: best way to time a 50-block origin-chain window; confirm current callback proxy
  addresses; get Lasna testnet funds.

## M5 — Hardening (judges probe these)
- [ ] **M5.1 Invariant tests.** Handler-based invariants: vault solvency (shares * NAV <= holdings), budget bounds,
  session never open at end of tx, withdrawals never blocked.
- [ ] **M5.2 Attack tests on our own design.** Oracle staleness, oracle vs spot manipulation griefing an honest
  curator, window gaming, curator bypass attempts (direct PoolManager calls), reentrancy via hooks.
  Document each in docs/THREAT_MODEL.md with result.
- [ ] **M5.3 Gas report.** `forge snapshot`; note costs of begin/end/settle/afterSwap in docs.

## M6 — Submission materials
- [ ] **M6.1 README.md.** Problem (with sources), solution layers, why-a-hook, theme mapping (mandate = curator strategy
  params; AI curator = off-chain signals/ML; reputation-weighted AUM = budget-driven deposit cap), math summary,
  architecture mermaid diagram, results charts, threat model summary, limitations, how to run.
  Document FOUNDRY_PROFILE=deploy for anvil/testnet deploys and the contract-size reason.
- [ ] **M6.2 docs/MATH.md.** Full derivations with a worked numeric example matching a test.
- [ ] **M6.3 Pitch outline.** docs/PITCH.md: 3-minute demo script, slide outline, likely judge questions + answers.

## Stretch (only after everything above is [x])
- S1 moved to M3.3 (fees in alpha).
- [ ] **S2** Multiple markout windows (short + long) to resist window gaming.
- [ ] **S3** Optional LLM-driven curator in sim/ (needs API key -> leave runnable but default to rule-based).
- [ ] **S4** Minimal dashboard (single HTML file reading the CSVs).

## Human-only
- [H] Confirm UHI11 rules (one prize per project?), submission format, demo length.
- [H] Pitch idea to mentors at office hours; record feedback in docs/FEEDBACK.md.
- [H] Testnet deploy with burner keys only: Unichain Sepolia + Reactive Lasna (+ Base Sepolia only if M4.5b is
  done); record addresses in README.
- [H] Record demo video.

# Tenure — Earned Autonomy for AI Liquidity Curators

Uniswap Hook Incubator, Cohort 11 (UHI11) hookathon. Theme: **Curated Liquidity — Active Management & Curation**.
Solo builder. Deadline: Thursday December 3, 2026. Target: Theme prize (UHI11 devs), fallback General prize.

## One-line pitch
We don't try to detect when an AI curator is compromised. We measure the damage its decisions cause,
and its autonomy shrinks automatically when it starts losing depositors' money.

## The problem (why this matters — use this framing in docs and pitch)
- In curated liquidity, depositors hand money to a curator who manages LP positions. The curator is fully trusted.
  Arrakis openly says its manager is off-chain and trusted, bounded only by static per-block limits.
- Mandate drift is real: in the Stream Finance collapse (Nov 2025), a curator changed strategy without depositor
  consent; risk-curator vault TVL fell from ~$10B to ~$6.9B within days.
- AI curators make it worse. Princeton research (CrAIBench, arXiv 2503.16248) showed memory/context injection makes
  agents take harmful actions, and prompt-injection detectors give limited protection once stored context is corrupted.
  You cannot reliably detect a poisoned agent by inspecting the agent.
- Static limits (per-action caps, per-block leak caps) stop one big loss but NOT a slow bleed of many small,
  individually "valid" bad decisions. The killer attack: poison the curator into placing liquidity at a bad price,
  then trade against it yourself. No theft transaction ever happens.

## The solution: four layers
1. **Mandate** — depositor-agreed bounds (range width, max distance from fair price, max fraction of NAV moved per
   action, cooldown). Enforced by the hook. Changes are timelocked so depositors can exit first.
2. **Decision measurement (the novel core)** — every rebalance is scored at a fair reference price:
   immediate leakage, then a markout `alpha` vs the counterfactual of not rebalancing, settled after W blocks.
3. **Risk budget -> autonomy tiers** — a leaky-bucket budget drained by losses, refilled slowly over time.
   Budget level sets the tier: FULL -> RESTRICTED -> FROZEN (safe passive mode, guardian needed to restore).
4. **Pool-native reputation** — max budget and the vault's deposit cap grow only with proven positive alpha,
   measured by the hook itself (no external, Sybil-prone reputation scores).

## Why it must be a hook (judges will ask — keep this true in the code)
- The hook gates every modifyLiquidity on vault positions, so the curator cannot act outside a measured session.
- The hook reads pool state and the vault's positions directly from the PoolManager; it measures independently
  of the curator.
- Markout settlement piggybacks on swap flow in afterSwap (keeper-free).

## Architecture
```
Curator (off-chain agent, untrusted) --rebalance(params)--> CuratedVault (trusted code)
CuratedVault: hook.beginRebalance() -> poolManager.unlock(remove old, add new) -> hook.endRebalance()
TenureHook:
  beginRebalance  : open session (transient storage flag), snapshot holdings H_before + fair price
  beforeAdd/RemoveLiquidity : revert if sender == registered vault and no open session
  endRebalance    : snapshot H_after, check mandate + tier, charge immediate leakage to budget, store RebalanceRecord
  settle(id)      : after W blocks, compute alpha vs counterfactual, update budget + reputation (anyone can call)
  afterSwap       : opportunistically settle up to N due records (bounded gas)
ReferencePrice (oracle adapter) : fair sqrtPriceX96; MockReferencePrice in tests
```
Contracts (src/): `TenureHook.sol`, `CuratedVault.sol`, `libraries/PositionValue.sol`, `libraries/DecisionScore.sol`,
`libraries/RiskBudget.sol`, `interfaces/IReferencePrice.sol`, `mocks/MockReferencePrice.sol`.
Off-chain (sim/): Python reference model + test-vector generator + chart script.

## Core math (full detail in the `tenure-math` skill — load it before touching any math)
- holdings(range, L, S): token amounts of a position at pool sqrt price S (+ idle balances).
- NAV(h, P*) = amount0 * P* + amount1, in token1 units, P* = fair price from the reference oracle. NEVER pool spot.
- Immediate leakage: `L_imm = NAV(H_before, P*_t) - NAV(H_after, P*_t)`.
- Markout: `alpha = NAV(H_new at S_{t+W}, P*_{t+W}) - NAV(H_old at S_{t+W}, P*_{t+W})`.
- Loss charged = max(0, L_imm) + max(0, -alpha), as a WAD fraction of NAV_before.
- Budget: `B_t = min(B_max, B_{t-1} + r * blocks) - loss_t`. Tier by B/B_max: >=50% FULL, 20-50% RESTRICTED, <20% FROZEN.
- Reputation: `B_max` and deposit cap grow with cumulative positive alpha, capped.

## Tech stack and conventions
- Foundry. Built on Uniswap's v4-template. Use whatever BaseHook / test utilities the template uses —
  read lib/ sources before calling any function; signatures change between versions.
- Solidity version: whatever the template pins. Do not upgrade dependencies.
- Fixed point: WAD (1e18) for fractions; Q96 for sqrt prices; use FullMath.mulDiv for products.
- Rounding: always round AGAINST the curator (leakage up, alpha down, budget refill down).
- Naming: custom errors `Tenure__Something`; events for every state change (judges read events in demos).
- NatSpec on every external function. Explain the "why" in comments for math.
- Tests: unit + fuzz + differential (Solidity vs Python vectors) + scenario tests. Fuzz runs >= 256.

## Hard rules
- Never weaken, skip, or delete a test to make it pass. Fix the code or log a blocker.
- Never use mainnet, real private keys, or real funds. Testnet deploys are human-only tasks.
- Never edit files under lib/. Never add unpinned dependencies.
- Keep this file under 300 lines. Put details in skills or docs/.
- One PLAN.md task per loop iteration. Commit after each task.

## Learnings
- Template: solc 0.8.30, cancun, OZ uniswap-hooks v1.1.0 (BaseHook at @openzeppelin/uniswap-hooks/src/base/BaseHook.sol), test base `test/utils/BaseTest.sol` (deployArtifactsAndLabel, deployCurrencyPair, deployCodeTo to flag address).
- Vector JSON must be held in a memory string in tests (storage string => OutOfGas from SLOADs).
- forge 1.8.5 clears transient storage between top-level calls in a test: test in-tx behavior inside ONE external call.
- Hook reverts surface as CustomRevert.WrappedError(hook, callbackSelector, innerErr, HookCallFailed) - build expected bytes that way.
- TenureHook exceeds 24KB without via-IR: deploy with FOUNDRY_PROFILE=deploy (via_ir). Tests use deployCodeTo (no size limit).
- Tests: use vm.getBlockNumber()/vm.getBlockTimestamp(), never block.number - via-IR caches it across vm.roll.
- Windows: keep LF line endings (.gitattributes) or `forge fmt --check` fails on every file.
- ACCEPTED: Guardian restore sets budget to 35% of bMax (lands in RESTRICTED; autonomy is re-earned).
- ACCEPTED: Positive alpha grows bMax and deposit cap but never refills budget; losses reduce cumulative positive alpha.
- ACCEPTED: "Fraction of NAV moved" = value swapped between tokens; range moves without swaps are bounded by the distance-from-fair-price rule instead.
- ACCEPTED: Hook exceeds 24KB in default profile; deploy with FOUNDRY_PROFILE=deploy.
- M2.6: credit() keeps the tier (never recomputes it); k <= 1e18 is checked in RiskBudget.validate at registerPool, since BudgetParams are per pool, not constructor args.
<!-- Append non-obvious discoveries here (API quirks, gotchas, decisions). Keep each to 1-2 lines. -->

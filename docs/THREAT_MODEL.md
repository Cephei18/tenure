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
attacker profit **+421.9 tokens** at the fair price, vault loss **446.0 tokens** (~0.56% of NAV per round).
(In the first M4.1 version, before the poisoned curator re-balanced its inventory when parking, the same round
cost the vault 524.1 tokens.) Without inventory management the damage decays geometrically: each round the vault
sells token0, so its next follow-range holds less and less (L: 1.0e24 -> 4.0e23 -> 1.1e23 over three rounds).

**Headline (M4.2, 600 blocks, one seeded market, `test/scenario/Headline.t.sol`):** static caps only (run B):
25 rounds, vault -4,197 tokens vs. the honest run (~5% of NAV), attacker +1,563. Tenure (run C): RESTRICTED at
block 160, FROZEN at block 170 after 3 rounds, safe mode; vault -1,261 vs. the honest run (including fees forgone
while idle), attacker +625. B's loss grows with time; C's is capped at the freeze.

**Why static caps don't stop it.** No single action breaks a per-action rule, and no transaction is a theft.
**What Tenure does.** A pure re-range at a manipulated spot leaks ~0 immediately (both snapshots are taken at the
same spot), so immediate leakage alone does not catch it. The markout does: after W blocks the new range is
valued at the fair price against the counterfactual of keeping the old range, and the arbitrage that bought the
vault's token0 below fair shows up as negative alpha. That drains the risk budget, so the curator steps down
FULL -> RESTRICTED -> FROZEN after a bounded number of rounds (headline scenario, M4.2). Any swap the curator
makes at the manipulated spot is additionally caught as immediate leakage.

## 3. The fair-price oracle (M4.6: Chainlink adapter)

Everything Tenure measures is valued at the reference price, so the oracle is part of the trust base.
`src/ChainlinkReferencePrice.sol` turns Chainlink feeds (token0/USD and token1/USD, or one direct token0/token1 feed)
into a fair sqrtPriceX96 (`src/libraries/ChainlinkPriceLib.sol`, exact vs `sim/model.py`, 240 vectors).
- **Bad answers:** non-positive answers and incomplete rounds (`updatedAt == 0` or `answeredInRound < roundId`)
  revert. A price outside v4's sqrt-price range reverts.
- **Stale answers:** the adapter reports the OLDER feed's `updatedAt`. The hook rejects it past the pool's
  `maxOracleAge` (`Tenure__StalePrice`), and `afterSwap` simply skips settlement, so swaps never revert.
- **Owner picks the price:** feeds are set ONCE per pool and cannot be replaced. Swapping a feed would let the
  owner choose the price every decision is scored at. A different source needs a new adapter and a new pool
  registration, which depositors can see coming and exit before.
- **Residual risk (not solved here):** a compromised or deprecated Chainlink feed. A deviation check against a
  second source (e.g. a pool TWAP) is future work. Settlement also requires spot near fair (`maxSettleDev`), so a
  feed far from the market stalls markouts rather than scoring them.
Evidence: `test/ChainlinkReferencePrice.t.sol` (decimals 6/8/18, direct and two-feed modes, stale, negative and
incomplete answers, set-once), `test/diff/ChainlinkPriceDiff.t.sol`.

## 4. Reactive settlement relay (M4.5a)

`TenureSettlerRC` runs on the Reactive Network. It watches the hook's `RebalanceScored`, `MarkoutSettled` and a
cron topic, and asks `TenureReactiveReceiver` on the hook's chain to call `hook.settleMany`. The integration adds
zero bytes to TenureHook; `test/HookSizeFrozen.t.sol` pins the hook size in both profiles.
- **Trust model:** the relay is a liveness aid only. `settleMany` is permissionless, and the hook re-checks
  everything: due-ness, oracle freshness, spot vs fair, already settled. The receiver accepts calls only from the
  callback proxy (`authorizedSenderOnly`) carrying our RVM ID (`rvmIdOnly`). That stops strangers from spending the
  receiver's pre-paid callback fees; it is not needed for correctness.
- **Replayed or duplicate callbacks:** harmless. A settled record is skipped (`settleMany` returns 0 for it), and a
  record that is not yet due is skipped. A callback that reverts (stale oracle, spot off fair) leaves the record
  queued. The RC re-sends it at most once every `delayBlocks` until `MarkoutSettled` drops it.
- **Compromised relay, worst case:** it can stop settling, or settle at a moment it picks. Stopping only delays
  markouts: anyone (a keeper, a depositor) can still call `settle`/`settleMany`. `autoSettlePerSwap` is fixed at
  registration, so the pool cannot fall back to swap-driven settlement on its own. Picking the moment is bounded by the hook's anti-gaming rule: settlement needs
  a fresh oracle and spot within `maxSettleDev` of fair, the same as for any keeper. No funds can move: the
  receiver can only call `settleMany`.

## 5. Cross-chain freeze propagation (M4.5b)

One curator can run Tenure-gated vaults on two chains. `TenureFreezeRC` watches `TierChanged` for that curator's
pool on chain A and on chain B. When one side enters FROZEN, it calls `TenureFreezeReceiver` on the other chain,
which sets `CuratedVault.relayFrozen`, and that flag blocks the curator's `rebalance`. Nothing changes in
TenureHook: the flag lives in the vault, and the hook size is pinned by `test/HookSizeFrozen.t.sol`.
- **SAFETY INVARIANT: the relay can only freeze.** The receiver's single vault call is `relayFreeze`, which can
  only set the flag. Clearing it (`clearRelayFreeze`) is guardian-only: the hook's guardian, the same party that
  restores a FROZEN tier. The relay never touches the hook's tier or budget. Deposits, withdrawals and safe mode
  are unaffected. Proven in `test/reactive/FreezePropagation.t.sol::test_invariant_receiverCanOnlyFreeze`: as
  msg.sender, the receiver reverts on every vault and hook admin or curator function, and every non-`freeze`
  payload through the proxy fails.
- **Trust model:** a vault accepts relays only from the receiver its owner set (`setFreezeReceiver`; address(0)
  disables relays). The receiver accepts only the callback proxy carrying our RVM ID.
- **Duplicates and replays:** the RC relays once per FROZEN episode. A duplicate notification is ignored until
  that side leaves FROZEN (guardian restore). At the vault, `relayFreeze` is idempotent. A replayed callback
  after the guardian cleared the flag re-freezes: that costs liveness, never funds, and only in the safe direction.
- **No echo:** a relayed freeze emits no `TierChanged`, so A and B cannot ping-pong.
- **Compromised relay, worst case:** it can freeze an honest curator's vault on the other chain. The curator
  cannot rebalance until the guardian clears the flag. Depositors keep full access (withdrawals stay open, and safe
  mode is still allowed), and no funds can move: the relay has no path to tokens, shares, the mandate or the
  budget. A malicious vault owner could point the vault at a hostile receiver, but that receiver can still only
  freeze.

## 6. Markout window gaming (M5.2, partly open)

**Who controls W.** The markout window is `PoolSettings.window`. It is per pool, set by the owner once in
`registerPool`, and has no setter. The curator cannot change it, and neither can the owner after registration. A
different W needs a new pool registration, which depositors can see coming. So it is not timelocked because it
cannot change at all. (It is not part of `Mandate`; it is fixed like the oracle.)

**Threat.** A markout grades a decision once, W blocks after it is made. A poisoned curator re-centers its range on
a spot the attacker pushed off fair (the section 2 "follow" decision). The attacker then waits until the record has
been graded before arbitraging spot back through that range. Loss realized after grading is never charged.

**What bounds it.** A record can only be graded while `|spot - fair| <= maxSettleDev` (100 ticks in tests;
`Tenure__SpotOffFair` otherwise). A range's value at a given spot does not depend on the path taken, so grading
already counts everything up to the settlement spot. Only the last leg, from the settlement spot back to fair, can
land after grading: at most `maxSettleDev` ticks.

**Measured** (`test/attacks/WindowGaming.t.sol`; same pool and vault as section 2, every round run from the same
snapshot, values in token units at the fair price):

| Attack | Vault damage | Charged (inside W) | Charged (after W) | Realized after grading |
|---|---|---|---|---|
| Push -90 (inside maxSettleDev), grade at -90, then arb | 8.56 | 17.29 | 0.00 (80,002 wei) | 8.56 (100%) |
| Push -400, arb to -100, grade, then finish the arb | 445.99 | 484.52 | 461.73 (-4.7%) | 13.09 (2.9%) |
| Push -400, try to grade at -400 | - | - | reverts `SpotOffFair(400, 100)` | - |

The charge inside W is above the damage because of the curator-adverse fee rule: the abandoned parked range's
ticks are uninitialized, so the counterfactual is credited the global fee-growth upper bound.

**Repeated (the slow bleed).** 20 rounds of the -90 attack struck after W
(`test_windowGaming_smallPush_repeated`), with a poisoned curator that parks without a swap. The vault loses
57.75 tokens (~0.07% of NAV), the tier stays FULL and the budget is never touched. This is a real grading gap.
**In this pool the attacker loses 50.57 tokens on the campaign**, because the 0.3% fee on push and arbitrage through
third-party liquidity is more than it takes from 90-tick moves. It is a griefing bleed here, not a profit. That
would change with a lower fee tier or a vault that holds more of the in-range liquidity. (The stock section 2
curator re-parks with an inventory swap; in this thin pool that swap is charged as leakage, and it is FROZEN after
one round.)

**What currently limits it, honestly:**
- `maxSettleDev` is the binding limit. It caps the escaped leg. Lowering it shrinks the gap, but markouts then stall
  more often in volatile markets.
- **Mandate distance rule** (`maxCenterDist`): it does NOT bind this variant. A 90-tick follow is far inside 3,000.
  It bounds how far a bad range can sit from fair, which bounds the size of a graded round, not the escaped leg.
- **Next rebalance**: it ends the vault's exposure to the graded range, but it does NOT re-grade the escaped loss.
  The next record measures `H_before` after the loss and compares against keeping the already-damaged range. In the
  repeated test the 20 park records charge nothing.
- **Holding spot off fair for W blocks** (not modeled): the tests have no other traders. In a live pool,
  arbitrageurs pull spot back within W through the vault's range, and that loss is graded. The attacker must defend
  the manipulated spot for W blocks, at its own cost.

**Planned fix (M5.5, lifetime grading):** when the curator replaces a range, run a final markout from the original
decision to now and charge only the loss beyond the early W-block grade. A max horizon lets anyone force the final
grade.

**Candidate fix found in M5.2 (untested, for M5.5):** value both hypothetical holdings at the FAIR price instead of
the settlement spot (`S := P*` in the markout). The grade would then not depend on spot at all. It equals the
realized outcome once spot returns to fair. When spot is off fair it is a lower bound for the curator (LP holdings
at any off-fair spot, valued at fair, are worth at least the holdings at fair; see section 8). That would close
both the escaped last leg above and the alpha inflation in section 8. It changes the math spec (tenure-math) and
needs the Python model, new vectors and a hook-size check first.

## 7. Invariants (M5.1)

`test/invariant/TenureInvariants.t.sol`: a handler drives the whole system: deposits, withdrawals, random curator
decisions (most break the mandate and are rejected), swaps up to 400 ticks off fair, fair-price moves, blocks
with and without oracle refresh (so the oracle goes stale), settlements, safe mode, guardian restores, and a
simulated full bank run. In-transaction properties are checked inside the handler call and latched into ghost
flags, because forge clears transient storage between top-level calls.

| Invariant | Meaning |
|---|---|
| `bankRunAlwaysSucceeds` | every holder exits in full, in sequence; only the burned dead shares remain |
| `withdrawPaysAtMostProRata` | no withdrawal pays more than shares/supply of holdings (2 wei of v4 rounding slack) |
| `noOrphanedVaultLiquidity` | the vault has liquidity only in the hook-tracked range, never in any other range it tried |
| `budgetBounds` | budget <= bMax, bMax0 <= bMax <= bMaxCap, cap0 <= deposit cap <= capMax |
| `frozenOnlyLiftedByGuardian` | FROZEN is left only through the guardian's timelocked restore |
| `sessionNeverLeftOpen` | no hook session is open after any vault call (checked in the same transaction) |
| `withdrawalsNeverBlocked` | no withdrawal reverts: not when FROZEN, not with a stale oracle, not at a manipulated spot |

**Result:** all hold. One full-depth campaign ran 256 runs x 500 calls = 128,000 calls with 0 reverts and 0
violations. The checked-in configuration uses depth 100 (about 2 minutes per profile).
`test_invariantHandler_reachesKeyStates` proves the handler reaches FROZEN, a stale oracle, a guardian restore and
a bank run, so the campaign is not passing vacuously.

## 8. Oracle and oracle-vs-spot attacks (M5.2)

`test/attacks/OracleAttacks.t.sol`:
- **Stale oracle across a full markout cycle**: the curator cannot open a session, swaps keep working, a due record
  is never scored at a stale price (afterSwap skips it; `settle`/`settleMany` revert `Tenure__StalePrice`), and it
  settles normally once the price is fresh. An oracle timestamp in the future is rejected like a stale one.
- **Griefing an honest curator at settlement is impossible.** An outsider can pick the settlement spot within
  `maxSettleDev`. But positions are valued at the fair price, and an LP position at any off-fair spot is worth at
  least as much at fair as the same position at fair: it sold above fair or bought below fair on the way. Measured:
  an honest record settled at fair grades -2 wei, and the same record settled at -100 or +100 ticks grades
  **+40.08 tokens**.
- **The flip side (finding): alpha inflation.** An accomplice who pushes spot to the edge of the band before
  settling hands the curator +40.08 tokens of positive alpha for 36.11 tokens of its own cost. That grew `bMax` by
  12.5% (2.000e15 to 2.2505e15) and raised the deposit cap: reputation bought for slightly less than it adds.
  It is bounded per record (under 0.1% of NAV, asserted) and capped overall by `bMaxCap`/`capMax`, but it is a
  real way to buy reputation. The section 6 candidate fix (value at fair) removes it.
- **Spot push vs a prudent curator**: a curator that refuses to act while spot is off fair can be delayed by a push
  but never charged. The hook cannot tell a naive honest curator from a poisoned one: a curator that re-centers
  on a manipulated spot is charged by the markout. By design, Tenure grades outcomes, not intent.

## 9. Curator bypass attempts (M5.2)

`test/attacks/BypassAttacks.t.sol`. All refused:
- The curator (or anyone) calling the hook's session functions directly: `Tenure__NotVault` for all six.
- Direct PoolManager calls on the vault's exact ticks: v4 keys positions by owner, so the rogue contract only
  touches its own position. Adding is just third-party liquidity. Removing the vault's L underflows the rogue's
  own position (`SafeCastOverflow`). Vault liquidity and NAV are unchanged.
- Calling the vault's `unlockCallback` directly: `Tenure__NotPoolManager`. Calling hook callbacks directly:
  `NotPoolManager`.
- The curator changing its mandate, restoring itself, or replacing itself: owner- or guardian-only.
- A FROZEN curator: `rebalance` reverts `Tenure__Frozen`. Only de-risking stays open: safe mode and withdrawals.

## 10. Reentrancy (M5.2)

Tenure's contracts make no untrusted external calls: the hook calls only the PoolManager and the owner-set oracle.
The realistic vector is a token with transfer callbacks, which fires INSIDE a measured rebalance.
`test/attacks/Reentrancy.t.sol` etches such a token over the pool's currency0 and re-enters from the callback
while the session is open:
- vault `deposit`, `withdraw`, nested `rebalance`, `enterSafeMode`: `ReentrancyGuardReentrantCall`.
- hook `beginRebalance` (second session) and `endRebalance` (closing early, before H_after is measured):
  `Tenure__NotVault`.
- a nested `PoolManager.unlock`: `AlreadyUnlocked`.
- The outer rebalance still completes, is scored, and leaves no session open.
- **`settle` mid-session runs** (it is permissionless and has no session check). It can only hurt the curator:
  the vault's range has just been removed and its ticks cleared, so the fee estimator falls back
  curator-adversely. Measured: a record graded +108.32 tokens normally grades -2 wei when settled mid-session. Only
  a callback token can reach it. Tenure does not support such tokens. Adding a session check to `settle` costs
  hook bytes (headroom is 48 B), so it is left as is and documented here.
- The hook's own `afterSwap` never settles while a session is open, so a curator cannot pick its grading moment
  with a swap inside its own rebalance.

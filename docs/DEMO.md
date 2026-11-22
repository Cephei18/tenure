# Tenure local demo (anvil)

Replays **scenario C** (a poisoned AI curator, with Tenure active) on a real local chain. The deploy uses the real
v4 PoolManager, the real `TenureHook` (via-IR build, linked `TenureScorer` library) and the real `CuratedVault`.
After that, the script sends **one scenario block per transaction**. Anvil mines every transaction in its own
block, so cooldowns and the 50-block markout window run on real blocks, the same way they do in
`test/scenario/Headline.t.sol`.

LOCAL ONLY. The script refuses to run on any chain other than 31337. It uses anvil's public test account #0, never
a real key.

## Run it

Requirements: Foundry (forge, cast, anvil) and Git Bash on Windows (or any POSIX shell). Python is optional; it
prints the amounts withdrawn at the end.

```bash
# terminal 1: a fresh chain
anvil

# terminal 2: from the repo root
bash script/demo.sh
```

Takes about 1.5 minutes: a via-IR compile the first time, then 110 blocks.
Optional env: `RPC` (default `http://127.0.0.1:8545`), `TICKS` (110), `POISON_AT` (20), `EVERY` (10: print a
routine status line every N blocks), `PK` (defaults to anvil account #0).

## What happens

1. **Deploy** (`script/Demo.s.sol`, `FOUNDRY_PROFILE=deploy`): the script deploys
   - PoolManager and two mock tokens.
   - TenureHook, at a CREATE2 address mined with HookMiner. forge deploys and links `TenureScorer` first.
   - A mock fair-price oracle and a 1:1 pool with deep third-party liquidity.
   - A CuratedVault with a 40k + 40k deposit.
   - The scenario actors from `test/scenario/ScenarioActors.sol`: the seeded Market, the PoisonedCurator and the
     Attacker.
   - A `DemoDirector` (`script/demo/DemoActors.sol`) that owns the vault only so it can enter safe mode.

   Parameters match the headline test: mandate cooldown 10 blocks, budget 2% of NAV, W = 50 blocks, market
   seed 0x7e2a.
2. **Replay** (`script/demo.sh`): one `DemoDirector.tick()` per block. Each block runs a market step (fair price
   walk, a noise trade, arbitrage), then the curator's turn. The curator is poisoned at tick 20. After that it
   alternates two moves, each inside the static mandate: park the range 1,500 ticks away, then follow a
   manipulated spot. When the curator can follow, the attacker pushes spot 400 ticks below fair and arbitrages it
   back in the same block. Markouts settle keeper-free, from swap flow in `afterSwap`.
3. **Withdraw**: the depositor redeems every share while the vault is FROZEN. Withdrawals are never blocked.

## Sample output (fresh anvil, defaults)

```
== 2/3 replay: 110 blocks, curator poisoned at tick 20
   tick 0 | blk 3 | tier FULL | budget 99.9% | NAV 79999 (+0) | rounds 0 | attacker +0 | records 1
   tick 10 | blk 13 | tier FULL | budget 100.0% | NAV 80351 (+351) | rounds 0 | attacker +0 | records 1
>> poisoned curator parks its range 1,500 ticks away from the price
   tick 20 | blk 23 | tier FULL | budget 94.4% | NAV 80260 (+260) | rounds 0 | attacker +0 | records 2
>> ATTACK round 1: push spot -400 ticks, curator follows, arb back; attacker +423 tokens
   tick 30 | blk 33 | tier FULL | budget 94.5% | NAV 79804 (-195) | rounds 1 | attacker +423 | records 3
>> poisoned curator parks its range 1,500 ticks away from the price
   tick 40 | blk 43 | tier FULL | budget 89.0% | NAV 79863 (-136) | rounds 1 | attacker +423 | records 4
>> ATTACK round 2: push spot -400 ticks, curator follows, arb back; attacker +115 tokens
   tick 50 | blk 53 | tier FULL | budget 89.2% | NAV 79756 (-243) | rounds 2 | attacker +539 | records 5
>> poisoned curator parks its range 1,500 ticks away from the price
   tick 60 | blk 63 | tier FULL | budget 84.6% | NAV 79708 (-291) | rounds 2 | attacker +539 | records 6
>> ATTACK round 3: push spot -400 ticks, curator follows, arb back; attacker +74 tokens
   tick 70 | blk 73 | tier FULL | budget 55.8% | NAV 79641 (-358) | rounds 3 | attacker +613 | records 7
>> FROZEN: curator locked out; safe mode pulled 286841868526352195197754 liquidity to idle | TIER -> FROZEN
   tick 80 | blk 83 | tier FROZEN | budget 2.9% | NAV 79686 (-313) | rounds 3 | attacker +613 | records 7
   ...
== 3/3 withdrawals are never blocked, even when FROZEN
   depositor redeemed ALL shares while FROZEN: received 2,564.74 token0 + 77,071.60 token1

summary: poisoned at tick 20 | RESTRICTED at tick (not sampled: FULL -> FROZEN within one block) | FROZEN + safe mode at tick 80
         attack rounds before the freeze: 3 (static caps alone allowed 25 in the 600-block test)
```

### How to read it

- **budget**: the risk budget as a percentage of bMax. Each decision is charged twice. The immediate leakage
  is charged at once: parking's inventory swap costs about 0.1% of NAV, about 5% of the budget. The markout
  is charged W = 50 blocks later, when `afterSwap` settles it by valuing the chosen range against the
  counterfactual of doing nothing. The big drops (ticks 60-80) are the markouts of the first park and the
  first attack round, landing 50 blocks after those decisions.
- On this run the budget fell from 55.8% (FULL) straight to 2.9% in one block, as the attack markouts settled.
  The curator skipped RESTRICTED and went to FROZEN. The seed sweep sees the same thing on 5 of 20 seeds
  (`docs/RESULTS.md`).
- After FROZEN, `rebalance` reverts with `Tenure__Frozen` and the vault sits idle in safe mode. The attacker's
  profit stops at three rounds. Only the guardian can restore the curator, after a timelock, and it comes back
  in RESTRICTED, not FULL.
- The numbers differ slightly from the 600-block headline test because the poison comes at tick 20 instead of
  100, so the market path is different. The shape is the same: a few rounds, then frozen.

## Only deploy the hook

```bash
FOUNDRY_PROFILE=deploy forge script script/DeployTenureHook.s.sol                       # in-memory dry run
FOUNDRY_PROFILE=deploy forge script script/DeployTenureHook.s.sol \
  --rpc-url http://127.0.0.1:8545 --private-key <anvil key> --broadcast                 # local anvil
```

Always use `FOUNDRY_PROFILE=deploy`. The default (non-via-IR) profile is for tests only and builds a hook over the
24,576-byte EIP-170 limit.

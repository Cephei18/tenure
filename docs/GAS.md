# Tenure gas report (M5.3)

All numbers come from `test/GasReport.t.sol` under the **deploy profile** (via-IR, the build you would actually ship;
TenureHook runtime is 22,528 B). Raw values are in `snapshots/GasReport.deploy.json`, with
`snapshots/GasReport.default.json` for the default profile. To reproduce:

```
FOUNDRY_PROFILE=deploy forge test --match-path test/GasReport.t.sol
```

USD figures are **illustrative only**: Ethereum mainnet at **10 gwei** and **ETH = $3,000**, so 1M gas = $30.
**L2 costs are usually much lower** (often by 10-100x or more, depending on the chain and on L1 data fees).
Tenure is meant for a v4 deployment such as Unichain, where these execution costs are cents, not dollars.

## Results

| Operation | Gas | USD (mainnet, illustrative) | Notes |
|---|---:|---:|---|
| **Swaps** (1 token exact-in, inside the vault's range) | | | |
| Plain swap, hookless pool (baseline) | 99,105 | $2.97 | v4 with no hook at all |
| Swap on a Tenure pool, nothing due (`autoSettlePerSwap = 1`) | 116,310 | $3.49 | +17,205 vs. baseline (afterSwap callback + due check) |
| Swap, `autoSettlePerSwap = 0`, records due | 113,808 | $3.41 | +14,703: swappers never pay for markouts |
| Swap, `autoSettlePerSwap = 1`, settles one due record | 262,397 | $7.87 | +146,087 vs. nothing due: one fee-aware markout, paid by that swapper |
| **Rebalance** (remove old range, swap 1,000 token0, add new range) | | | |
| Full vault rebalance with Tenure (`CuratedVault.rebalance`) | 849,110 | $25.47 | |
| Same liquidity moves without the hook (`PlainVault`, hookless pool) | 311,210 | $9.34 | same logic: curator check, reentrancy guard, one unlock, event |
| **Tenure overhead per rebalance** | **537,900** | **$16.14** | difference of the two rows above |
| `beginRebalance` (as the vault pays it, inside the tx) | 175,042 | $5.25 | refill, tier/cooldown checks, oracle read, holdings snapshot |
| `endRebalance` (inside the tx) | 394,345 | $11.83 | re-read holdings, mandate, leakage score, budget, new record |
| **Keeper settlement** | | | |
| `settleMany`, 1 record | 184,507 | $5.54 | |
| `settleMany`, 5 records | 512,375 | $15.37 | ~81,967 per extra record ($2.46) |
| **Depositors** (vault holds a live position) | | | |
| `deposit` (second depositor, both tokens) | 221,046 | $6.63 | NAV at the fair price, deposit-cap check |
| `withdraw` (full exit) | 174,970 | $5.25 | pro-rata liquidity removal inside a hook session. No oracle read, works in every tier |
| **Deployment** | | | |
| `TenureHook` (CREATE2 at a mined flag address) | 4,987,754 | $149.63 | 22,528 B runtime |
| `CuratedVault` | 4,215,108 | $126.45 | one per vault |
| `TenureScorer` (linked external library) | 1,567,447 | $47.02 | deployed once, shared by every hook |
| Total for one hook + one vault + library | 10,770,309 | $323.11 | one-time cost |

## How the numbers were measured

- **Every call is its own transaction.** The test runs with `isolate = true`, so storage and accounts start cold and
  transient storage is cleared, as on-chain. The same numbers came out with isolation off, because each measured call
  is the first touch of its slots.
- **Transaction rows** (swaps, rebalances, settleMany, deposit, withdraw) are `vm.snapshotGasLastCall`. That is
  receipt-style `gasUsed`: it **includes** the 21,000 intrinsic cost and calldata, and gas refunds are **already
  applied**. (Checked with a probe: ten cold nonzero->zero writes report 57,754, which matches the refund cap. Without
  refunds they would report 72,204.)
- **`beginRebalance` / `endRebalance`** are not standalone transactions; the vault calls them. They are measured with
  `gasleft()` around each hook call inside an instrumented copy of the vault (`ProbeVault`) on a second, identically
  set-up Tenure pool. Each figure includes the vault's call into the hook and is **before refunds**. The parts sum to
  858,721 gross, while the probe's receipt is 859,723 including the 21k intrinsic cost (about 838.7k of execution).
  The difference of about 20k is refunds, mostly from the PoolManager clearing the old range's ticks.
- **Fair overhead comparison.** All three pools (Tenure+CuratedVault, hookless+PlainVault, Tenure+ProbeVault) have the
  same tokens, price, 1e27 full-range third-party liquidity, deposits and rebalance history. They also get the same
  warm-up swaps, so no measured call pays one-time slot initialisation. The measured rebalance is the vault's
  **third**, a steady-state one. A vault's very first re-range costs about 100k more, once, because the hook's
  snapshot slots are written from zero.
- **Deployment** = the in-EVM CREATE/CREATE2 cost (32k + initcode word cost + constructor + 200 gas per runtime byte),
  plus 21,000, plus calldata for the initcode (16 gas per nonzero byte, 4 per zero byte). For the hook, 32 bytes of
  salt calldata to the CREATE2 factory are added and counted as nonzero, so the figure is a slight upper bound.

## Where Tenure's gas goes

Most of the rebalance overhead is **storage writes, by design**. Every measured decision leaves an on-chain record that
anyone can later settle and audit. A state diff of one steady-state rebalance shows the hook writing **13 fresh
slots** and about 18 rewrites:

- `RebalanceRecord`: 8 new slots (old/new range, idle before/after, NAV before, block, settled flag).
- Fee snapshots for the new record, plus exit marks on the previous record when its range is abandoned before
  settlement (tenure-math 4b). That case is skipped if the previous record has already settled.
- The pending holdings snapshot (9 slots, rewritten each rebalance) and the budget state.
- About 20 cold reads of PoolManager state (slot0, positions, fee growth) and the oracle, taken twice (before and
  after) so the hook measures independently of the curator.

Swappers pay almost nothing. The hook adds about 15-17k gas to a normal swap. The one exception is a swap that
settles a due markout (only on pools that opt into `autoSettlePerSwap = 1`). Pools that set it to 0 move all
settlement cost to keepers (`settleMany`), and the cost per extra record falls to about 82k.

Perspective: one rebalance costs about $16 of overhead at the illustrative mainnet price. That is less than one basis
point on a vault above $200k, and a cent or so on an L2. Curators rebalance on the order of hours to days, not per
block.

## Optimization opportunities (not done; recorded for later)

- **Pending snapshot in transient storage.** `_pending` is written in `beginRebalance` and read in `endRebalance` in
  the same transaction. Moving it to `tstore` would remove about 9 cold slot rewrites per rebalance (roughly 40-45k).
  Hook bytecode headroom is tight (48 B under the size guard), so first move code to `TenureScorer`.
- **Pack `RebalanceRecord`.** Ranges and the block number fit in fewer slots. Idle amounts could be stored as
  `uint128`, which needs a bounds argument.
- **Skip the redundant re-reads** of slot0 and fee growth between the snapshot and the scoring step.

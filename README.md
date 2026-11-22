# Tenure: earned autonomy for AI liquidity curators

A Uniswap v4 hook. It does not try to detect whether an AI curator is compromised. It measures the damage the
curator's decisions cause at a fair price, and the curator's autonomy shrinks automatically when it starts losing
depositors' money.

> The full README (problem, layers, architecture, results, threat model) is task M6.1 in `PLAN.md`. For now:
> results in [`docs/RESULTS.md`](docs/RESULTS.md), the local demo in [`docs/DEMO.md`](docs/DEMO.md), the math in
> [`docs/MATH.md`](docs/MATH.md), the threat model in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Build and test

```bash
forge test                                  # full suite (default profile, test-only build)
python -m pytest sim -q                     # Python reference model + vector freshness
FOUNDRY_PROFILE=deploy forge build --sizes  # what ships: via-IR, hook must stay >= 2,000 B under EIP-170
```

Deploy only with `FOUNDRY_PROFILE=deploy`. The hook links the external library `TenureScorer`; forge deploys
and links it automatically (`script/DeployTenureHook.s.sol`).

## Settlement cost model (M5.4)

Each rebalance is scored twice. The immediate leakage is charged in `endRebalance`, which the vault pays. The
markout is settled W blocks later. Settling is permissionless, and each pool chooses who pays for it:

| Per-pool `autoSettlePerSwap` | Who settles | Swapper's extra gas (`afterSwap`) |
|---|---|---|
| `1` (keeper-free) | the next swap after a record is due, **at most one record per swap** | ~200k once per due record; ~0 otherwise |
| `0` (opt-out) | keepers, via `settle(id)` or `settleMany(ids)` | ~0: no settlement work in swaps |

Measured `afterSwap` overhead of one fee-aware settlement (`snapshots/TenureHook.<profile>.json`,
`test/TenureHookScoring.t.sol`, `test/TenureHookKeepers.t.sol`):

| | default profile | deploy profile (via-IR, what ships) |
|---|---|---|
| swap, nothing due | 117,746 | 116,719 |
| swap, 1 record due, auto-settle on | +204,822 | +201,514 |
| swap, 3 records due, auto-settle on (still settles 1) | +139,155 | +134,747 |
| swap, 3 records due, auto-settle **off** | -2,798 (no settlement) | -2,815 |

Why a settlement costs ~200k: it must read the pool's fee growth (globals plus each range's tick info, all cold)
so that both the curator's range and the counterfactual are credited the LP fees they would have earned. Without
fees, honest liquidity provision would score as pure impermanent loss. The rest is the markout itself: two
position valuations at the fair price, plus a risk-budget update written to storage once. A pool with heavy swap
flow can set `autoSettlePerSwap = 0` and run a keeper. `settleMany` skips records that are already settled, not
yet due, or unknown, so a keeper's batch never fails on a race. The batch reverts only if the oracle is stale or
spot is too far from fair, which is the same anti-gaming rule `settle` applies.

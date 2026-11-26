# Tenure Lab

A judge-facing, read-only frontend for Tenure: https://cephei18.github.io/tenure/

No wallet, no keys, no transactions. Every number on the page comes from one of three places:
1. **The chain:** read-only calls to the deployed contracts on Unichain Sepolia.
2. **Committed data:** CSV and JSON files in this repository.
3. **Ported math:** an exact BigInt port of the contracts' math, run in the browser.

## Run locally

Requires Node 20.

```bash
cd frontend
npm ci
npm run dev      # http://localhost:5173/tenure/
npm test         # TS math vs test/vectors, losses.csv replay vs the hook, timeline vs docs
npm run build    # static site in dist/ (base path /tenure/)
npm run preview  # serve dist/ at http://localhost:4173/tenure/
```

The ABI fragments in `src/abi/` were copied from Foundry's build output. To refresh them after `forge build` at the
repo root, run `npm run abi`.

## What each section proves

| Section | Shows | Source |
|---|---|---|
| **Live** | Pool A's tier and budget, vault B's `relayFrozen()`, vault A's remaining shares and the demo counters, read from the deployed contracts. Below that, a timeline of the proven live sequence (restore, re-freeze, Lasna reaction, relay, full exit while FROZEN), linked to Uniscan and Reactscan. | viem `readContract` against `https://sepolia.unichain.org`, with 3 retries. The RPC can be changed in the page or with `?rpc=<url>`. If the RPC fails, the page shows the last values recorded in [`src/data/live-snapshot.json`](src/data/live-snapshot.json) behind a banner. Addresses come from `deployments/*.json`. The timeline is built from `docs/INCIDENT_REACTIVE.md` and `docs/RESULTS.md`. |
| **Replay** | The headline scenario, animated: runs A (honest), B (static caps) and C (Tenure), with NAV, budget, tiers, and markers for the poisoning, attack rounds, RESTRICTED and FROZEN. Below it, the 20-seed sweep. The headline numbers (20/20 frozen, honest curator never restricted, about 59% less attacker profit) are computed from the CSVs. | `docs/results/headline.csv`, `sweep.csv`, `losses.csv` |
| **Playground** | The poisoned curator's real per-decision losses, re-scored with your risk-budget parameters. It shows when the curator would freeze, how many decisions it still makes, the total loss charged, whether the honest run would be falsely restricted, and a comparison with a static per-action cap. | `docs/results/losses.csv` (exported by `test/scenario/LossesExport.t.sol`) and the RiskBudget port |
| **Math** | Drag a new range and move the pool and fair prices to see holdings, NAV at the fair price, immediate leakage and markout alpha against doing nothing. | Ports of PositionValue and DecisionScore |

## Correctness

- `src/math/` ports `sim/model.py`'s integer layer (which `src/libraries/*.sol` matches bit for bit) to BigInt.
- `src/math/vectors.test.ts` checks the ports against **all 1,980 differential-test vectors** in `test/vectors/`,
  the same vectors the Solidity differential tests use, with exact equality:

  | File | Checked |
  |---|---:|
  | holdings | 240 |
  | nav | 240 |
  | leakage | 240 |
  | alpha | 240 |
  | loss | 240 |
  | budget | 300 ops |
  | fees | 240 |
  | chainlink | 240 |

- `src/lib/replay.test.ts` replays every recorded scoring event of runs A, B and C. After each event, the replay
  must equal the hook's own emitted budget and tier exactly (and bMax, for markouts). It also checks that run C
  freezes at block 170 and that the attack-round rule reproduces the scenario's counters (25 and 3).
- `src/lib/timeline.test.ts` fails if any transaction hash or block in the timeline is missing from the committed
  docs.
- **Display only:** float conversions (tokens, percentages, decimal prices). All scoring stays in BigInt.
- **Not vector-checked:** the Math section's sizing helpers (`src/math/liquidity.ts`: LiquidityAmounts and an
  idealized swap at spot). They only build the example; they are not part of Tenure's scoring.

## Deploy

[`.github/workflows/pages.yml`](../.github/workflows/pages.yml) tests, builds and publishes on every push to
`main` that touches the frontend or its data. It needs no secrets. One-time setup: in the repo, go to Settings →
Pages → Source and choose "GitHub Actions".

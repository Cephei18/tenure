# Tenure Lab

A judge-facing, read-only frontend for Tenure, hosted on Vercel.

No wallet, no keys, no transactions. Every number on the page comes from one of three places:
1. **The chain:** read-only calls to the deployed contracts on Unichain Sepolia.
2. **Committed data:** CSV and JSON files in this repository.
3. **Ported math:** an exact BigInt port of the contracts' math, run in the browser.

## Run locally

Requires Node 20.

```bash
cd frontend
npm ci
npm run dev      # http://localhost:5173/
npm test         # TS math vs test/vectors, losses.csv replay vs the hook, timeline vs docs
npm run build    # static site in dist/ (base path "/"; GITHUB_PAGES=true builds for /tenure/)
npm run preview  # serve dist/ at http://localhost:4173/
```

The ABI fragments in `src/abi/` were copied from Foundry's build output. To refresh them after `forge build` at the
repo root, run `npm run abi`.

## What each section proves

| Section | Shows | Source |
|---|---|---|
| **Live** | Pool A's tier and budget, vault B's `relayFrozen()`, vault A's remaining shares and the demo counters, read from the deployed contracts. Below that, a timeline of the proven live sequence (restore, re-freeze, Lasna reaction, relay, full exit while FROZEN), linked to Uniscan and Reactscan. | viem `readContract` against `https://sepolia.unichain.org`, with 3 retries. The RPC can be changed in the page or with `?rpc=<url>`. If the RPC fails, the page shows the last values recorded in [`src/data/live-snapshot.json`](src/data/live-snapshot.json) behind a banner. Addresses come from `deployments/*.json`. The timeline is built from `docs/INCIDENT_REACTIVE.md` and `docs/RESULTS.md`. |
| **Replay** | The headline scenario, animated: runs A (honest), B (static caps) and C (Tenure), with NAV, budget, tiers, and markers for the poisoning, attack rounds, RESTRICTED and FROZEN. Below it, the 20-seed sweep. The headline numbers (20/20 frozen, honest curator never restricted, 59% less median attacker profit) are computed exactly from the CSVs and rounded half up, the rule stated in `docs/RESULTS.md`. | `docs/results/headline.csv`, `sweep.csv`, `losses.csv` |
| **Playground** | The poisoned curator's real per-decision losses, re-scored with your risk-budget parameters. It shows when the curator would freeze, how many decisions it still makes, the total loss charged, whether the honest run would be falsely restricted, and a comparison with a static per-action cap. | `docs/results/losses.csv` (exported by `test/scenario/LossesExport.t.sol`) and the RiskBudget port |
| **Math** | Drag a new range and move the pool and fair prices to see holdings, NAV at the fair price, immediate leakage and markout alpha against doing nothing. | Ports of PositionValue and DecisionScore |

## Correctness

- `src/math/` ports `sim/model.py`'s integer layer (which `src/libraries/*.sol` matches bit for bit) to BigInt.
- `src/math/vectors.test.ts` checks the ports against **all 1,992 differential-test vectors** in `test/vectors/`,
  the same vectors the Solidity differential tests use, with exact equality:

  | File | Checked |
  |---|---:|
  | holdings | 240 |
  | nav | 240 |
  | leakage | 240 |
  | alpha | 240 |
  | loss | 240 |
  | budget | 312 ops (16 sequences, incl. tier boundaries) |
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

**Vercel** (the live site): import the repo, set **Root Directory** to `frontend`, and keep the Vite defaults
(build `npm run build`, output `dist`). No `vercel.json` or environment variables are needed; the base path is `/`.
The build imports five files from **outside** `frontend/`, which Vercel must include. Its project setting
"Include files outside the root directory in the Build Step" covers this, and is on by default:

- `docs/results/headline.csv`, `docs/results/sweep.csv`, `docs/results/losses.csv`
- `deployments/1301.json`, `deployments/5318007.json`

The tests (not the build) also read `test/vectors/*.json`, `README.md`, `docs/RESULTS.md` and
`docs/INCIDENT_REACTIVE.md`.

**CI:** [`.github/workflows/frontend-ci.yml`](../.github/workflows/frontend-ci.yml) runs `npm test` and
`npm run build` on every push that touches the frontend or its data.

**GitHub Pages (fallback, manual only):** [`.github/workflows/pages.yml`](../.github/workflows/pages.yml) builds
with `GITHUB_PAGES=true` (base `/tenure/`) and deploys when started by hand. It needs Settings → Pages → Source:
"GitHub Actions".

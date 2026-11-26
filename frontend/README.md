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
repo root, run `npm run abi`. `npm run tokens` re-exports the design tokens (below).

URL options: `?demo=1` starts the demo tour on load (for screen recording); `?tune=1` opens the Tune drawer;
`?rpc=<url>` picks the Unichain Sepolia RPC.

## Sections: what the user can do

| Section | The user can | Data |
|---|---|---|
| **Overview** | See the pitch and three live tiles: vault A's tier, a budget gauge with the 20% / 50% thresholds, vault B's `relayFrozen()`. "Run the attack" jumps to the Simulator and plays B vs C; "Watch demo mode" starts the tour. | viem reads of the deployed hook and vaults |
| **Simulator** | Pick a scenario (honest, poisoned + static caps, poisoned + Tenure) or **Compare B vs C** side by side. Play, pause, scrub (markers for poisoning, attack rounds, RESTRICTED, FROZEN), 1x / 2x / 4x. Watch the budget ring, tier badge, NAV line, charged-loss counter and event toasts ("Attack round 2 · vault leaks 91.7 at once"). Open **Tune Tenure** to change bucket size, refill time, thresholds and a static cap: the real losses are re-scored live ("Freezes after 9 of 52 decisions · loss 2,471 vs 8,376"). Below: the 20-market sweep and three headline numbers. | `docs/results/headline.csv`, `losses.csv`, `sweep.csv`; RiskBudget port |
| **Live proof** | Follow the 8 proven steps (Unichain → Lasna → Unichain → withdraw), each with one line and an explorer link; read "read from chain at block N"; refresh; change the RPC. Falls back to the last recorded values behind a banner when the RPC is down. | viem reads; `src/data/timeline.ts` (every hash checked against the docs); `src/data/live-snapshot.json` |
| **How grading works** | Drag a liquidity range (or its edges, also with arrow keys), move the fair price, the pool price at the decision and the price W blocks later. Three tiles: holdings value, leakage, markout vs did nothing, each with a one-line meaning. **Show the math** reveals the formulas with exact wei values. | Ports of PositionValue and DecisionScore; `src/math/example.ts` builds the rebalance |
| **Demo mode** | A ~75 s scripted tour: spotlight + caption bar, plays B vs C through the freeze, the sweep, the live relay and the withdrawal. Pause, skip, exit (Esc). | Same data; captions' numbers are tested against it |

Honesty notes: the Simulator's counter is the **loss the hook charged to the curator** (from the recorded scoring
events); the scenario does not record per-round attacker profit, so the page does not show one. Toasts quote each
round's immediate leakage as charged by the hook.

## Design system

All tokens live in [`src/theme/tokens.ts`](src/theme/tokens.ts) (colours, fonts, spacing, radii, motion), mirrored as
CSS variables in `src/index.css` and exported to [`docs/design-tokens.json`](../docs/design-tokens.json) for the
slide deck (`npm run tokens`). `tokens.test.ts` fails if the CSS or the JSON drift, and checks WCAG AA contrast of
every text colour on every surface. Tier colours: FULL `#4ade80`, RESTRICTED `#fbbf24`, FROZEN `#e11d48`.
Motion is wall-clock driven (keeps time in background tabs and screen recorders) and is disabled under
`prefers-reduced-motion`. Icons: `lucide-react` (pinned).

Screenshots of every section at 1440 px and 390 px, and of demo mode mid-run, are in [`screenshots/`](screenshots/).

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
  docs, if the "2 blocks later" relay delay disagrees with them, or if an explorer link is malformed.
- `src/lib/sim.test.ts` checks the Simulator's events (rounds, RESTRICTED, FROZEN), the charged-loss counter and
  the Tune re-scoring: defaults freeze after 9 of 52 decisions at block 170, a bigger bucket never freezes earlier,
  FROZEN is sticky, and the static-cap comparison.
- `src/lib/stats.test.ts` checks that the sweep medians shown equal those quoted in `README.md` and `docs/RESULTS.md`.
- `src/sections/demoScript.test.ts` checks the tour length (60-90 s), caption length, spotlight targets, that the
  captions land on their events, and that every number in a caption comes from the data.
- `src/math/example.test.ts` checks the worked example (no leakage at fair; leakage grows with the price push).
- **Display only:** float conversions (tokens, percentages, decimal prices). All scoring stays in BigInt.
- **Not vector-checked:** the grading example's sizing helpers (`src/math/liquidity.ts`: LiquidityAmounts and an
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

# Tenure UHI11 demo-video deck

Eleven slides, 16:9 (1920x1080), in the red/pink theme of the Tenure Lab.

| File | What it is |
|---|---|
| `deck.html` | The deck. One self-contained file (plus `assets/` and `fonts/`), arrow-key navigation, speaker notes. |
| `Tenure_UHI11.pdf` | Rendered from `deck.html` with headless Chromium, one slide per page (1920x1080 px pages). |
| `Tenure_UHI11.pptx` | Editable PowerPoint / Google Slides version: same text, images and speaker notes. |
| `assets/` | Every chart and diagram as a standalone 2x PNG (A-H below). |
| `slide-previews/` | `slide-NN.png`, a 1920x1080 render of each slide (used for the visual check). |
| `data/live_ticks.csv` | The live testnet budget series behind chart D (see "Where every number comes from"). |
| `fonts/` | Inter 400/600/800 (SIL Open Font License, from Google Fonts), used by the HTML and the charts. |
| `src/` | Generators: `make_assets.py`, `render.py`, `build_pptx.py`, `lab_screenshots.py`. |

## Present

Open `deck.html` in Chrome or Edge (double-click works; no server needed).

| Key | Action |
|---|---|
| Right / Down / Space / PageDown / Enter, or click the right two thirds | next slide |
| Left / Up / PageUp / Backspace, or click the left third | previous slide |
| Home / End | first / last slide |
| N | toggle speaker notes (overlay at the bottom) |
| F | fullscreen |

`deck.html#5` opens slide 5. The deck scales to any window and keeps 16:9. For the video, record it fullscreen
at 1920x1080, or use the PDF. Slide 9 is where you switch to the Lab screen recording.

## Edit

- **Words, layout:** open `Tenure_UHI11.pptx` in PowerPoint or Google Slides. Every text is a real text box and
  the notes are in the speaker-notes pane. Install the three `fonts/Inter-*.ttf` first if you want the exact look.
  Without Inter, PowerPoint substitutes a system sans (checked on this machine: nothing overflows).
- **HTML deck:** edit `deck.html` directly. Colours are CSS variables at the top (copied from
  `docs/design-tokens.json`). Speaker notes are the `<aside class="notes">` blocks. The Lab URL appears on
  slides 9 and 11 and in their notes. Slide 6's code excerpts are the `.code` blocks (the PPTX builder parses them
  from `deck.html` too, so edit them there and rebuild both).
- **Charts:** edit `src/make_assets.py` (one function per chart). Charts read colours from
  `docs/design-tokens.json` when it exists, so they follow the Lab's theme.

## Regenerate

```bash
pip install matplotlib python-pptx pillow websockets      # plus Chrome or Edge installed
python docs/slides/src/make_assets.py [lab_screenshot_dir]  # assets/*.png (H only if a screenshot dir is given)
python docs/slides/src/render.py                          # slide-previews/*.png + Tenure_UHI11.pdf
python docs/slides/src/build_pptx.py                      # Tenure_UHI11.pptx (notes parsed from deck.html)
```

Lab screenshots (asset H) come from the live site, not a local build:
`python docs/slides/src/lab_screenshots.py` (default URL https://tenure-hazel.vercel.app/). It writes the four
`assets/H_lab_*.png` directly: 1024 px viewport at 2x, sticky nav and toasts hidden, background padding trimmed.
Slide 9 crops two of them in place (Overview: from the buttons down; Simulator: down to the budget rings); the
full captures stay in `assets/` for reuse.

## Assets

| | File | Used on |
|---|---|---|
| A | `A_architecture.png`: curator -> vault -> PoolManager <-> TenureHook (+ TenureScorer), Chainlink, Lasna RCs, freeze to vault B | slide 8 |
| B | `B_lifecycle.png`: beginRebalance -> unlock -> endRebalance -> markout 50 blocks later -> budget | slide 5 |
| C | `C_tiers.png`: FROZEN < 20% / RESTRICTED 20-50% / FULL >= 50%, drain/refill, sticky, restore -> 35% | slide 4 |
| D | `D_live_budget.png`: vault A budget per demo tick (1-90) on Unichain Sepolia, tier bands | slide 9 |
| E | `E_relay_timeline.png`: freeze 68,837,823 -> Lasna 9,291,302 -> relay 68,837,825 | slide 7 |
| F | `F_results.png`: slow bleed 9.52% vs 1.74%; median attacker profit 1,587 vs 650 | slide 10 |
| G | `G_playground.png`: losses let through 8,376 / 8,376 (0.2% cap, blocks 0 of 52) / 2,471 (FROZEN after 9 of 52) | slide 10 |
| H | `H_lab_overview.png` (hero + three live tiles), `H_lab_simulator.png` (Compare B vs C at block 172, just after C's FROZEN marker, budget rings), `H_lab_live.png` (Live proof section), `H_lab_live_steps.png` (the 8-step grid, "2 blocks later" on the relay card): captured from the live site https://tenure-hazel.vercel.app/ | slide 9 |

Tier colours are the Lab's exactly: FULL `#4ade80`, RESTRICTED `#fbbf24`, FROZEN `#e11d48`
(`docs/design-tokens.json`, generated from `frontend/src/theme/tokens.ts`). Static caps vs Tenure use the Lab's
run colours (amber `#fbbf24` vs pink `#f472b6`).

## Where every number comes from

| Number | Source |
|---|---|
| Stream Finance ~$10B -> ~$6.9B; Princeton "AI Agents in Cryptoland" (arXiv 2503.16248) | README.md "The problem" |
| 20/20 frozen, 60-76 blocks; honest curator never restricted; attacker profit 1,587 -> 650 (-59%, median) | docs/RESULTS.md; recomputed from docs/results/sweep.csv (1,586.99 / 650.21 -> -59.0%) |
| Slow bleed 9.52% vs 1.74% of NAV | docs/results/slow_bleed.csv final row vs the test's starting NAV (500 token0 + 1,000,000 token1 at tick 76,012, `test/scenario/SlowBleed.t.sol`): 9.5185% and 1.7412%, rounded half up |
| 52 decisions; 8,376 unchecked; 2,471 charged; FROZEN after 9; 0.2% cap blocks 0 | docs/results/losses.csv (run B), re-scored with the committed `frontend/src/lib/replay.ts` (`rescore`, `staticCap`) at the default parameters; run with vite-node on 2026-11-26 |
| 537,900 gas per rebalance, $16.14 mainnet, ~$0.016 on a 1 s L2, swap +17,205 (17.4% over 99,105) | docs/GAS.md |
| ~146k gas for a swap that settles a markout | docs/GAS.md (+146,087 vs nothing due) |
| Relay blocks 68,837,823 -> 9,291,302 -> 68,837,825, 2 blocks; ~2 s | docs/INCIDENT_REACTIVE.md (block timestamps 1795690251 -> 1795690253) |
| Poisoned tick 20, RESTRICTED tick 23, FROZEN tick 25, budget series | `data/live_ticks.csv`: the `DemoDirector` `Tick(tick, tier, budgetPct10, nav, note)` events of 0x4503...80f1 on Unichain Sepolia, read with `eth_getLogs` from the public RPC (read-only) for blocks 68,758,556-68,850,085 (210 ticks) |
| Depositor withdrew all shares while FROZEN (block 68,844,903) | README.md / docs/RESULTS.md |
| 258 Foundry, 53 Python, 48 frontend tests | fresh runs on 2026-11-26: `forge test` (35 suites, 258 passed), `python -m pytest sim -q` (53 passed), `npx vitest run` in frontend/ at 7949bc2 (8 files, 48 passed) |
| 1,992 vectors, to the wei | vitest output (`total=1992`); the Solidity differential tests (`test/diff/`) use exact `assertEq` |
| 7 invariants over 128,000 random calls | README.md threat model summary |
| TenureHook 22,528 B runtime (limit 24,576 B, 91.7%) | fresh `FOUNDRY_PROFILE=deploy forge build --sizes` on 2026-11-26 (margin 2,048 B; TenureScorer 6,302 B) |
| Slide 6 permission bits 0x800 / 0x200 / 0x40 | `lib/uniswap-hooks/lib/v4-core/src/libraries/Hooks.sol`: BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11, BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9, AFTER_SWAP_FLAG = 1 << 6; hook `0xBe78...8A40` (deployments/1301.json), low 14 bits 0x0A40 |

## Visual check (done for every slide)

Each `slide-previews/slide-NN.png`, the PDF pages and the PowerPoint export (via PowerPoint, Inter not installed)
were inspected for overflow, clipped text, overlaps and contrast. Fixed along the way: slides 1 and 3 showed
through every other slide (a CSS `display` override); diagram A's freeze arrow crossed TenureScorer; diagram B's
last box was clipped; diagram C's 35% marker cut the RESTRICTED label; chart D's labels touched the step line;
chart E's top labels were clipped; diagram A's small labels were under 15 px at slide size (raised); the Lab
captures were too small to read (re-shot at a 960 px viewport) and had the sticky nav bar painted across them;
orphan words on slides 2 and 9. Contrast on `#14070c`: white 19.7:1, `#fbcfe8` 14.3:1, muted `#c99aae` 8.2:1
(the smallest text, 19-20 px), pink `#f472b6` 7.4:1. Rose/FROZEN `#e11d48` is 4.2:1: fine for its large uses
(the 68 px "20/20", tier pills with white text at 4.7:1), slightly under 4.5:1 for the small FROZEN labels in
charts D and E. Those keep the Lab's exact FROZEN colour on purpose and always sit next to the word FROZEN.

Final pass (live Lab, 7949bc2): slide 8 rebuilt as a 2x2 grid from the live-site captures. Fixed: the Overview
crop cut through the subtitle (now starts at the buttons); hyphens rendered spaced out ("tenure - hazel",
"valid - looking") because Inter's tabular figures were on for all text (now numbers only); PowerPoint drew the
Lab link in the theme's dark-blue hyperlink colour (theme hyperlink set to the deck pink). All 10 HTML previews,
the PDF and a PowerPoint export were re-checked at 1920x1080.

Slide 6 "Inside the hook" added (slides 6-10 renumbered to 7-11). Its code is verbatim from `src/TenureHook.sol`
(4-space contract indent stripped; source line numbers in the gutter; `// ...` marks trims; endRebalance 366 and
_afterSwap 549 are wrapped onto a second line to fit). Checked in the HTML preview, the PDF and a PowerPoint export:
no overflow (widest code line ends 42 px inside its panel), code 22 px Consolas. Code colours on `#1f0a12`: keywords
pink, text `#fbcfe8`, comments muted, `true` FULL green, all above 4.5:1.

## Known limits

- In the slide 9 step-grid screenshot, the card body text is about 10-11 px at 1080p: crisp, but small. The grid
  is there to show the 8-step shape and the "2 blocks later" badge. The screen recording that follows slide 9
  shows it full size.
- The Lab screenshots show live chain state as of 2026-11-26 (read at block ~68.86M). Re-run
  `lab_screenshots.py` before recording if the live values change.
- Slide 7: the Reactive settlement callback has not landed live yet (README.md), so the slide says it is proven
  in tests. The freeze relay is live.
- Slide 6 code uses Consolas (Windows / Office). On a machine without it the HTML falls back to the system
  monospace, which is wider and could clip the longest line; present from Windows or use the PDF.
- In the PPTX, the theme's hyperlink colour is set to the deck pink, so the Lab link stays readable on the dark
  background. PowerPoint underlines hyperlinks.

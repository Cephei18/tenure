# sim/ — Tenure reference model

| File | Purpose |
|---|---|
| `model.py` | Integer layer that mirrors the Solidity math bit-for-bit (TickMath, SqrtPriceMath, FullMath ports; same rounding), plus a `Fraction` ideal layer for error-direction checks. No floats. |
| `test_model.py` | Hand-checked examples + randomized invariants. |
| `gen_vectors.py` | Writes `test/vectors/*.json` from the integer layer (fixed seed `0x7E2A`). |
| `test_vectors_fresh.py` | Fails if committed vectors are stale vs the model. |
| `plot_results.py` | Charts from `docs/results/*.csv` -> `headline.png`, `sweep.png`, `slow_bleed.png` (matplotlib; floats OK, plotting only). |
| `test_plot_results.py` | Smoke test: the charts regenerate from the committed CSVs. |

```
python -m pytest sim -q          # model tests
python sim/gen_vectors.py        # regenerate vectors after ANY model change, then commit them
python sim/plot_results.py       # regenerate docs/results/*.png after forge test rewrites the CSVs
forge test --match-path "test/diff/*"   # Solidity differential tests consume the vectors
```

## Vector files
All numbers are decimal strings (uint256/int256-safe). Each file: `{seed, count, cases: [...]}`.

- `holdings.json` — position (ticks, L) + idle at raw sqrt price, rounding flag -> amount0/amount1. Covers spot
  below/inside/above range, exactly at A and B, full range, 1-spacing ranges, MIN/MAX tick ranges, tiny and huge L.
- `nav.json` — amounts + fair sqrt price (incl. MIN/MAX extremes) + rounding flag -> NAV.
- `leakage.json` — old/new positions + idle, spot, fair -> NAV_before (up) and immediate leakage.
- `alpha.json` — old/new positions + idle, spot and fair at T -> markout alpha.
- `loss.json` — value, navRef -> lossWad (ceil) and gainWad (floor).
- `budget.json` — 12 sequences x 25 ops with default params. kind: 0 refill, 1 charge(a=lossWad,b=lossValue),
  2 credit(a=gainWad,b=gainValue), 3 restore. charge/credit refill to `block` first. Expected state after each op.
- `chainlink.json` — Chainlink answers + feed/token decimals (6/8/18, direct and two-feed) -> fair sqrtPriceX96,
  or `ok: false` where Solidity must revert (non-positive answer, overflow, out of range). M4.6.

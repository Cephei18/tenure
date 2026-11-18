---
name: tenure-math
description: Exact specification of Tenure's math — position holdings, NAV at fair price, immediate leakage, markout alpha, loss fraction, leaky-bucket risk budget, tiers and reputation — plus fixed-point, rounding and differential-testing rules. Use this skill before writing or modifying ANY math in Solidity or in sim/ Python, before generating test vectors, and whenever a numeric test disagrees between Python and Solidity.
---

# Tenure math specification

All formulas here are the source of truth. If code and this file disagree, fix the code (or, if this file is
wrong, fix it and explain why in CLAUDE.md Learnings and docs/MATH.md).

## Notation and units
- `S` = pool sqrt price, Q64.96 (`sqrtPriceX96`). `S*` = FAIR sqrt price from the reference oracle, Q64.96.
- Range `[tL, tU)` with sqrt prices `A = getSqrtPriceAtTick(tL)`, `B = getSqrtPriceAtTick(tU)`, `A < B`.
- `L` = position liquidity (uint128). Amounts are raw token units (no decimals adjustment inside the math).
- Price `P = (S / 2^96)^2` = token1 per token0 in raw units. NAV is denominated in token1 raw units.
- Fractions use WAD (1e18 = 100%). `Q96 = 2^96`.

## 1. Holdings of a CL position at sqrt price S
```
if S <= A:  amount0 = L * (B - A) / (A * B) * Q96      amount1 = 0
if S >= B:  amount0 = 0                                 amount1 = L * (B - A) / Q96
else:       amount0 = L * (B - S) / (S * B) * Q96      amount1 = L * (S - A) / Q96
```
In Solidity use v4-core `SqrtPriceMath.getAmount0Delta(lower, upper, L, roundUp)` and
`getAmount1Delta(lower, upper, L, roundUp)` with the clamped bounds above. Do not hand-roll these.
Holdings of the vault `H = position amounts + idle token balances + fees owed` (section 4b).
**Key property:** holdings at a given S are path-independent (ignoring fees). This is why we can compute the
counterfactual "if the curator had not rebalanced" exactly.

## 2. NAV at fair price
```
NAV(H, S*) = amount0 * (S*/Q96)^2 + amount1
Solidity:   mulDiv(mulDiv(amount0, S*, Q96), S*, Q96) + amount1      // nested to avoid 320-bit overflow
```
NEVER value at pool spot S. Spot is manipulable in-block; the fair price is the whole point.

## 3. Immediate leakage of a rebalance at block t
```
L_imm = NAV(H_before, S*_t) - NAV(H_after, S*_t)        (signed; positive = value lost)
```
H_before is snapshotted in beginRebalance (before unlock), H_after in endRebalance (after unlock), both with the same
S*_t. A rebalance with no swap at a fair pool price leaks ~0 (only rounding). Swapping at a manipulated price, or
removing/adding while spot != fair, shows up as positive leakage.

## 4. Markout alpha after window W
Stored in the RebalanceRecord at time t: old range+L (`R_old`), new range+L (`R_new`), idle balances after (`I_new`),
idle balances before (`I_old`). At settlement time T >= t + W with pool spot `S_T` and fair `S*_T`:
```
H_new(T) = holdings(R_new, S_T) + I_new
H_cf(T)  = holdings(R_old, S_T) + I_old            // counterfactual: curator did nothing
alpha    = NAV(H_new(T), S*_T) - NAV(H_cf(T), S*_T)
```
Negative alpha = the decision destroyed value vs doing nothing. Being picked off by an attacker shows up because the
new range sits where spot diverges from fair. Known limitation (document it, don't hide it): S_T itself is affected by
the curator's own liquidity (second-order), fees are excluded until M3.3 (fees in alpha).

## 4b. LP fees in the markout (M3.3)
Holdings include uncollected fees owed on the vault position (exactly v4's formula), in H_before, H_after and NAV.
At settlement each side gets the fees its range earned since the record:
```
fees(range, L) = L * dInside / 2^128         dInside = feeGrowthInside(T) - feeGrowthInside(t)   (mod 2^256)
H_new(T) += feesNew   (round DOWN)           H_cf(T) += feesCf   (round UP)
```
- Exact when trustworthy: both ticks initialized at settlement and dInside <= dGlobal (per token).
- New range abandoned before settlement: the hook snapshots its fee growth at the exit point; both sides are
  compared over [t, exit]. New = exact; cf = same growth if same ticks, else L_old * dGlobal[t, exit].
- Otherwise curator-adverse fallback: new -> 0, cf -> L_old * dGlobal (as if always in range).
- A no-op decision (same range, same idle) still scores exactly 0.

## 5. Loss charged to the budget
```
lossValue = max(0, L_imm)  at endRebalance
          + max(0, -alpha) at settle
lossWad   = ceilDiv(lossValue * 1e18, NAV_before)      // fraction of NAV at the time of the rebalance
```
Positive alpha does NOT refill the budget (one lucky trade must not buy back autonomy). It only grows reputation.

## 6. Risk budget (leaky bucket) and tiers
State per curator/vault: `budget` (WAD of NAV), `bMax`, `lastBlock`, `tier`, `cumPositiveAlpha`.
```
refill:   budget = min(bMax, budget + r * (block - lastBlock))       // r in WAD per block, floor
charge:   budget = budget > lossWad ? budget - lossWad : 0            // never underflow
ratio  = budget * 1e18 / bMax
tier   = ratio >= 0.50e18 ? FULL : ratio >= 0.20e18 ? RESTRICTED : FROZEN
```
- FROZEN is sticky: refill alone never leaves FROZEN. Only guardian `restore()` after a timelock, which sets
  `budget = bMax * 0.35` (`restoreWad = 0.35e18`, lands in RESTRICTED) — autonomy is re-earned, not restored to full.
  ACCEPTED decision; config must keep `restrictedThreshold <= restoreWad < fullThreshold`.
- RESTRICTED tightens the mandate: max NAV fraction moved / 2, min range width * 2, cooldown * 2.
- "Fraction of NAV moved" (`maxMoveWad`) = value swapped between tokens in the rebalance, as WAD of NAV_before
  (ACCEPTED). A range move with no swap moves 0 by this measure; it is bounded instead by the max
  distance-of-range-center-from-fair-price rule.
- Suggested defaults (make them constructor/config params): `bMax0 = 0.02e18` (2% of NAV), `r` such that empty->full
  takes ~1 day of blocks, `W = 50` blocks, thresholds 50% / 20%.

## 7. Reputation (pool-native)
State: `cumAlphaWad` (net positive alpha, WAD of NAV) and `cumAlphaValue` (net positive alpha, token1 units).
```
on settle with alpha > 0 (credit):
  cumAlphaWad += alphaWad; cumAlphaValue += alpha
  bMax'  = min(bMaxCap, bMax0 + k * cumAlphaWad)          (WAD)
  budget = floor(budget * bMax' / bMax)   (unless FROZEN)  // ratio budget/bMax unchanged: NO refill
on any loss (charge, L_imm or negative alpha):
  cumAlphaWad   = sat_sub(cumAlphaWad, lossWad)            // losses reduce net positive alpha first
  cumAlphaValue = sat_sub(cumAlphaValue, lossValue)
  bMax'  = min(bMaxCap, bMax0 + k * cumAlphaWad)
  budget = sat_sub(min(budget, bMax'), lossWad)
depositCap = min(capMax, cap0 + m * cumAlphaValue)
```
ACCEPTED decisions:
- Positive alpha grows `bMax` and the deposit cap but NEVER refills spent budget.
- When bMax grows from positive alpha, scale the budget proportionally:
     budget_new = floor(budget_old * bMax_new / bMax_old)
  so budget/bMax is unchanged. Success never changes the tier; only time refill (or guardian restore from FROZEN)
  does. Reputation gain factor k must satisfy k <= 1e18 (WAD), enforced in the constructor
  (Tenure__ReputationGainTooHigh). Pump bound: each unit of alpha an attacker manufactures by paying the vault buys
  at most k <= 1 unit of extra allowed loss, so pumping is never profitable (argument in docs/MATH.md). The tier is
  kept, not recomputed, on credit, so the 1-wei floor cannot demote a curator sitting exactly on a threshold.
  k is a per-pool BudgetParams field, so the check lives in RiskBudget.validate (run by registerPool).
- Losses reduce cumulative positive alpha (saturating at 0), so reputation is net of losses and bMax / deposit
  cap can shrink back toward their base values.

## Rounding — always against the curator
- Holdings used for NAV_after and H_new: round DOWN. NAV_before and H_cf: round UP where the API allows.
- lossWad: ceil. Refill: floor. Tier ratio: floor.
- Tests must assert the direction, not just closeness.

## Differential testing method
- `sim/model.py` has TWO layers: (1) an integer layer that mirrors Solidity exactly (floor `//`, explicit ceil-div,
  nested mulDiv emulation, same rounding flags as SqrtPriceMath), and (2) a `fractions.Fraction` ideal layer.
- Vectors (`test/vectors/*.json`) store inputs and the integer-layer outputs. Solidity tests read them with
  `vm.readFile` + `vm.parseJson*` and must match EXACTLY. A separate Python test asserts integer-layer vs ideal error
  is <= a few wei and in the curator-adverse direction.
- Use a fixed RNG seed. Cover: S below/inside/above range, S exactly at A and B, full-range, 1-tick-spacing ranges,
  extreme ticks (near MIN/MAX usable), tiny and huge L, zero idle balances.
- No floats anywhere in model core. Floats are allowed only in plotting.

## Worked example to keep in docs/MATH.md
Pick one concrete rebalance (e.g. ETH/USDC-like prices with realistic decimals), compute H_before, H_after, L_imm,
alpha and the budget step by hand in the doc, and make one Solidity test assert those exact numbers.

# Tenure math

The specification lives in `.claude/skills/tenure-math/SKILL.md`. This file holds derivations and arguments.
Full derivations and the worked numeric example are added in M6.2.

## Reputation: proportional budget scaling and the pump bound (M2.6)

### Rule
When a settled rebalance shows positive alpha `g` (as a WAD fraction of NAV), reputation grows:

```
cumAlphaWad' = cumAlphaWad + g
bMax'        = min(bMaxCap, bMax0 + k * cumAlphaWad')        so  bMax' - bMax <= k * g
budget'      = floor(budget * bMax' / bMax)                  (unless FROZEN: budget unchanged)
tier'        = tier                                          (not recomputed)
```

`budget / bMax` is preserved within 1 wei, rounded down. Success never moves the tier: one lucky (or bought)
trade cannot lift a RESTRICTED curator back to FULL. Only time refill or a guardian restore change the tier
upward. The tier is kept rather than recomputed so the 1-wei floor cannot demote a curator sitting exactly on a
threshold either.

The previous rule added the new headroom to the budget (`budget += bMax' - bMax`). That preserves the deficit
but raises the ratio, so positive alpha alone could promote RESTRICTED -> FULL. M2.6 replaced it.

### Why k <= 1 (the pump bound)
Attack: an attacker who controls (or has poisoned) the curator pays the vault `X` of value, for example by trading
against the vault's range at a loss, so that a rebalance settles with manufactured positive alpha
`g = X / NAV`. The hope is that the extra reputation buys more room to bleed the vault later.

Let `rho = budget / bMax <= 1` be the budget ratio before the pump. After it:

```
budget' - budget  =  rho * (bMax' - bMax)   (up to a floor)
                 <=  rho * k * g
                 <=  k * g
                 <=  g                       iff  k <= 1
```

So the extra loss the curator may cause before reaching FROZEN is at most `g` (that is, at most `X` in value),
and the attacker paid exactly `X` to get it. **Under this premise** (the manufactured alpha is value actually paid
into the vault and kept there), net extractable value does not increase. Two effects make it strictly worse for
the attacker: losses first reduce `cumAlphaWad`, so bleeding shrinks `bMax` back toward its old value while the
budget is drained; and every rounding step (`floor` scaling, `ceil` loss) is curator-adverse.

**Scope: the bound does not cover alpha that is recorded but not kept.** M5.2 found such a case
(`docs/THREAT_MODEL.md` section 8). An accomplice pushes pool spot to the edge of the settlement band
(`maxSettleDev`) and settles there. The markout values the positions at that spot, so it records positive alpha.
The value behind it goes back out when spot returns to fair, and the accomplice's cost goes mostly to
third-party LPs as fees, not to the vault. Measured: +40.08 tokens of alpha for 36.11 tokens of cost, bMax +12.5%.
So the premise above does not hold and faking a track record is not ruled out. It is bounded instead:
- per record, by `maxSettleDev` (asserted under 0.1% of NAV in the test);
- overall, by `bMaxCap` and `capMax`.

The candidate fix, valuing the markout's hypothetical holdings at the fair price instead of at spot, is the first
item of M5.5. It would make every recorded alpha a value the vault keeps, which restores the premise.

With `k > 1` the inequality breaks: paying `X` buys up to `k * X` of loss allowance, and pumping is profitable.
`RiskBudget.validate` (called by `TenureHook.registerPool`) therefore reverts with
`Tenure__ReputationGainTooHigh` when `k > 1e18`.

The deposit cap also grows with `cumAlphaValue` (`m * X`), but deposit cap is not loss allowance: new deposits are
priced at NAV at the fair price, and every loss on them is still charged to the same budget.

### Evidence in tests
These prove the budget-side bound (extra loss allowance <= `g`) for a given `g`; they do not cover how `g` is
produced. The settlement-spot gap above is measured in
`test/attacks/OracleAttacks.t.sol::test_settlementSpot_cannotGriefDown_canInflateUp`.
- `test/unit/RiskBudget.t.sol::testFuzz_pumpNeverProfitable`: for random `k <= 1`, prior reputation, prior loss
  and pump size, the exact largest loss that leaves the curator un-frozen (binary search) grows by at most `g`.
  The same test fails for `k` in `[2e18, 3e18]` (mutation-checked).
- `testFuzz_pumpNeverProfitable_slowBleed`: the same bound for a slow bleed of 0.01%-of-NAV steps, within one
  step of granularity.
- `testFuzz_creditKeepsTierAndRatio`: the tier never changes on credit; `b1*m0 <= b0*m1 < (b1+1)*m0`.
- `test/TenureHook.t.sol::test_register_reputationGainAboveOne_reverts`: the hook rejects `k = 1e18 + 1`.
- `sim/test_model.py::test_pump_never_profitable`: the same property in the Python reference model.

## LP fees in the markout (M3.3)

Without fees, honest liquidity provision scores as pure impermanent loss against the counterfactual, so an honest
curator would bleed budget simply for doing its job. Each side of the markout is therefore credited the fees its
range earned over the window: `fees = L * dFeeGrowthInside / 2^128` (fee growth accumulators wrap mod 2^256).

The counterfactual range usually no longer exists (the vault was often its only LP, so its ticks were cleared),
so its fee growth cannot be read. The rules, from most to least exact:
1. The range's ticks are initialized at settlement and `dInside <= dGlobal`: exact.
2. The new range was abandoned before settlement: its fee growth was snapshotted at the exit point. Both sides are
   compared over `[t, exit]`; the new side is exact, the old side shares its growth if it is the same range,
   otherwise it gets the upper bound `L_old * dGlobal`.
3. Otherwise: new -> 0, counterfactual -> `L_old * dGlobal` (curator-adverse).

Rounding: new fees down, counterfactual fees up. Known limitation: rule 3's upper bound penalizes a curator whose
abandoned old range would in truth have gone out of range; it never favors the curator.
Evidence: `test/diff/DecisionScoreDiff.t.sol::test_diff_feesAlpha` (240 vectors, exact),
`test/TenureHookFees.t.sol` (exactness vs v4's owed fees, exit snapshot, fallback, 500-block honest run).

## Fair price from Chainlink feeds (M4.6)

With `a0` the token0 answer (fd0 decimals) and `a1` the token1 answer (fd1 decimals) in a common quote, and token
decimals dec0 and dec1, the raw pool price (token1 base units per token0 base unit) is
`P = a0 * 10^(fd1 + dec1) / (a1 * 10^(fd0 + dec0))`. A direct feed is the special case a1 = 1, fd1 = 0.
`sqrtPriceX96 = floor(sqrt(P * 2^192))` while P < 2^64 (exact to 1 unit). Above that, P * 2^192 would overflow, so
the code computes `floor(sqrt(P * 2^128)) << 32`; the result is then >= 2^128, so the relative error is < 2^-96.
Both round down. Worked example: ETH/USD = 3,000 and USDC/USD = 1 (8-decimal feeds), with WETH (18) as token0
and USDC (6) as token1. Then P = 3,000 * 10^6 / 10^18 = 3e-9 and sqrtPriceX96 = 4,339,505,179,874,779,489,431,521
(`test_wethUsdc_handExample`; `sim/test_model.py` checks it against the exact rational value).

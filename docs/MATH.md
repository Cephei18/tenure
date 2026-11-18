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
and the attacker paid exactly `X` to get it. Net extractable value never increases. Two effects make it strictly
worse for the attacker: losses first reduce `cumAlphaWad`, so bleeding shrinks `bMax` back toward its old value
while the budget is drained; and every rounding step (`floor` scaling, `ceil` loss) is curator-adverse.

With `k > 1` the inequality breaks: paying `X` buys up to `k * X` of loss allowance, and pumping is profitable.
`RiskBudget.validate` (called by `TenureHook.registerPool`) therefore reverts with
`Tenure__ReputationGainTooHigh` when `k > 1e18`.

The deposit cap also grows with `cumAlphaValue` (`m * X`), but deposit cap is not loss allowance: new deposits are
priced at NAV at the fair price, and every loss on them is still charged to the same budget.

### Evidence in tests
- `test/unit/RiskBudget.t.sol::testFuzz_pumpNeverProfitable`: for random `k <= 1`, prior reputation, prior loss
  and pump size, the exact largest loss that leaves the curator un-frozen (binary search) grows by at most `g`.
  The same test fails for `k` in `[2e18, 3e18]` (mutation-checked).
- `testFuzz_pumpNeverProfitable_slowBleed`: the same bound for a slow bleed of 0.01%-of-NAV steps, within one
  step of granularity.
- `testFuzz_creditKeepsTierAndRatio`: the tier never changes on credit; `b1*m0 <= b0*m1 < (b1+1)*m0`.
- `test/TenureHook.t.sol::test_register_reputationGainAboveOne_reverts`: the hook rejects `k = 1e18 + 1`.
- `sim/test_model.py::test_pump_never_profitable`: the same property in the Python reference model.

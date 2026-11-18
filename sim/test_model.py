"""Hand-checked tests for the Tenure reference model. Run: python -m pytest sim -q"""

import random
from dataclasses import replace
from fractions import Fraction

import pytest

from model import (
    FROZEN,
    FULL,
    MAX_SQRT_PRICE,
    MAX_TICK,
    MIN_SQRT_PRICE,
    MIN_TICK,
    Q96,
    RESTRICTED,
    WAD,
    Q128,
    U256,
    estimate_fees,
    fee_amounts,
    fee_growth_delta,
    markout_alpha_fees,
    BudgetParams,
    BudgetState,
    Position,
    b_max_for,
    charge,
    credit,
    deposit_cap,
    holdings,
    ideal_nav,
    ideal_position_holdings,
    immediate_leakage,
    init_state,
    loss_wad,
    gain_wad,
    markout_alpha,
    max_usable_tick,
    min_usable_tick,
    nav,
    position_holdings,
    refill,
    restore,
    sqrt_price_at_tick,
    tier_for,
    validate,
)

L = 10**18


# ---------------------------------------------------------------- TickMath port
def test_tickmath_known_values():
    assert sqrt_price_at_tick(0) == Q96
    assert sqrt_price_at_tick(MIN_TICK) == MIN_SQRT_PRICE
    assert sqrt_price_at_tick(MAX_TICK) == MAX_SQRT_PRICE
    # Uniswap's documented value for tick 1: sqrt(1.0001) * 2^96, rounded up
    assert sqrt_price_at_tick(1) == 79232123823359799118286999568
    assert sqrt_price_at_tick(-1) == 79224201403219477170569942574


def test_tickmath_monotonic_and_close_to_ideal():
    prev = 0
    for t in range(-1000, 1001, 7):
        s = sqrt_price_at_tick(t)
        assert s > prev
        prev = s


def test_usable_ticks():
    assert min_usable_tick(60) == -887220
    assert max_usable_tick(60) == 887220


# ---------------------------------------------------------------- Holdings (section 1)
def test_in_range_symmetric_at_price_one():
    # Range [-60, 60] around price 1. Ideal: amount0 = L(1 - 1/b), amount1 = L(1 - a).
    pos = Position(-60, 60, L)
    s = Q96
    a0, a1 = position_holdings(pos, s, False)
    i0, i1 = ideal_position_holdings(pos, s)
    assert a0 <= i0 < a0 + 1 and a1 <= i1 < a1 + 1
    # roughly 0.3% of L on each side (sqrt(1.0001^60) - 1 ~ 0.0030)
    assert 2_990 * 10**12 < a0 < 3_000 * 10**12
    assert 2_990 * 10**12 < a1 < 3_000 * 10**12


def test_below_range_is_all_token0():
    pos = Position(600, 1200, L)
    a0, a1 = position_holdings(pos, Q96, False)
    assert a1 == 0
    a = sqrt_price_at_tick(600)
    b = sqrt_price_at_tick(1200)
    assert a0 == ((L << 96) * (b - a) // b) // a  # literal formula from the skill


def test_above_range_is_all_token1():
    pos = Position(-1200, -600, L)
    a0, a1 = position_holdings(pos, Q96, False)
    assert a0 == 0
    a = sqrt_price_at_tick(-1200)
    b = sqrt_price_at_tick(-600)
    assert a1 == L * (b - a) // Q96


def test_boundaries_exact():
    pos = Position(-60, 60, L)
    a = sqrt_price_at_tick(-60)
    b = sqrt_price_at_tick(60)
    # At S == A the position is entirely token0; at S == B entirely token1.
    h_at_a = position_holdings(pos, a, False)
    h_at_b = position_holdings(pos, b, False)
    assert h_at_a[1] == 0 and h_at_a[0] > 0
    assert h_at_b[0] == 0 and h_at_b[1] > 0
    # Continuity: just inside A gives (almost) the same as at A.
    h_in = position_holdings(pos, a + 1, False)
    assert abs(h_in[0] - h_at_a[0]) <= 1 and h_in[1] <= 1


def test_full_range_at_price_one():
    pos = Position(min_usable_tick(60), max_usable_tick(60), L)
    a0, a1 = position_holdings(pos, Q96, False)
    # Full range at price 1 holds ~L of each token.
    assert L - 10**13 < a0 <= L and L - 10**13 < a1 <= L


def test_zero_liquidity():
    assert position_holdings(Position(-60, 60, 0), Q96, True) == (0, 0)


def test_idle_added():
    assert holdings(Position(-60, 60, 0), 5, 7, Q96, False) == (5, 7)


@pytest.mark.parametrize("seed", range(5))
def test_rounding_direction_vs_ideal(seed):
    rng = random.Random(seed)
    for _ in range(200):
        tl = rng.randrange(-50_000, 50_000) // 10 * 10
        tu = tl + rng.randrange(1, 2000) * 10
        pos = Position(tl, tu, rng.randrange(1, 10**30))
        s = sqrt_price_at_tick(rng.randrange(tl - 3000, tu + 3000))
        lo = position_holdings(pos, s, False)
        hi = position_holdings(pos, s, True)
        ideal = ideal_position_holdings(pos, s)
        for k in range(2):
            assert lo[k] <= ideal[k] <= hi[k]
            assert hi[k] - lo[k] <= 1


# ---------------------------------------------------------------- NAV (section 2)
def test_nav_hand_example():
    # price = (2Q96/Q96)^2 = 4 token1 per token0 -> 10*4 + 5 = 45
    assert nav((10, 5), 2 * Q96, False) == 45
    assert nav((10, 5), 2 * Q96, True) == 45


def test_nav_rounding_direction():
    s = sqrt_price_at_tick(12345)
    h = (10**20 + 7, 3)
    ideal = ideal_nav((Fraction(h[0]), Fraction(h[1])), s)
    assert nav(h, s, False) <= ideal <= nav(h, s, True)


def test_nav_no_overflow_at_extremes():
    nav(((1 << 128) - 1, (1 << 128) - 1), MAX_SQRT_PRICE - 1, True)
    nav(((1 << 128) - 1, 0), MIN_SQRT_PRICE, True)


# ---------------------------------------------------------------- Scoring (sections 3-5)
def test_leakage_doing_nothing_is_zero_up_to_rounding():
    pos = Position(-600, 600, L)
    s = Q96
    h_up = holdings(pos, 0, 0, s, True)
    h_dn = holdings(pos, 0, 0, s, False)
    leak = immediate_leakage(h_up, h_dn, s)
    assert 0 <= leak <= 3  # never negative: rounding can only hurt the curator


def test_leakage_hand_example():
    # Before: 100 token0 + 0 token1. After a bad swap: 0 token0 + 90 token1. Fair price 1 => leaked 10.
    assert immediate_leakage((100, 0), (0, 90), Q96) == 10
    # A good trade shows negative leakage (value gained).
    assert immediate_leakage((100, 0), (0, 110), Q96) == -10


def test_alpha_no_change_is_zero_up_to_rounding():
    pos = Position(-600, 600, L)
    a = markout_alpha(pos, (5, 5), pos, (5, 5), sqrt_price_at_tick(300), sqrt_price_at_tick(300))
    # Derived bound near price 1: each side carries <=1 wei holdings rounding per token (x price ~1) plus <=2 wei
    # from the nested mulDiv => <=4 per side, <=8 total. Direction matters most: never positive (curator-adverse).
    assert -8 <= a <= 0


def test_alpha_moving_out_of_the_way_of_a_dump():
    # Old: range above spot (all token0). New: same liquidity's value as token1 idle.
    # Price then falls (tick 0 -> -2000). Holding token1 beats holding token0 => positive alpha.
    old = Position(0, 600, L)
    h0 = holdings(old, 0, 0, Q96, False)
    new = Position(0, 600, 0)
    s_t = sqrt_price_at_tick(-2000)
    alpha = markout_alpha(old, (0, 0), new, (0, h0[0]), s_t, s_t)
    assert alpha > 0


def test_loss_and_gain_wad():
    assert loss_wad(-5, 100) == 0
    assert loss_wad(1, 3) == WAD // 3 + 1  # ceil
    assert gain_wad(1, 3) == WAD // 3  # floor
    assert gain_wad(-1, 3) == 0
    with pytest.raises(ZeroDivisionError):
        loss_wad(1, 0)


# ---------------------------------------------------------------- Budget (sections 6-7)
P = BudgetParams()


def test_tiers():
    assert tier_for(P.b_max0, P.b_max0, P) == FULL
    assert tier_for(P.b_max0 // 2, P.b_max0, P) == FULL  # exactly 50%
    assert tier_for(P.b_max0 // 2 - 1, P.b_max0, P) == RESTRICTED
    assert tier_for(P.b_max0 // 5, P.b_max0, P) == RESTRICTED  # exactly 20%
    assert tier_for(P.b_max0 // 5 - 1, P.b_max0, P) == FROZEN
    assert tier_for(0, P.b_max0, P) == FROZEN


def test_charge_floors_at_zero_and_freezes():
    s = init_state(P, 100)
    s = charge(s, P, 10 * WAD, 0)
    assert s.budget == 0 and s.tier == FROZEN


def test_full_restricted_frozen_sequence():
    s = init_state(P, 0)
    s = charge(s, P, P.b_max0 * 6 // 10, 0)  # 40% left
    assert s.tier == RESTRICTED
    s = charge(s, P, P.b_max0 * 25 // 100, 0)  # 15% left
    assert s.tier == FROZEN


def test_refill_caps_at_bmax_and_restores_restricted_to_full():
    s = init_state(P, 0)
    s = charge(s, P, P.b_max0 * 6 // 10, 0)
    assert s.tier == RESTRICTED
    s = refill(s, P, 10**6)
    assert s.budget == s.b_max and s.tier == FULL


def test_refill_floor_rate():
    s = init_state(P, 0)
    s = charge(s, P, P.b_max0, 0)  # empty -> frozen
    s2 = restore(s, P, 0)
    s3 = refill(s2, P, 10)
    assert s3.budget == s2.budget + 10 * P.refill_rate


def test_frozen_is_sticky_under_refill():
    s = init_state(P, 0)
    s = charge(s, P, P.b_max0, 0)
    s = refill(s, P, 10**9)
    assert s.tier == FROZEN and s.budget == 0


def test_frozen_not_lifted_by_credit():
    s = charge(init_state(P, 0), P, P.b_max0, 0)
    s = credit(s, P, 10**16, 10**18)
    assert s.tier == FROZEN and s.budget == 0 and s.b_max > P.b_max0


def test_restore_lands_restricted():
    s = charge(init_state(P, 0), P, P.b_max0, 0)
    s = restore(s, P, 5)
    assert s.tier == RESTRICTED
    assert s.budget == P.b_max0 * 35 // 100
    assert s.last_block == 5


def test_credit_scales_budget_proportionally():
    s = init_state(P, 0)
    s = charge(s, P, 10**15, 0)
    s2 = credit(s, P, 10**16, 1000 * 10**18)
    assert s2.b_max == P.b_max0 + 10**16 * P.k // WAD
    assert s2.budget == s.budget * s2.b_max // s.b_max
    # ratio preserved within 1 wei, rounded down (never up)
    r0 = Fraction(s.budget, s.b_max)
    r1 = Fraction(s2.budget, s2.b_max)
    assert r1 <= r0 and (r0 - r1) * s2.b_max < 1
    assert s2.tier == s.tier
    assert deposit_cap(s2, P) == P.cap0 + P.m * 1000


def test_credit_never_changes_tier_at_threshold():
    # budget exactly at the FULL threshold: a floor in the scaling must not demote it
    s = BudgetState(budget=P.b_max0 // 2, b_max=P.b_max0, last_block=0, tier=FULL)
    for gw in (1, 3, 7, 10**15 + 1):
        s2 = credit(s, P, gw, 1)
        assert s2.tier == FULL


def test_k_above_one_rejected():
    validate(P)
    validate(replace(P, k=WAD))
    with pytest.raises(ValueError):
        validate(replace(P, k=WAD + 1))


def test_pump_never_profitable():
    """Attacker pays the vault X (manufactured alpha X), then bleeds the vault until FROZEN.
    Extra extractable loss must not exceed X."""
    nav = 10**24
    for frac in (10**15, 5 * 10**15, 3 * 10**16):
        base = _extract_until_frozen(init_state(P, 0), nav)
        x_value = frac * nav // WAD
        pumped = credit(init_state(P, 0), P, frac, x_value)
        extra = _extract_until_frozen(pumped, nav) - base
        assert extra <= x_value


def _extract_until_frozen(s, nav):
    step = 10**14
    total = 0
    while s.tier != FROZEN:
        s = charge(s, P, step, step * nav // WAD)
        total += step * nav // WAD
    return total


def test_reputation_capped():
    assert b_max_for(10**30, P) == P.b_max_cap
    s = credit(init_state(P, 0), P, 0, 10**40)
    assert deposit_cap(s, P) == P.cap_max


def test_losses_decay_reputation():
    s = credit(init_state(P, 0), P, 2 * 10**16, 100)
    s = charge(s, P, 5 * 10**15, 40)
    assert s.cum_alpha_wad == 15 * 10**15 and s.cum_alpha_value == 60
    assert s.budget <= s.b_max


@pytest.mark.parametrize("seed", range(5))
def test_random_walk_invariants(seed):
    rng = random.Random(seed)
    s = init_state(P, 0)
    blk = 0
    for _ in range(500):
        blk += rng.randrange(0, 50)
        s = refill(s, P, blk)
        op = rng.random()
        if op < 0.5:
            was_frozen = s.tier == FROZEN
            s = charge(s, P, rng.randrange(0, 10**16), rng.randrange(0, 10**18))
            assert not was_frozen or s.tier == FROZEN
        elif op < 0.9:
            tier_before = s.tier
            s = credit(s, P, rng.randrange(0, 10**15), rng.randrange(0, 10**18))
            assert s.tier == tier_before  # success never changes the tier
        elif s.tier == FROZEN:
            s = restore(s, P, blk)
        assert 0 <= s.budget <= s.b_max <= P.b_max_cap
        assert s.b_max >= P.b_max0


# ------------------------------------------------------------------------------------------- M3.3 fees in alpha
def test_fee_growth_delta_wraps():
    assert fee_growth_delta(5, 3) == 2
    assert fee_growth_delta(1, U256 - 1) == 2  # accumulator wrapped past 2^256


def test_fee_amounts_rounding():
    d = Q128 // 3  # one third of a token per unit liquidity
    assert fee_amounts(d, 0, 3, False)[0] == 0  # floor(3 * (Q128//3) / Q128) = 0
    assert fee_amounts(d, 0, 3, True)[0] == 1
    assert fee_amounts(Q128 * 7, Q128, 10, False) == (70, 10)


def test_estimate_fees_exact_and_fallbacks():
    di, dg = (Q128 * 2, Q128), (Q128 * 5, Q128 * 5)
    assert estimate_fees(di, dg, 10, True, False) == (20, 10)
    assert estimate_fees(di, dg, 10, True, True) == (20, 10)
    # untrustworthy inside growth: new gets nothing, counterfactual gets the global upper bound
    assert estimate_fees(di, dg, 10, False, False) == (0, 0)
    assert estimate_fees(di, dg, 10, False, True) == (50, 50)
    # inside > global is impossible for a continuously initialized range => treated as untrustworthy
    bad = (Q128 * 6, Q128)
    assert estimate_fees(bad, dg, 10, True, False) == (0, 0)
    assert estimate_fees(bad, dg, 10, True, True) == (50, 50)
    assert estimate_fees(di, dg, 0, False, True) == (0, 0)


def test_alpha_fees_noop_is_zero_and_fees_count():
    pos = Position(-600, 600, 10**24)
    idle = (10**20, 10**20)
    assert markout_alpha_fees(pos, idle, (5, 5), pos, idle, (0, 0), Q96, Q96) == 0
    # entering a range from idle: without fees the IL makes alpha negative; enough fees flip it
    empty = Position(-600, 600, 0)
    s_t = sqrt_price_at_tick(300)
    base = markout_alpha_fees(empty, (10**22, 10**22), (0, 0), pos, (0, 0), (0, 0), s_t, s_t)
    fees = (10**21, 10**21)
    with_fees = markout_alpha_fees(empty, (10**22, 10**22), (0, 0), pos, (0, 0), fees, s_t, s_t)
    assert with_fees > base
    # adding fees f to the new side raises alpha by NAV(f) up to rounding
    assert with_fees - base >= nav(fees, s_t, False) - 2

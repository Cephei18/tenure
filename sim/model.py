"""Tenure reference model.

Two layers (see .claude/skills/tenure-math/SKILL.md):
  * Integer layer: mirrors the Solidity code EXACTLY (floor division, explicit ceil, nested mulDiv, the same rounding
    flags as v4-core SqrtPriceMath). Test vectors are produced from this layer and Solidity must match bit-for-bit.
  * Ideal layer (`ideal_*`): exact rational arithmetic with fractions.Fraction. Used only to check that the integer
    layer is within a few wei of the truth AND errs in the curator-adverse direction.

No floats anywhere in this file.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
from fractions import Fraction

Q96 = 1 << 96
Q128 = 1 << 128
U256 = 1 << 256
WAD = 10**18
UINT256_MAX = (1 << 256) - 1

MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_PRICE = 4295128739
MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342

FULL, RESTRICTED, FROZEN = 0, 1, 2
TIER_NAMES = {FULL: "FULL", RESTRICTED: "RESTRICTED", FROZEN: "FROZEN"}


# --------------------------------------------------------------------------------------------------------------------
# Fixed-point primitives (mirror FullMath / UnsafeMath)
# --------------------------------------------------------------------------------------------------------------------
def mul_div(a: int, b: int, d: int) -> int:
    """FullMath.mulDiv: floor(a*b/d); reverts (raises) if d == 0 or the result overflows uint256."""
    if d == 0:
        raise ZeroDivisionError("mulDiv by zero")
    r = (a * b) // d
    if r > UINT256_MAX:
        raise OverflowError("mulDiv overflow")
    return r


def mul_div_up(a: int, b: int, d: int) -> int:
    """FullMath.mulDivRoundingUp: ceil(a*b/d)."""
    r = mul_div(a, b, d)
    if (a * b) % d:
        r += 1
        if r > UINT256_MAX:
            raise OverflowError("mulDivUp overflow")
    return r


def div_up(a: int, b: int) -> int:
    """UnsafeMath.divRoundingUp."""
    return a // b + (1 if a % b else 0)


# --------------------------------------------------------------------------------------------------------------------
# TickMath.getSqrtPriceAtTick (exact port)
# --------------------------------------------------------------------------------------------------------------------
_TICK_CONSTS = [
    (0x2, 0xFFF97272373D413259A46990580E213A),
    (0x4, 0xFFF2E50F5F656932EF12357CF3C7FDCC),
    (0x8, 0xFFE5CACA7E10E4E61C3624EAA0941CD0),
    (0x10, 0xFFCB9843D60F6159C9DB58835C926644),
    (0x20, 0xFF973B41FA98C081472E6896DFB254C0),
    (0x40, 0xFF2EA16466C96A3843EC78B326B52861),
    (0x80, 0xFE5DEE046A99A2A811C461F1969C3053),
    (0x100, 0xFCBE86C7900A88AEDCFFC83B479AA3A4),
    (0x200, 0xF987A7253AC413176F2B074CF7815E54),
    (0x400, 0xF3392B0822B70005940C7A398E4B70F3),
    (0x800, 0xE7159475A2C29B7443B29C7FA6E889D9),
    (0x1000, 0xD097F3BDFD2022B8845AD8F792AA5825),
    (0x2000, 0xA9F746462D870FDF8A65DC1F90E061E5),
    (0x4000, 0x70D869A156D2A1B890BB3DF62BAF32F7),
    (0x8000, 0x31BE135F97D08FD981231505542FCFA6),
    (0x10000, 0x9AA508B5B7A84E1C677DE54F3E99BC9),
    (0x20000, 0x5D6AF8DEDB81196699C329225EE604),
    (0x40000, 0x2216E584F5FA1EA926041BEDFE98),
    (0x80000, 0x48A170391F7DC42444E8FA2),
]


def sqrt_price_at_tick(tick: int) -> int:
    abs_tick = abs(tick)
    if abs_tick > MAX_TICK:
        raise ValueError("InvalidTick")
    price = 0xFFFCB933BD6FAD37AA2D162D1A594001 if abs_tick & 0x1 else 1 << 128
    for bit, c in _TICK_CONSTS:
        if abs_tick & bit:
            price = (price * c) >> 128
    if tick > 0:
        price = UINT256_MAX // price
    return (price + (1 << 32) - 1) >> 32


def min_usable_tick(spacing: int) -> int:
    # Solidity int division truncates toward zero.
    return -((-MIN_TICK) // spacing) * spacing


def max_usable_tick(spacing: int) -> int:
    return (MAX_TICK // spacing) * spacing


# --------------------------------------------------------------------------------------------------------------------
# SqrtPriceMath amount deltas (exact port)
# --------------------------------------------------------------------------------------------------------------------
def amount0_delta(sa: int, sb: int, liq: int, round_up: bool) -> int:
    if sa > sb:
        sa, sb = sb, sa
    if sa == 0:
        raise ValueError("InvalidPrice")
    n1 = liq << 96
    n2 = sb - sa
    if round_up:
        return div_up(mul_div_up(n1, n2, sb), sa)
    return mul_div(n1, n2, sb) // sa


def amount1_delta(sa: int, sb: int, liq: int, round_up: bool) -> int:
    n = abs(sa - sb)
    return mul_div_up(liq, n, Q96) if round_up else mul_div(liq, n, Q96)


# --------------------------------------------------------------------------------------------------------------------
# Section 1: holdings of a position at sqrt price S
# --------------------------------------------------------------------------------------------------------------------
@dataclass(frozen=True)
class Position:
    tick_lower: int
    tick_upper: int
    liquidity: int


def position_holdings(pos: Position, s: int, round_up: bool) -> tuple[int, int]:
    """Token amounts of `pos` if the pool sat at sqrt price `s`.

    Path independent (fees ignored), which is what makes the counterfactual exact.
    """
    if pos.liquidity == 0:
        return (0, 0)
    a = sqrt_price_at_tick(pos.tick_lower)
    b = sqrt_price_at_tick(pos.tick_upper)
    if s <= a:
        return (amount0_delta(a, b, pos.liquidity, round_up), 0)
    if s >= b:
        return (0, amount1_delta(a, b, pos.liquidity, round_up))
    return (amount0_delta(s, b, pos.liquidity, round_up), amount1_delta(a, s, pos.liquidity, round_up))


def holdings(pos: Position, idle0: int, idle1: int, s: int, round_up: bool) -> tuple[int, int]:
    """Vault holdings H = position amounts + idle balances."""
    p0, p1 = position_holdings(pos, s, round_up)
    return (p0 + idle0, p1 + idle1)


# --------------------------------------------------------------------------------------------------------------------
# Section 2: NAV at FAIR price, in token1 units
# --------------------------------------------------------------------------------------------------------------------
def nav(h: tuple[int, int], s_fair: int, round_up: bool) -> int:
    """amount0 * (S*/Q96)^2 + amount1, via nested mulDiv to stay inside 256 bits."""
    a0, a1 = h
    if round_up:
        return mul_div_up(mul_div_up(a0, s_fair, Q96), s_fair, Q96) + a1
    return mul_div(mul_div(a0, s_fair, Q96), s_fair, Q96) + a1


# --------------------------------------------------------------------------------------------------------------------
# Sections 3-5: decision scoring
# --------------------------------------------------------------------------------------------------------------------
def immediate_leakage(h_before_up: tuple[int, int], h_after_down: tuple[int, int], s_fair: int) -> int:
    """L_imm = NAV(H_before) - NAV(H_after) at the same fair price. Signed; positive = value lost.

    Rounding against the curator: before rounded up, after rounded down => leakage biased up.
    """
    return nav(h_before_up, s_fair, True) - nav(h_after_down, s_fair, False)


def score_leakage(
    old: Position,
    idle_old: tuple[int, int],
    s_before: int,
    new: Position,
    idle_new: tuple[int, int],
    s_after: int,
    s_fair: int,
) -> tuple[int, int]:
    """(L_imm, NAV_before) from raw state snapshots. Exact no-op (nothing changed) scores exactly 0."""
    h_before = holdings(old, idle_old[0], idle_old[1], s_before, True)
    nav_before = nav(h_before, s_fair, True)
    if old == new and idle_old == idle_new and s_before == s_after:
        return (0, nav_before)
    h_after = holdings(new, idle_new[0], idle_new[1], s_after, False)
    return (nav_before - nav(h_after, s_fair, False), nav_before)


def markout_alpha(
    old: Position, idle_old: tuple[int, int], new: Position, idle_new: tuple[int, int], s_t: int, s_fair_t: int
) -> int:
    """alpha = NAV(H_new at S_T) - NAV(H_counterfactual at S_T), both at fair price S*_T. Biased down.

    Exact no-op (same range, same idle) is a non-decision and scores exactly 0 (no rounding dust).
    """
    if old == new and idle_old == idle_new:
        return 0
    h_new = holdings(new, idle_new[0], idle_new[1], s_t, False)
    h_cf = holdings(old, idle_old[0], idle_old[1], s_t, True)
    return nav(h_new, s_fair_t, False) - nav(h_cf, s_fair_t, True)


# --------------------------------------------------------------------------------------------------------------------
# Section 4b (M3.3): LP fees in the markout
# --------------------------------------------------------------------------------------------------------------------
def fee_growth_delta(now: int, then: int) -> int:
    """v4 fee growth accumulators are uint256 that wrap by design; deltas are taken mod 2^256 (Solidity unchecked)."""
    return (now - then) % U256


def fee_amounts(d0: int, d1: int, liq: int, round_up: bool) -> tuple[int, int]:
    """Fees earned by `liq` over a fee-growth delta (X128 per unit liquidity). v4 itself floors."""
    f = mul_div_up if round_up else mul_div
    return (f(d0, liq, Q128), f(d1, liq, Q128))


def estimate_fees(
    d_inside: tuple[int, int], d_global: tuple[int, int], liq: int, inside_valid: bool, counterfactual: bool
) -> tuple[int, int]:
    """Fees a hypothetical position (range, liq) earned between the record and settlement.

    Exact when the range's fee-growth-inside is trustworthy (`inside_valid`: both ticks initialized at settlement,
    and the inside delta does not exceed the global delta for either token). Otherwise curator-adverse fallback:
    the NEW position is credited 0 fees, the COUNTERFACTUAL is credited liq * global delta (as if it had been in
    range the whole time, an upper bound). New fees round down, counterfactual fees round up.
    """
    if liq == 0:
        return (0, 0)
    ok = inside_valid and d_inside[0] <= d_global[0] and d_inside[1] <= d_global[1]
    if counterfactual:
        return fee_amounts(*(d_inside if ok else d_global), liq, True)
    return fee_amounts(*d_inside, liq, False) if ok else (0, 0)


def markout_alpha_fees(
    old: Position,
    idle_old: tuple[int, int],
    fees_cf: tuple[int, int],
    new: Position,
    idle_new: tuple[int, int],
    fees_new: tuple[int, int],
    s_t: int,
    s_fair_t: int,
) -> int:
    """Markout alpha with LP fees: fees are added to each side's idle holdings. A no-op decision still scores 0."""
    if old == new and idle_old == idle_new:
        return 0
    return markout_alpha(
        old,
        (idle_old[0] + fees_cf[0], idle_old[1] + fees_cf[1]),
        new,
        (idle_new[0] + fees_new[0], idle_new[1] + fees_new[1]),
        s_t,
        s_fair_t,
    )


def loss_wad(loss_value: int, nav_ref: int) -> int:
    """max(0, loss) as a WAD fraction of nav_ref, rounded UP."""
    if nav_ref == 0:
        raise ZeroDivisionError("nav_ref == 0")
    if loss_value <= 0:
        return 0
    return mul_div_up(loss_value, WAD, nav_ref)


def gain_wad(gain_value: int, nav_ref: int) -> int:
    """max(0, gain) as a WAD fraction of nav_ref, rounded DOWN (reputation is never over-credited)."""
    if nav_ref == 0:
        raise ZeroDivisionError("nav_ref == 0")
    if gain_value <= 0:
        return 0
    return mul_div(gain_value, WAD, nav_ref)


# --------------------------------------------------------------------------------------------------------------------
# Sections 6-7: risk budget (leaky bucket), tiers, reputation
# --------------------------------------------------------------------------------------------------------------------
@dataclass(frozen=True)
class BudgetParams:
    b_max0: int = 2 * 10**16  # 2% of NAV
    b_max_cap: int = 10 * 10**16  # 10% of NAV
    refill_rate: int = 2 * 10**16 // 7200  # empty -> full in ~1 day of 12s blocks
    full_threshold: int = 5 * 10**17
    restricted_threshold: int = 2 * 10**17
    restore_wad: int = 35 * 10**16  # restore() lands at 35% of bMax => RESTRICTED
    k: int = 5 * 10**17  # bMax grows by k * cumulative positive alpha fraction
    cap0: int = 100_000 * 10**18  # deposit cap in token1 units
    cap_max: int = 10_000_000 * 10**18
    m: int = 50 * 10**18  # cap grows by m * cumulative positive alpha value


@dataclass(frozen=True)
class BudgetState:
    budget: int
    b_max: int
    last_block: int
    tier: int
    cum_alpha_wad: int = 0
    cum_alpha_value: int = 0


def validate(p: BudgetParams) -> None:
    """Mirror of RiskBudget.validate's reputation check. k <= 1 (WAD) is the pump bound: a unit of alpha an
    attacker manufactures by paying the vault can buy at most one unit of extra allowed loss."""
    if p.k > WAD:
        raise ValueError("Tenure__ReputationGainTooHigh")


def init_state(p: BudgetParams, block: int) -> BudgetState:
    return BudgetState(budget=p.b_max0, b_max=p.b_max0, last_block=block, tier=FULL)


def tier_for(budget: int, b_max: int, p: BudgetParams) -> int:
    ratio = budget * WAD // b_max  # floor
    if ratio >= p.full_threshold:
        return FULL
    if ratio >= p.restricted_threshold:
        return RESTRICTED
    return FROZEN


def b_max_for(cum_alpha_wad: int, p: BudgetParams) -> int:
    return min(p.b_max_cap, p.b_max0 + mul_div(p.k, cum_alpha_wad, WAD))


def deposit_cap(s: BudgetState, p: BudgetParams) -> int:
    return min(p.cap_max, p.cap0 + mul_div(p.m, s.cum_alpha_value, WAD))


def refill(s: BudgetState, p: BudgetParams, block: int) -> BudgetState:
    """Time-based refill, floor. FROZEN is sticky: no refill while frozen."""
    if block <= s.last_block:
        return s
    if s.tier == FROZEN:
        return replace(s, last_block=block)
    budget = min(s.b_max, s.budget + p.refill_rate * (block - s.last_block))
    return replace(s, budget=budget, last_block=block, tier=tier_for(budget, s.b_max, p))


def _sat_sub(a: int, b: int) -> int:
    return a - b if a > b else 0


def charge(s: BudgetState, p: BudgetParams, loss_w: int, loss_value: int) -> BudgetState:
    """Charge a loss: decay reputation first (losses offset past alpha), then drain the budget (floor at 0)."""
    cum_w = _sat_sub(s.cum_alpha_wad, loss_w)
    cum_v = _sat_sub(s.cum_alpha_value, loss_value)
    b_max = b_max_for(cum_w, p)
    budget = _sat_sub(min(s.budget, b_max), loss_w)
    tier = FROZEN if s.tier == FROZEN else tier_for(budget, b_max, p)
    return replace(s, budget=budget, b_max=b_max, tier=tier, cum_alpha_wad=cum_w, cum_alpha_value=cum_v)


def credit(s: BudgetState, p: BudgetParams, gain_w: int, gain_value: int) -> BudgetState:
    """Positive alpha grows reputation (bMax, deposit cap). It never refills spent budget: the budget is scaled
    proportionally, budget' = floor(budget * bMax' / bMax), so budget/bMax is unchanged (within 1 wei, rounded
    down). Success never changes the tier (the tier is kept as-is, so a 1-wei floor cannot demote it either);
    only time refill or guardian restore does. While FROZEN only reputation changes, not the budget."""
    cum_w = s.cum_alpha_wad + gain_w
    cum_v = s.cum_alpha_value + gain_value
    b_max = b_max_for(cum_w, p)
    if s.tier == FROZEN:
        return replace(s, b_max=b_max, cum_alpha_wad=cum_w, cum_alpha_value=cum_v)
    budget = mul_div(s.budget, b_max, s.b_max)  # floor: curator-adverse
    return replace(s, budget=budget, b_max=b_max, cum_alpha_wad=cum_w, cum_alpha_value=cum_v)


def restore(s: BudgetState, p: BudgetParams, block: int) -> BudgetState:
    """Guardian restore from FROZEN: autonomy is re-earned, so land in RESTRICTED, not FULL."""
    budget = mul_div(s.b_max, p.restore_wad, WAD)
    return replace(s, budget=budget, last_block=block, tier=tier_for(budget, s.b_max, p))


# --------------------------------------------------------------------------------------------------------------------
# Ideal (rational) layer — for error-direction checks only
# --------------------------------------------------------------------------------------------------------------------
def ideal_position_holdings(pos: Position, s: int) -> tuple[Fraction, Fraction]:
    a = Fraction(sqrt_price_at_tick(pos.tick_lower), Q96)
    b = Fraction(sqrt_price_at_tick(pos.tick_upper), Q96)
    x = Fraction(s, Q96)
    L = pos.liquidity
    if L == 0:
        return (Fraction(0), Fraction(0))
    if x <= a:
        return (L * (b - a) / (a * b), Fraction(0))
    if x >= b:
        return (Fraction(0), L * (b - a))
    return (L * (b - x) / (x * b), L * (x - a))


def ideal_nav(h: tuple[Fraction, Fraction], s_fair: int) -> Fraction:
    p = Fraction(s_fair, Q96) ** 2
    return h[0] * p + h[1]


# --------------------------------------------------------------------------------------------------------------------
# M4.6 Chainlink reference price: USD (or direct) feeds -> fair sqrtPriceX96 (mirrors ChainlinkPriceLib.sol)
# --------------------------------------------------------------------------------------------------------------------
TWO_64 = 1 << 64


def _isqrt(x: int) -> int:
    """floor(sqrt(x)) for x >= 0 (OpenZeppelin Math.sqrt, default rounding = floor)."""
    from math import isqrt

    return isqrt(x)


def chainlink_sqrt_price_x96(a0: int, fd0: int, a1: int, fd1: int, dec0: int, dec1: int) -> int:
    """Fair sqrt price (token1 per token0, raw units, Q64.96) from two Chainlink answers.

    a0 = price of token0 in a common quote (fd0 feed decimals), a1 = same for token1. A DIRECT feed (token0 quoted
    in token1) is the special case a1 = 1, fd1 = 0. dec0/dec1 are the ERC-20 decimals. Raw price:
        P = (a0 / 10^fd0) / (a1 / 10^fd1) * 10^dec1 / 10^dec0 = num / den,  e = fd1 + dec1 - fd0 - dec0
    sqrtPriceX96 = floor(sqrt(P * 2^192)) when P < 2^64 (exact to 1 unit); otherwise
                   floor(sqrt(P * 2^128)) << 32 (relative error < 2^-96), so the mulDiv never overflows.
    Raises on non-positive answers, uint256 overflow, or a result outside [MIN_SQRT_PRICE, MAX_SQRT_PRICE).
    """
    if a0 <= 0 or a1 <= 0:
        raise ValueError("non-positive answer")
    e = fd1 + dec1 - fd0 - dec0
    num, den = (a0 * 10**e, a1) if e >= 0 else (a0, a1 * 10 ** (-e))
    if num > UINT256_MAX or den > UINT256_MAX:
        raise OverflowError("scale overflow")
    if num // den < TWO_64:
        s = _isqrt(mul_div(num, 1 << 192, den))
    else:
        s = _isqrt(mul_div(num, 1 << 128, den)) << 32
    if s < MIN_SQRT_PRICE or s >= MAX_SQRT_PRICE:
        raise ValueError("price out of range")
    return s


def ideal_chainlink_price(a0: int, fd0: int, a1: int, fd1: int, dec0: int, dec1: int) -> Fraction:
    """Exact raw price P (token1 per token0) for the ideal layer."""
    return Fraction(a0, 10**fd0) / Fraction(a1, 10**fd1) * Fraction(10**dec1, 10**dec0)

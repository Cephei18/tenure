"""Generate deterministic differential-test vectors from the integer layer of sim/model.py.

Run from the repo root:   python sim/gen_vectors.py
Writes test/vectors/{holdings,nav,leakage,alpha,loss,budget,fees}.json. Every number is a decimal STRING so uint256 / int256
values survive JSON; forge's vm.parseJsonUint / parseJsonInt accept numeric strings.
"""

from __future__ import annotations

import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from model import (  # noqa: E402
    FROZEN,
    MAX_TICK,
    MIN_TICK,
    BudgetParams,
    Position,
    charge,
    credit,
    deposit_cap,
    estimate_fees,
    markout_alpha_fees,
    Q128,
    U256,
    gain_wad,
    holdings,
    init_state,
    loss_wad,
    markout_alpha,
    max_usable_tick,
    min_usable_tick,
    nav,
    refill,
    restore,
    score_leakage,
    sqrt_price_at_tick,
)

SEED = 0x7E2A
N = 240  # >= 200 per function
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "test", "vectors")
SPACINGS = [1, 10, 60, 200]


def s(x: int) -> str:
    return str(int(x))


def rand_range(rng: random.Random, near: int | None = None) -> tuple[int, int]:
    """A tick range on a random spacing; realistic widths, sometimes 1 spacing, sometimes full range."""
    sp = rng.choice(SPACINGS)
    lo_ok, hi_ok = min_usable_tick(sp), max_usable_tick(sp)
    r = rng.random()
    if r < 0.08:
        return lo_ok, hi_ok
    center = near if near is not None else rng.randrange(-200_000, 200_000)
    if r < 0.2:
        width = 1
    else:
        width = rng.choice([rng.randrange(1, 20), rng.randrange(20, 400), rng.randrange(400, 4000)])
    tl = max(lo_ok, min(hi_ok - sp, (center // sp - width // 2) * sp))
    tu = min(hi_ok, tl + width * sp)
    return tl, tu


def rand_liq(rng: random.Random, huge_ok: bool) -> int:
    r = rng.random()
    if r < 0.05:
        return rng.randrange(1, 1000)  # tiny
    if r < 0.1 and huge_ok:
        return rng.randrange(1 << 120, 1 << 128)  # huge
    return rng.randrange(10**12, 10**26)


def rand_spot_for(rng: random.Random, tl: int, tu: int) -> int:
    a, b = sqrt_price_at_tick(tl), sqrt_price_at_tick(tu)
    r = rng.random()
    if r < 0.1:
        return a  # exactly at lower boundary
    if r < 0.2:
        return b  # exactly at upper boundary
    if r < 0.35:  # below range
        t = max(MIN_TICK, tl - rng.randrange(1, 5000))
        return sqrt_price_at_tick(t)
    if r < 0.5:  # above range
        t = min(MAX_TICK - 1, tu + rng.randrange(1, 5000))
        return sqrt_price_at_tick(t)
    return rng.randrange(a, b + 1)  # inside (raw sqrt price, not tick-aligned)


def pos_json(p: Position) -> dict:
    return {"tickLower": s(p.tick_lower), "tickUpper": s(p.tick_upper), "liquidity": s(p.liquidity)}


def gen_holdings(rng):
    cases = []
    extremes = [
        (MIN_TICK, MIN_TICK + 1),
        (MAX_TICK - 1, MAX_TICK),
        (min_usable_tick(1), max_usable_tick(1)),
    ]
    for i in range(N):
        if i < len(extremes) * 4:
            tl, tu = extremes[i % len(extremes)]
        else:
            tl, tu = rand_range(rng)
        pos = Position(tl, tu, rand_liq(rng, huge_ok=True))
        spot = rand_spot_for(rng, tl, tu)
        idle0 = 0 if rng.random() < 0.4 else rng.randrange(0, 10**24)
        idle1 = 0 if rng.random() < 0.4 else rng.randrange(0, 10**24)
        round_up = rng.random() < 0.5
        a0, a1 = holdings(pos, idle0, idle1, spot, round_up)
        cases.append(
            {**pos_json(pos), "sqrtPrice": s(spot), "sqrtLower": s(sqrt_price_at_tick(tl)),
             "sqrtUpper": s(sqrt_price_at_tick(tu)), "idle0": s(idle0), "idle1": s(idle1),
             "roundUp": round_up, "amount0": s(a0), "amount1": s(a1)}
        )
    return cases


def gen_nav(rng):
    cases = []
    for i in range(N):
        fair_tick = rng.choice([MIN_TICK, MAX_TICK - 1, 0]) if i < 9 else rng.randrange(-400_000, 400_000)
        fair = sqrt_price_at_tick(fair_tick) + (0 if rng.random() < 0.5 else rng.randrange(0, 1000))
        a0 = rng.choice([0, 1, rng.randrange(0, 10**18), rng.randrange(0, 1 << 128)])
        a1 = rng.choice([0, 1, rng.randrange(0, 10**18), rng.randrange(0, 1 << 128)])
        round_up = rng.random() < 0.5
        cases.append({"amount0": s(a0), "amount1": s(a1), "sqrtFair": s(fair), "roundUp": round_up,
                      "nav": s(nav((a0, a1), fair, round_up))})
    return cases


def gen_leakage(rng):
    cases = []
    for i in range(N):
        t = rng.randrange(-200_000, 200_000)
        spot = sqrt_price_at_tick(t) + rng.randrange(0, 10**6)
        # spot after the session: usually unchanged, sometimes moved (vault swapped / was sandwiched)
        spot_after = spot if rng.random() < 0.6 else sqrt_price_at_tick(t + rng.randrange(-300, 300))
        # fair is within +-5% (+-~500 ticks) of spot, or equal
        fair = spot if rng.random() < 0.2 else sqrt_price_at_tick(t + rng.randrange(-500, 500))
        old = Position(*rand_range(rng, near=t), rand_liq(rng, huge_ok=False))
        new = Position(*rand_range(rng, near=t + rng.randrange(-1000, 1000)), rand_liq(rng, huge_ok=False))
        io = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        inew = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        if i < 8:  # exact no-ops must score 0
            new, inew, spot_after = old, io, spot
        leak, nav_before = score_leakage(old, io, spot, new, inew, spot_after, fair)
        cases.append({"old": pos_json(old), "new": pos_json(new), "idleOld0": s(io[0]), "idleOld1": s(io[1]),
                      "idleNew0": s(inew[0]), "idleNew1": s(inew[1]), "sqrtSpot": s(spot),
                      "sqrtSpotAfter": s(spot_after), "sqrtFair": s(fair), "navBefore": s(nav_before),
                      "leakage": s(leak)})
    return cases


def gen_alpha(rng):
    cases = []
    for i in range(N):
        t = rng.randrange(-200_000, 200_000)
        old = Position(*rand_range(rng, near=t), rand_liq(rng, huge_ok=False))
        new = Position(*rand_range(rng, near=t + rng.randrange(-1000, 1000)), rand_liq(rng, huge_ok=False))
        io = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        inew = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        if i < 8:  # exact no-ops must score 0
            new, inew = old, io
        t_end = t + rng.randrange(-3000, 3000)
        s_t = sqrt_price_at_tick(t_end) + rng.randrange(0, 10**6)
        fair_t = s_t if rng.random() < 0.3 else sqrt_price_at_tick(t_end + rng.randrange(-500, 500))
        a = markout_alpha(old, io, new, inew, s_t, fair_t)
        cases.append({"old": pos_json(old), "new": pos_json(new), "idleOld0": s(io[0]), "idleOld1": s(io[1]),
                      "idleNew0": s(inew[0]), "idleNew1": s(inew[1]), "sqrtSpotT": s(s_t), "sqrtFairT": s(fair_t),
                      "alpha": s(a)})
    return cases


def gen_loss(rng):
    cases = []
    for i in range(N):
        nav_ref = rng.choice([1, 3, rng.randrange(1, 10**18), rng.randrange(10**18, 10**30)])
        v = rng.choice([0, -1, 1, rng.randrange(-10**24, 10**24), rng.randrange(0, nav_ref + 1)])
        cases.append({"value": s(v), "navRef": s(nav_ref), "lossWad": s(loss_wad(v, nav_ref)),
                      "gainWad": s(gain_wad(v, nav_ref))})
    return cases


def gen_budget(rng):
    """Random op sequences with the default params; expected state after every op."""
    p = BudgetParams()
    seqs = []
    for _ in range(12):
        st = init_state(p, 1000)
        blk = 1000
        ops = []
        for _ in range(25):
            blk += rng.choice([0, 1, rng.randrange(1, 200), rng.randrange(200, 10_000)])
            r = rng.random()
            if r < 0.45:
                lw, lv = rng.randrange(0, 8 * 10**15), rng.randrange(0, 10**21)
                st = charge(refill(st, p, blk), p, lw, lv)
                op = {"kind": "1", "a": s(lw), "b": s(lv)}
            elif r < 0.75:
                gw, gv = rng.randrange(0, 4 * 10**15), rng.randrange(0, 10**21)
                st = credit(refill(st, p, blk), p, gw, gv)
                op = {"kind": "2", "a": s(gw), "b": s(gv)}
            elif r < 0.85 and st.tier == FROZEN:
                st = restore(st, p, blk)
                op = {"kind": "3", "a": "0", "b": "0"}
            else:
                st = refill(st, p, blk)
                op = {"kind": "0", "a": "0", "b": "0"}
            op.update({"block": s(blk), "budget": s(st.budget), "bMax": s(st.b_max), "lastBlock": s(st.last_block),
                       "tier": s(st.tier), "cumAlphaWad": s(st.cum_alpha_wad),
                       "cumAlphaValue": s(st.cum_alpha_value), "depositCap": s(deposit_cap(st, p))})
            ops.append(op)
        seqs.append({"startBlock": "1000", "ops": ops})
    return seqs


def gen_fees(rng):
    """M3.3: fee estimation (exact / fallback, wrap-around deltas) and markout alpha with fees."""
    cases = []
    for i in range(N):
        t = rng.randrange(-200_000, 200_000)
        old = Position(*rand_range(rng, near=t), rand_liq(rng, huge_ok=False) if rng.random() < 0.85 else 0)
        new = Position(*rand_range(rng, near=t + rng.randrange(-1000, 1000)), rand_liq(rng, huge_ok=False))
        io = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        inew = (rng.randrange(0, 10**22), rng.randrange(0, 10**22))
        if i < 8:
            new, inew = old, io

        def growth(liq):
            # realistic: total fees F for this liquidity => delta = F * 2^128 / L
            if liq == 0:
                return rng.randrange(0, Q128 * 10**6)
            return rng.randrange(0, 10**21) * Q128 // liq

        g0 = rng.randrange(0, U256)  # accumulator snapshot at record time (any value; wraps)
        g1 = rng.randrange(0, U256)
        dg = (growth(min(old.liquidity or 10**24, new.liquidity or 10**24)) * 3, growth(10**24) * 3)
        di_old = (rng.randrange(0, dg[0] + 1), rng.randrange(0, dg[1] + 1))
        di_new = (rng.randrange(0, dg[0] + 1), rng.randrange(0, dg[1] + 1))
        if rng.random() < 0.15:  # corrupted inside growth (tick re-initialized): inside > global
            di_new = (dg[0] + rng.randrange(1, 10**30), di_new[1])
        valid_old, valid_new = rng.random() < 0.6, rng.random() < 0.8
        f_cf = estimate_fees(di_old, dg, old.liquidity, valid_old, True)
        f_new = estimate_fees(di_new, dg, new.liquidity, valid_new, False)
        t_end = t + rng.randrange(-3000, 3000)
        s_t = sqrt_price_at_tick(t_end) + rng.randrange(0, 10**6)
        fair_t = s_t if rng.random() < 0.3 else sqrt_price_at_tick(t_end + rng.randrange(-500, 500))
        a = markout_alpha_fees(old, io, f_cf, new, inew, f_new, s_t, fair_t)
        # store the raw accumulators (then, now) so Solidity exercises the unchecked wrap-around subtraction
        cases.append({"old": pos_json(old), "new": pos_json(new), "idleOld0": s(io[0]), "idleOld1": s(io[1]),
                      "idleNew0": s(inew[0]), "idleNew1": s(inew[1]),
                      "gThen0": s(g0), "gThen1": s(g1),
                      "gNow0": s((g0 + dg[0]) % U256), "gNow1": s((g1 + dg[1]) % U256),
                      "oThen0": s(g0), "oThen1": s(g1),
                      "oNow0": s((g0 + di_old[0]) % U256), "oNow1": s((g1 + di_old[1]) % U256),
                      "nThen0": s(g1), "nThen1": s(g0),
                      "nNow0": s((g1 + di_new[0]) % U256), "nNow1": s((g0 + di_new[1]) % U256),
                      "validOld": valid_old, "validNew": valid_new,
                      "feesCf0": s(f_cf[0]), "feesCf1": s(f_cf[1]), "feesNew0": s(f_new[0]), "feesNew1": s(f_new[1]),
                      "sqrtSpotT": s(s_t), "sqrtFairT": s(fair_t), "alpha": s(a)})
    return cases


def main():
    rng = random.Random(SEED)
    os.makedirs(OUT, exist_ok=True)
    gens = [("holdings", gen_holdings), ("nav", gen_nav), ("leakage", gen_leakage), ("alpha", gen_alpha),
            ("loss", gen_loss), ("budget", gen_budget), ("fees", gen_fees)]
    for name, fn in gens:
        cases = fn(rng)
        with open(os.path.join(OUT, f"{name}.json"), "w", newline="\n") as f:
            json.dump({"seed": SEED, "count": len(cases), "cases": cases}, f, indent=1)
        print(f"{name}: {len(cases)} cases")


if __name__ == "__main__":
    main()

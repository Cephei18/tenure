"""Generate every chart and diagram of the Tenure UHI11 deck as standalone 2x PNGs in docs/slides/assets/.

    python docs/slides/src/make_assets.py

Every number is read from a committed file (paths next to each chart) or is a protocol constant documented in the
README. Colours come from docs/design-tokens.json (the Tenure Lab's generated token file), so slides and Lab match.
Each figure is laid out in *slide pixels* (the deck is 1920x1080) and saved at dpi=200 -> exactly 2x.
"""

from __future__ import annotations

import csv
import json
import os
from statistics import median

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import font_manager as fm  # noqa: E402
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SLIDES = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(SLIDES))
ASSETS = os.path.join(SLIDES, "assets")
TOKEN = 10**18

# ---------- theme ----------
_FALLBACK = {"bg": "#14070c", "surface": "#1f0a12", "surface2": "#2a0f19", "border": "#3d1724", "primary": "#e11d48",
             "accent": "#f472b6", "soft": "#fbcfe8", "text": "#ffffff", "muted": "#c99aae", "full": "#4ade80",
             "restricted": "#fbbf24", "frozen": "#e11d48", "runA": "#4ade80", "runB": "#fbbf24", "runC": "#f472b6"}
_tok_path = os.path.join(ROOT, "docs", "design-tokens.json")
if os.path.exists(_tok_path):
    with open(_tok_path, encoding="utf-8") as f:
        T = {**_FALLBACK, **json.load(f)["color"]}
else:
    T = dict(_FALLBACK)
BG, SURF, SURF2, BORDER = T["bg"], T["surface"], T["surface2"], T["border"]
PRIMARY, ACCENT, SOFT, TEXT, MUTED = T["primary"], T["accent"], T["soft"], T["text"], T["muted"]
FULL, RESTR, FROZ = T["full"], T["restricted"], T["frozen"]
STATIC, TENURE = T["runB"], T["runC"]  # Lab run colours: B static caps, C Tenure

for w in (400, 600, 800):
    fm.fontManager.addfont(os.path.join(SLIDES, "fonts", f"Inter-{w}.ttf"))
plt.rcParams.update({"font.family": "Inter", "text.color": TEXT, "axes.edgecolor": BORDER, "axes.labelcolor": SOFT,
                     "xtick.color": SOFT, "ytick.color": SOFT, "savefig.facecolor": BG, "figure.facecolor": BG})


def px(v: float) -> float:
    """slide pixels -> points (figures are sized at 100 px per inch)."""
    return v * 0.72


def canvas(w: int, h: int):
    fig = plt.figure(figsize=(w / 100, h / 100), dpi=100)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, w)
    ax.set_ylim(h, 0)
    ax.axis("off")
    return fig, ax


def save(fig, name: str) -> None:
    out = os.path.join(ASSETS, name)
    fig.savefig(out, dpi=200, facecolor=BG)
    plt.close(fig)
    print("wrote", os.path.relpath(out, ROOT))


def box(ax, x, y, w, h, fc=SURF, ec=BORDER, lw=2, r=16, z=2):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=f"round,pad=0,rounding_size={r}", fc=fc, ec=ec, lw=lw * 0.72,
                                zorder=z))


def arrow(ax, x0, y0, x1, y1, color=SOFT, lw=3, style="-|>", ls="-", rad=0.0, z=3, ms=22):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1), arrowstyle=style, mutation_scale=ms * 0.72, color=color,
                                 lw=lw * 0.72, linestyle=ls, connectionstyle=f"arc3,rad={rad}", zorder=z,
                                 shrinkA=0, shrinkB=0))


def text(ax, x, y, s, size=24, color=TEXT, weight=400, ha="left", va="center", z=5, **kw):
    ax.text(x, y, s, fontsize=px(size), color=color, fontweight=weight, ha=ha, va=va, zorder=z, **kw)


def read_csv(rel: str):
    with open(os.path.join(ROOT, rel), encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def half_up(x: float, nd: int = 0) -> str:
    """Repo rounding rule (docs/RESULTS.md): half up."""
    from decimal import ROUND_HALF_UP, Decimal
    q = Decimal(1).scaleb(-nd)
    return str(Decimal(repr(x)).quantize(q, rounding=ROUND_HALF_UP))


# ---------- A. architecture ----------
def arch():
    W, H = 900, 640
    fig, ax = canvas(W, H)
    # Unichain zone
    box(ax, 8, 8, W - 16, 440, fc=BG, ec=BORDER, lw=2, r=20, z=1)
    text(ax, 32, 40, "UNICHAIN", 19, MUTED, 600)
    # nodes
    box(ax, 32, 70, 250, 96, fc=SURF2, ec=MUTED)
    text(ax, 157, 104, "Curator agent", 24, TEXT, 600, ha="center")
    text(ax, 157, 138, "off-chain · untrusted", 20, MUTED, ha="center")
    box(ax, 32, 214, 250, 84, fc=SURF)
    text(ax, 157, 256, "CuratedVault", 24, TEXT, 600, ha="center")
    box(ax, 32, 344, 250, 84, fc=SURF)
    text(ax, 157, 386, "PoolManager", 24, TEXT, 600, ha="center")
    box(ax, 350, 290, 270, 138, fc=SURF, ec=PRIMARY, lw=3)
    text(ax, 485, 330, "TenureHook", 28, TEXT, 800, ha="center")
    text(ax, 485, 366, "measures every", 20, SOFT, ha="center")
    text(ax, 485, 392, "liquidity move", 20, SOFT, ha="center")
    box(ax, 640, 314, 156, 90, fc=SURF2)
    text(ax, 718, 346, "TenureScorer", 20, TEXT, 600, ha="center")
    text(ax, 718, 374, "math library", 19, MUTED, ha="center")
    box(ax, 350, 70, 270, 96, fc=SURF2)
    text(ax, 485, 104, "Chainlink", 24, TEXT, 600, ha="center")
    text(ax, 485, 138, "fair price", 20, MUTED, ha="center")
    box(ax, 716, 70, 160, 96, fc=SURF, ec=ACCENT, lw=2)
    text(ax, 796, 104, "Vault B", 22, TEXT, 600, ha="center")
    text(ax, 796, 138, "same curator", 19, MUTED, ha="center")
    # edges
    arrow(ax, 157, 166, 157, 212)
    text(ax, 170, 190, "rebalance", 19, MUTED)
    arrow(ax, 157, 298, 157, 342)
    arrow(ax, 284, 392, 348, 380)
    arrow(ax, 348, 350, 284, 362)
    text(ax, 290, 326, "gates", 19, MUTED)
    arrow(ax, 485, 166, 485, 288, color=SOFT)
    arrow(ax, 620, 359, 640, 359, color=MUTED, lw=2, style="-")
    # Lasna zone
    box(ax, 8, 476, W - 16, 156, fc=BG, ec=ACCENT, lw=2, r=20, z=1)
    text(ax, 32, 506, "REACTIVE LASNA", 19, ACCENT, 600)
    box(ax, 300, 520, 260, 90, fc=SURF2, ec=ACCENT)
    text(ax, 430, 552, "SettlerRC", 22, TEXT, 600, ha="center")
    text(ax, 430, 584, "settles grades", 19, MUTED, ha="center")
    box(ax, 600, 520, 276, 90, fc=SURF2, ec=ACCENT)
    text(ax, 738, 552, "FreezeRC", 22, TEXT, 600, ha="center")
    text(ax, 738, 584, "relays FROZEN", 19, MUTED, ha="center")
    arrow(ax, 430, 518, 450, 430, color=ACCENT, ls="--")
    arrow(ax, 580, 430, 660, 518, color=ACCENT, ls="--")
    arrow(ax, 846, 518, 846, 168, color=ACCENT, ls="--", rad=0.0)
    text(ax, 834, 250, "freeze", 19, ACCENT, ha="right")
    text(ax, 40, 566, "events out,\ncallbacks in", 19, MUTED, va="center", linespacing=1.4)
    save(fig, "A_architecture.png")


# ---------- B. rebalance lifecycle ----------
def lifecycle():
    W, H = 1728, 380
    fig, ax = canvas(W + 4, H)
    ax.set_xlim(-2, W + 2)
    steps = [
        ("beginRebalance", ["snapshot holdings", "at the fair price"], SURF),
        ("unlock", ["remove + add liquidity", "(hook blocks moves", "outside a session)"], SURF),
        ("endRebalance", ["mandate check", "immediate leakage", "charge the budget"], SURF),
        ("markout", ["new position vs", "“did nothing”"], SURF2),
        ("budget", ["losses drain it", "proven gains grow", "budget + deposit cap"], SURF2),
    ]
    bw, gap, y0, bh = 300, 57, 70, 250
    for i, (title, lines, fc) in enumerate(steps):
        x = i * (bw + gap)
        ec = PRIMARY if i == 3 else BORDER
        box(ax, x, y0, bw, bh, fc=fc, ec=ec, lw=3 if i == 3 else 2)
        ax.add_patch(plt.Circle((x + 38, y0 + 44), 20, color=PRIMARY if i < 3 else ACCENT, zorder=4))
        text(ax, x + 38, y0 + 45, str(i + 1), 20, BG if i >= 3 else TEXT, 800, ha="center")
        text(ax, x + 70, y0 + 45, title, 24 if len(title) < 16 else 22, TEXT, 800)
        for j, ln in enumerate(lines):
            text(ax, x + 28, y0 + 110 + j * 38, ln, 22, SOFT)
        if i < 4:
            ls = "--" if i == 2 else "-"
            arrow(ax, x + bw + 6, y0 + bh / 2, x + bw + gap - 6, y0 + bh / 2, color=ACCENT if i == 2 else SOFT, ls=ls)
    # same tx bracket and 50-block label
    ax.plot([0, 3 * bw + 2 * gap], [36, 36], color=BORDER, lw=px(3), solid_capstyle="round")
    text(ax, (3 * bw + 2 * gap) / 2, 16, "one transaction, one measured session", 20, MUTED, ha="center")
    x3 = 3 * (bw + gap)
    ax.plot([x3, W], [36, 36], color=ACCENT, lw=px(3), solid_capstyle="round")
    text(ax, (x3 + W) / 2, 16, "50 blocks later · anyone can settle", 20, ACCENT, 600, ha="center")
    save(fig, "B_lifecycle.png")


# ---------- C. tier bar ----------
def tierbar():
    W, H = 1728, 300
    fig, ax = canvas(W, H)
    x0, x1, y, h = 4, W - 4, 96, 92
    sx = lambda pct: x0 + (x1 - x0) * pct / 100  # noqa: E731
    segs = [(0, 20, FROZ, "FROZEN", "< 20%", TEXT), (20, 50, RESTR, "RESTRICTED", "20–50%", BG),
            (50, 100, FULL, "FULL", "≥ 50%", BG)]
    for a, b, c, name, rng, ink in segs:
        r = 18
        ax.add_patch(FancyBboxPatch((sx(a) + 3, y), sx(b) - sx(a) - 6, h, boxstyle=f"round,pad=0,rounding_size={r}",
                                    fc=c, ec="none", zorder=2))
        text(ax, (sx(a) + sx(b)) / 2, y + h / 2 - 2, f"{name}  {rng}", 28, ink, 800, ha="center")
    # drain / refill arrows
    arrow(ax, sx(80), 50, sx(58), 50, color=PRIMARY, lw=4)
    text(ax, sx(81), 50, "losses drain", 22, SOFT, 600)
    arrow(ax, sx(28), 50, sx(44), 50, color=FULL, lw=4)
    text(ax, sx(27), 50, "time refills", 22, SOFT, 600, ha="right")
    # restore: from frozen to 35%
    m35 = sx(35)
    arrow(ax, sx(10), y + h + 10, m35, y + h + 8, color=TEXT, lw=3, rad=0.45, ms=20)
    text(ax, m35 + 14, y + h + 62, "guardian restore → 35%  (timelocked)", 22, TEXT, 600)
    text(ax, sx(0) + 4, y + h + 62, "sticky:", 22, SOFT, 600)
    text(ax, sx(0) + 4, y + h + 94, "no auto-unfreeze", 20, MUTED)
    save(fig, "C_tiers.png")


# ---------- D. live budget chart ----------
def live_budget():
    rows = read_csv("docs/slides/data/live_ticks.csv")
    rows = [r for r in rows if int(r["tick"]) <= 90]
    t = [int(r["tick"]) for r in rows]
    b = [int(r["budgetPct10"]) / 10 for r in rows]
    tier = [int(r["tier"]) for r in rows]
    poison = 20
    restricted = next(x for x, k in zip(t, tier) if k == 1)
    frozen = next(x for x, k in zip(t, tier) if k == 2)
    W, H = 852, 300  # slide 9 grid cell
    fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
    ax = fig.add_axes([0.075, 0.12, 0.91, 0.72])
    fig.text(0.075, 0.93, "Vault A risk budget, live on Unichain Sepolia (director Tick events, ticks 1–90)",
             fontsize=px(17), color=SOFT, fontweight=600, va="center")
    ax.set_facecolor(BG)
    for lo, hi, c in ((50, 105, FULL), (20, 50, RESTR), (0, 20, FROZ)):
        ax.axhspan(lo, hi, color=c, alpha=0.10, lw=0, zorder=0)
    for yv in (20, 50):
        ax.axhline(yv, color=BORDER, lw=px(2), zorder=1)
    ax.text(89, 96, "FULL", color=FULL, fontsize=px(17), fontweight=700, ha="right", va="top")
    ax.text(89, 47, "RESTRICTED", color=RESTR, fontsize=px(17), fontweight=700, ha="right", va="top")
    ax.text(89, 17, "FROZEN", color=FROZ, fontsize=px(17), fontweight=700, ha="right", va="top")
    ax.step(t, b, where="post", color=TEXT, lw=px(4), zorder=4)
    for x, lab, c, dy in ((poison, f"poisoned · tick {poison}", ACCENT, 0),
                          (restricted, f"RESTRICTED · {restricted}", RESTR, 0),
                          (frozen, f"FROZEN · {frozen}", FROZ, 0)):
        ax.axvline(x, color=c, lw=px(2), ls=(0, (4, 3)), zorder=2)
    ax.annotate(f"poisoned · tick {poison}", (poison, 94.4), (poison - 1.2, 80), color=ACCENT, fontsize=px(17),
                fontweight=600, ha="right")
    ax.annotate(f"RESTRICTED · tick {restricted}", (restricted, 47.3), (restricted + 3.2, 62), color=RESTR,
                fontsize=px(17), fontweight=600)
    ax.annotate(f"FROZEN · tick {frozen}", (frozen, 15.1), (frozen + 3.2, 29), color=FROZ, fontsize=px(17),
                fontweight=600)
    ax.text(60, 7.7 + 2.5, f"{b[-1]:.1f}%: stays FROZEN", color=SOFT, fontsize=px(16), ha="center", va="bottom")
    ax.set_xlim(0, 90)
    ax.set_ylim(0, 105)
    ax.set_yticks([0, 20, 50, 100])
    ax.set_yticklabels(["0%", "20%", "50%", "100%"])
    ax.set_xticks([0, 20, 40, 60, 80])
    ax.tick_params(labelsize=px(16), length=0, pad=6)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(BORDER)
    save(fig, "D_live_budget.png")
    return {"restricted": restricted, "frozen": frozen, "series": list(zip(t, b))[18:27]}


# ---------- E. relay timeline ----------
def relay():
    W, H = 1728, 330
    fig, ax = canvas(W, H)
    yU, yL = 112, 236
    text(ax, 0, yU, "Unichain", 22, SOFT, 600)
    text(ax, 0, yL, "Reactive Lasna", 22, ACCENT, 600)
    ax.plot([230, 1420], [yU, yU], color=BORDER, lw=px(3))
    ax.plot([230, 1420], [yL, yL], color=BORDER, lw=px(3))
    pts = [(420, yU, FROZ, "vault A FROZEN", "block 68,837,823"),
           (860, yL, ACCENT, "FreezeRC reacts", "block 9,291,302"),
           (1300, yU, ACCENT, "vault B frozen (FreezeRelayed)", "block 68,837,825")]
    for x, y, c, a, b in pts:
        ax.add_patch(plt.Circle((x, y), 16, color=c, zorder=5))
        ax.add_patch(plt.Circle((x, y), 22, fc="none", ec=BG, lw=px(4), zorder=6))
        dy = -46 if y == yU else 46
        text(ax, x, y + dy, a, 22, TEXT, 600, ha="center")
        text(ax, x, y + dy + (26 if y == yL else -28), b, 18, MUTED, ha="center")
    arrow(ax, 440, yU + 14, 840, yL - 14, color=SOFT, lw=3)
    arrow(ax, 880, yL - 14, 1280, yU + 14, color=SOFT, lw=3)
    text(ax, 1590, 160, "2 blocks", 44, TEXT, 800, ha="center")
    text(ax, 1590, 206, "~2 seconds", 24, SOFT, 600, ha="center")
    save(fig, "E_relay_timeline.png")


# ---------- F. results ----------
def results():
    sb = read_csv("docs/results/slow_bleed.csv")
    # NAV before the first leak: 500 token0 + 1,000,000 token1 at FAIR_TICK 76,012 (test/scenario/SlowBleed.t.sol)
    nav0 = 500 * 1.0001**76012 + 1_000_000
    lostS = (nav0 - int(sb[-1]["static_nav"]) / TOKEN) / nav0 * 100
    lostT = (nav0 - int(sb[-1]["tenure_nav"]) / TOKEN) / nav0 * 100
    sw = read_csv("docs/results/sweep.csv")
    pB = median(int(r["profitB"]) for r in sw) / TOKEN
    pC = median(int(r["profitC"]) for r in sw) / TOKEN
    cut = (1 - pC / pB) * 100

    W, H = 840, 420
    fig, ax = canvas(W, H)
    panels = [("Slow bleed: value lost", "200 small “valid” leaks, % of NAV", lostS, lostT,
               lambda v: f"{half_up(v, 2)}%"),
              ("Attacker profit", "median of 20 seeds, tokens", pB, pC, lambda v: f"{float(half_up(v)):,.0f}")]
    for k, (ttl, sub, vS, vT, fmt) in enumerate(panels):
        y0 = k * 210
        text(ax, 0, y0 + 22, ttl, 24, TEXT, 700)
        text(ax, 0, y0 + 54, sub, 18, MUTED)
        maxv = max(vS, vT)
        for j, (lab, v, c) in enumerate((("static caps", vS, STATIC), ("Tenure", vT, TENURE))):
            yy = y0 + 84 + j * 56
            text(ax, 0, yy + 20, lab, 20, SOFT, 600)
            L = 160
            wbar = (W - L - 150) * v / maxv
            box(ax, L, yy, wbar, 40, fc=c, ec="none", r=6)
            text(ax, L + wbar + 12, yy + 20, fmt(v), 24, TEXT, 800)
    save(fig, "F_results.png")
    return {"slow_bleed_static_pct": lostS, "slow_bleed_tenure_pct": lostT, "profitB": pB, "profitC": pC,
            "profit_cut_pct": cut}


# ---------- G. playground ----------
def playground():
    # Values from the Tenure Lab Playground at its default parameters, which re-scores run B's 52 decisions of
    # docs/results/losses.csv with frontend/src/lib/replay.ts (rescore / staticCap); recomputed for this deck with
    # vite-node and listed in docs/slides/README.md. Unchecked total = sum of lossValue for run B.
    rows = [r for r in read_csv("docs/results/losses.csv") if r["run"] == "B"]
    unchecked = sum(int(r["lossValue"] or 0) for r in rows) / TOKEN
    decisions = sum(1 for r in rows if r["event"] == "RebalanceScored")
    tenure_charged, tenure_allowed, cap_blocked = 2471.03112, 9, 0
    W, H = 840, 420
    fig, ax = canvas(W, H)
    text(ax, 0, 22, "Losses let through", 24, TEXT, 700)
    text(ax, 0, 54, f"poisoned curator, {decisions} real decisions from the Solidity scenario, tokens", 18, MUTED)
    bars = [("no check", unchecked, MUTED, f"all {decisions} decisions"),
            ("0.2% static cap", unchecked, STATIC, f"blocks {cap_blocked} of {decisions}"),
            ("Tenure", tenure_charged, TENURE, f"FROZEN after {tenure_allowed} of {decisions}")]
    L = 200
    for j, (lab, v, c, note) in enumerate(bars):
        yy = 100 + j * 104
        text(ax, 0, yy + 22, lab, 20, SOFT, 600)
        wbar = (W - L - 130) * v / unchecked
        box(ax, L, yy, wbar, 44, fc=c, ec="none", r=6)
        text(ax, L + wbar + 12, yy + 22, f"{float(half_up(v)):,.0f}", 24, TEXT, 800)
        text(ax, L, yy + 68, note, 18, MUTED)
    save(fig, "G_playground.png")
    return {"unchecked": unchecked, "decisions": decisions}


# ---------- H. Lab screenshots: captured from the live site by lab_screenshots.py (not generated here) ----------


if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    arch()
    lifecycle()
    tierbar()
    d = live_budget()
    relay()
    f = results()
    g = playground()
    print(json.dumps({"D": d, "F": f, "G": g}, indent=1))

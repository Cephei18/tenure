"""Render the result charts from the CSVs the Foundry tests write (M4.3).

    python sim/plot_results.py            # writes docs/results/{headline,sweep,slow_bleed}.png

Inputs (all produced by `forge test`):
  docs/results/headline.csv   per-block NAV, budget ratio, tier for runs A/B/C (test/scenario/Headline.t.sol)
  docs/results/sweep.csv      per-seed losses / profits / timings over 20 seeds  (test/scenario/Sweep.t.sol)
  docs/results/slow_bleed.csv 200 small leaks: static cap vs Tenure budget       (test/scenario/SlowBleed.t.sol)

Floats are fine here: this is plotting only, never model math.
"""

from __future__ import annotations

import csv
import math
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

COMMA = FuncFormatter(lambda v, _: f"{v:,.0f}")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "docs", "results")

WAD = 10**18
TOKEN = 10**18  # token1 has 18 decimals in every scenario

# Color follows the entity (fixed categorical order, validated default palette):
#   A honest = slot 1 blue, B static caps = slot 2 orange, C Tenure = slot 3 aqua.
COLOR_A = "#2a78d6"
COLOR_B = "#eb6834"
COLOR_C = "#1baf7a"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#8a8985"
GRID = "#e4e3df"
SURFACE = "#fcfcfb"

TIER_NAMES = {0: "FULL", 1: "RESTRICTED", 2: "FROZEN"}
POISON_BLOCK = 100  # Headline.t.sol: the curator is poisoned at block 100



def _half_up(x: float) -> int:
    """Round half up to a whole token: the one rounding rule of docs/RESULTS.md."""
    return math.floor(x + 0.5)

def _style() -> None:
    plt.rcParams.update(
        {
            "figure.facecolor": SURFACE,
            "axes.facecolor": SURFACE,
            "savefig.facecolor": SURFACE,
            "axes.edgecolor": GRID,
            "axes.labelcolor": INK_2,
            "axes.titlecolor": INK,
            "axes.titleweight": "bold",
            "axes.titlesize": 12,
            "axes.titlelocation": "left",
            "axes.grid": True,
            "axes.axisbelow": True,
            "grid.color": GRID,
            "grid.linewidth": 0.8,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "xtick.color": INK_2,
            "ytick.color": INK_2,
            "font.size": 10,
            "legend.frameon": False,
            "legend.labelcolor": INK_2,
            "lines.linewidth": 2,
        }
    )


def _read(name: str) -> list[dict[str, str]]:
    with open(os.path.join(RESULTS, name), newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _first(rows: list[dict[str, str]], col: str, value: int) -> int | None:
    """First block at which `col` reaches `value` (tiers only move down within a run)."""
    for r in rows:
        if int(r[col]) >= value:
            return int(r["block"])
    return None


def _mark(ax, x: float, label: str, color: str, y: float, ha: str = "left") -> None:
    ax.axvline(x, color=color, linewidth=1, linestyle=(0, (4, 3)), zorder=1)
    ax.annotate(
        label,
        xy=(x, y),
        xycoords=("data", "axes fraction"),
        xytext=(4 if ha == "left" else -4, 0),
        textcoords="offset points",
        ha=ha,
        va="top",
        fontsize=9,
        color=INK_2,
    )


def plot_headline(out: str) -> None:
    rows = _read("headline.csv")
    block = [int(r["block"]) for r in rows]
    navA = [int(r["navA"]) for r in rows]
    # NAV minus the honest run removes the shared random-walk market move: what is left is what the poisoned
    # curator cost depositors (attack damage + fees forgone while frozen).
    dB = [(int(r["navB"]) - a) / TOKEN for r, a in zip(rows, navA)]
    dC = [(int(r["navC"]) - a) / TOKEN for r, a in zip(rows, navA)]
    ratioC = [int(r["ratioC"]) / WAD * 100 for r in rows]
    ratioA = [int(r["ratioA"]) / WAD * 100 for r in rows]

    restricted = _first(rows, "tierC", 1)
    frozen = _first(rows, "tierC", 2)

    fig, (ax1, ax2) = plt.subplots(
        2, 1, figsize=(10, 7.2), sharex=True, gridspec_kw={"height_ratios": [3, 2], "hspace": 0.18}
    )

    ax1.plot(block, dB, color=COLOR_B, label="B  static caps only")
    ax1.plot(block, dC, color=COLOR_C, label="C  Tenure")
    ax1.axhline(0, color=MUTED, linewidth=1)
    ax1.set_title("Poisoned curator: vault value lost vs. the honest run (same market)")
    ax1.set_ylabel("NAV minus honest run A (tokens)")
    _mark(ax1, POISON_BLOCK, "poisoned", MUTED, 0.98)
    if restricted is not None and restricted != frozen:
        _mark(ax1, restricted, f"C RESTRICTED (blk {restricted})", COLOR_C, 0.90)
    if frozen is not None:
        _mark(ax1, frozen, f"C FROZEN -> safe mode (blk {frozen})", COLOR_C, 0.82)
    # Direct end labels (<= 4 series: legend + direct labels).
    for series, color, name in ((dB, COLOR_B, "B"), (dC, COLOR_C, "C")):
        ax1.annotate(
            f"{name}  {series[-1]:,.0f}",
            xy=(block[-1], series[-1]),
            xytext=(6, 0),
            textcoords="offset points",
            va="center",
            fontsize=9,
            color=INK,
        )
        ax1.plot([block[-1]], [series[-1]], "o", color=color, markersize=7, markeredgecolor=SURFACE, markeredgewidth=2)
    ax1.legend(loc="lower left")
    ax1.yaxis.set_major_formatter(COMMA)
    ax1.set_xlim(block[0], block[-1] * 1.09)

    ax2.plot(block, ratioA, color=COLOR_A, linewidth=1.5, label="A  honest")
    ax2.plot(block, ratioC, color=COLOR_C, label="C  poisoned + Tenure")
    for thr, name in ((50, "FULL >= 50%"), (20, "RESTRICTED >= 20%")):
        ax2.axhline(thr, color=MUTED, linewidth=1, linestyle=(0, (2, 2)))
        ax2.annotate(name, xy=(block[-1] * 1.09, thr), xytext=(-2, 3), textcoords="offset points", ha="right",
                     fontsize=8, color=INK_2)
    ax2.set_ylim(0, 105)
    ax2.set_title("Risk budget (budget / bMax)")
    ax2.set_ylabel("% of bMax")
    ax2.set_xlabel("block")
    _mark(ax2, POISON_BLOCK, "", MUTED, 0.98)
    if frozen is not None:
        _mark(ax2, frozen, "", COLOR_C, 0.98)
    ax2.legend(loc="center left", bbox_to_anchor=(0.42, 0.3))

    fig.text(
        0.01,
        0.005,
        "Seed 0x7e2a, 600 blocks, poison at block 100. Source: docs/results/headline.csv (test/scenario/Headline.t.sol).",
        fontsize=8,
        color=MUTED,
    )
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_sweep(out: str) -> None:
    rows = _read("sweep.csv")
    data = sorted(
        ((int(r["seed"]), int(r["lossB"]) / TOKEN, int(r["lossC"]) / TOKEN) for r in rows), key=lambda t: t[1]
    )
    ys = list(range(len(data)))
    fig, ax = plt.subplots(figsize=(9, 6.4))
    for y, (_, b, c) in zip(ys, data):
        ax.plot([c, b], [y, y], color=GRID, linewidth=3, solid_capstyle="round", zorder=1)
    ax.scatter([d[1] for d in data], ys, s=64, color=COLOR_B, edgecolors=SURFACE, linewidths=2, zorder=3,
               label="B  static caps only")
    ax.scatter([d[2] for d in data], ys, s=64, color=COLOR_C, edgecolors=SURFACE, linewidths=2, zorder=3,
               label="C  Tenure")
    ax.set_yticks(ys, [f"seed {d[0]}" for d in data])
    ax.tick_params(axis="y", labelsize=8)
    ax.grid(axis="y", visible=False)
    sb = sorted(d[1] for d in data)
    n = len(sb)
    medB = sb[n // 2] if n % 2 else (sb[n // 2 - 1] + sb[n // 2]) / 2
    worstC = max(d[2] for d in data)
    ax.axvline(medB, color=COLOR_B, linewidth=1, linestyle=(0, (4, 3)))
    ax.annotate(f"B median {_half_up(medB):,}", xy=(medB, 1.0), xycoords=("data", "axes fraction"), xytext=(4, -2),
                textcoords="offset points", va="top", fontsize=9, color=INK_2)
    ax.axvline(worstC, color=COLOR_C, linewidth=1, linestyle=(0, (4, 3)))
    ax.annotate(f"C worst {_half_up(worstC):,}", xy=(worstC, 1.0), xycoords=("data", "axes fraction"), xytext=(-4, -2),
                textcoords="offset points", ha="right", va="top", fontsize=9, color=INK_2)
    ax.set_xlim(0, max(d[1] for d in data) * 1.08)
    ax.xaxis.set_major_formatter(COMMA)
    ax.set_xlabel("vault loss vs. honest run A (tokens)")
    ax.set_title("20 seeds: Tenure's worst case beats static caps' median")
    ax.legend(loc="lower right")
    fig.text(0.01, 0.005, "Sorted by B loss. Source: docs/results/sweep.csv (test/scenario/Sweep.t.sol).",
             fontsize=8, color=MUTED)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_slow_bleed(out: str) -> None:
    rows = _read("slow_bleed.csv")
    action = [int(r["action"]) for r in rows]
    nav0 = int(rows[0]["static_nav"])
    lostS = [(nav0 - int(r["static_nav"])) / TOKEN for r in rows]
    lostT = [(nav0 - int(r["tenure_nav"])) / TOKEN for r in rows]
    tiers = [r["tier"] for r in rows]

    fig, ax = plt.subplots(figsize=(10, 5))
    ax.plot(action, lostS, color=COLOR_B, label="static per-action cap only")
    ax.plot(action, lostT, color=COLOR_C, label="Tenure risk budget")
    seen = set()
    y = 0.98
    for a, t in zip(action, tiers):
        if t != "FULL" and t not in seen:
            seen.add(t)
            _mark(ax, a, f"Tenure {t} (action {a})", COLOR_C, y)
            y -= 0.08
    for series, color in ((lostS, COLOR_B), (lostT, COLOR_C)):
        ax.annotate(f"{series[-1]:,.0f}", xy=(action[-1], series[-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=9, color=INK)
        ax.plot([action[-1]], [series[-1]], "o", color=color, markersize=7, markeredgecolor=SURFACE,
                markeredgewidth=2)
    ax.set_xlim(action[0], action[-1] * 1.08)
    ax.set_xlabel("rebalance #  (each leak individually within the static cap)")
    ax.set_ylabel("cumulative value lost (tokens)")
    ax.yaxis.set_major_formatter(COMMA)
    ax.set_title("Slow bleed: 200 small 'valid' leaks")
    ax.legend(loc="upper left", bbox_to_anchor=(0, 0.78))
    fig.text(0.01, 0.005, "Source: docs/results/slow_bleed.csv (test/scenario/SlowBleed.t.sol).", fontsize=8,
             color=MUTED)
    fig.savefig(out, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main(argv: list[str]) -> int:
    out_dir = argv[1] if len(argv) > 1 else RESULTS
    os.makedirs(out_dir, exist_ok=True)
    _style()
    plot_headline(os.path.join(out_dir, "headline.png"))
    plot_sweep(os.path.join(out_dir, "sweep.png"))
    plot_slow_bleed(os.path.join(out_dir, "slow_bleed.png"))
    for name in ("headline.png", "sweep.png", "slow_bleed.png"):
        print(os.path.join(out_dir, name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

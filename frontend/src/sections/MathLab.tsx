import { useMemo, useRef, useState, type PointerEvent as RPointerEvent } from "react";
import { Card, Section, Slider, Source, fmtPct } from "../components/ui";
import { WAD } from "../math/fixed";
import { holdings, lossWad, markoutAlpha, nav, scoreLeakage, sqrtPriceAtTick, type Pair, type Position } from "../math/position";
import { liquidityForAmounts, sell0At, sell1At } from "../math/liquidity";
import { tokens } from "../lib/data";

const SPACING = 60;
const LO = -3000;
const HI = 3000;
const E18 = 10n ** 18n;
const snap = (t: number) => Math.round(t / SPACING) * SPACING;
const price = (tick: number) => Math.pow(1.0001, tick);
const fmt = (wei: bigint, d = 2) => tokens(wei).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const signed = (wei: bigint, d = 2) => (wei < 0n ? "−" : "+") + fmt(wei < 0n ? -wei : wei, d);

// The old position: the vault of the headline scenario (40,000 + 40,000 tokens) in a +-600 tick range at price 1.
const OLD: Position = (() => {
  const s = sqrtPriceAtTick(0);
  const L = liquidityForAmounts(s, sqrtPriceAtTick(-600), sqrtPriceAtTick(600), 40_000n * E18, 40_000n * E18);
  return { tickLower: -600, tickUpper: 600, liquidity: L };
})();

type Handle = "newLo" | "newHi";

// Below 0.01 token the value is rounding dust (rounded against the curator): show it in wei rather than "0.00".
const leakText = (leak: bigint) => {
  const a = leak < 0n ? -leak : leak;
  const amount = a < 10n ** 16n ? `${a.toLocaleString("en-US")} wei` : fmt(a);
  return leak === 0n ? "0" : `${amount} ${leak > 0n ? "lost" : "gained"}`;
};

export default function MathLab() {
  const [newLo, setNewLo] = useState(-300);
  const [newHi, setNewHi] = useState(900);
  const [spotTick, setSpot] = useState(0);
  const [fairTick, setFair] = useState(0);
  const [swapPct, setSwap] = useState(0); // + sells token0, - sells token1, as % of what the vault holds
  const [spotT, setSpotT] = useState(240);
  const [fairT, setFairT] = useState(240);
  const svg = useRef<SVGSVGElement>(null);
  const drag = useRef<Handle | null>(null);

  const r = useMemo(() => {
    const S = sqrtPriceAtTick(spotTick);
    const F = sqrtPriceAtTick(fairTick);
    // 1. holdings before, at the pool's spot, valued at the FAIR price
    const hBefore = holdings(OLD, 0n, 0n, S, true);
    // 2. the curator removes the old position (amounts at spot), optionally swaps at spot, adds the new range
    let [a0, a1] = holdings(OLD, 0n, 0n, S, false);
    if (swapPct > 0) {
      const x = (a0 * BigInt(swapPct)) / 100n;
      a0 -= x;
      a1 += sell0At(x, S);
    } else if (swapPct < 0) {
      const y = (a1 * BigInt(-swapPct)) / 100n;
      a1 -= y;
      a0 += sell1At(y, S);
    }
    const nw: Position = {
      tickLower: newLo, tickUpper: newHi,
      liquidity: liquidityForAmounts(S, sqrtPriceAtTick(newLo), sqrtPriceAtTick(newHi), a0, a1),
    };
    const used = holdings(nw, 0n, 0n, S, true);
    const idleNew: Pair = [a0 > used[0] ? a0 - used[0] : 0n, a1 > used[1] ? a1 - used[1] : 0n];
    const hAfter = holdings(nw, idleNew[0], idleNew[1], S, false);
    // 3. Tenure's score: immediate leakage at the fair price, as a fraction of NAV_before (rounded up)
    const [leak, navBefore] = scoreLeakage(OLD, [0n, 0n], S, nw, idleNew, S, F);
    const leakW = lossWad(leak, navBefore);
    // 4. markout after W blocks: new decision vs the do-nothing counterfactual, both at fair F_T
    const ST = sqrtPriceAtTick(spotT);
    const FT = sqrtPriceAtTick(fairT);
    const alpha = markoutAlpha(OLD, [0n, 0n], nw, idleNew, ST, FT);
    const hNewT = holdings(nw, idleNew[0], idleNew[1], ST, false);
    const hCfT = holdings(OLD, 0n, 0n, ST, true);
    const alphaW = lossWad(-alpha, navBefore);
    return {
      hBefore, navBefore, navBeforeAtSpot: nav(hBefore, S, true), nw, idleNew, hAfter, navAfter: nav(hAfter, F, false),
      leak, leakW, alpha, alphaW, hNewT, hCfT, navNewT: nav(hNewT, FT, false), navCfT: nav(hCfT, FT, true),
      totalW: leakW + alphaW,
    };
  }, [newLo, newHi, spotTick, fairTick, swapPct, spotT, fairT]);

  // ------------------------------------------------------------------ SVG geometry
  const W = 800;
  const x = (t: number) => ((t - LO) / (HI - LO)) * W;
  const tickFromClient = (clientX: number) => {
    const box = svg.current!.getBoundingClientRect();
    return snap(LO + ((clientX - box.left) / box.width) * (HI - LO));
  };
  const onMove = (e: RPointerEvent<SVGSVGElement>) => {
    if (!drag.current) return;
    const t = Math.max(LO, Math.min(HI, tickFromClient(e.clientX)));
    if (drag.current === "newLo") setNewLo(Math.min(t, newHi - SPACING));
    else setNewHi(Math.max(t, newLo + SPACING));
  };
  const handle = (h: Handle, t: number) => (
    <g
      onPointerDown={(e) => {
        drag.current = h;
        svg.current?.setPointerCapture(e.pointerId);
      }}
      style={{ cursor: "ew-resize", touchAction: "none" }}
    >
      <rect x={x(t) - 9} y={58} width={18} height={44} fill="transparent" />
      <rect x={x(t) - 3} y={64} width={6} height={32} rx={3} fill="var(--color-runC)" />
    </g>
  );
  const vline = (t: number, color: string, label: string, y: number, dash?: string) => (
    <g>
      <line x1={x(t)} x2={x(t)} y1={18} y2={150} stroke={color} strokeWidth={2} strokeDasharray={dash} />
      <text x={x(t) + 4} y={y} fill={color} fontSize={12}>{label}</text>
    </g>
  );

  const Row = ({ k, v, strong }: { k: string; v: string; strong?: boolean }) => (
    <div className="flex justify-between gap-3 text-sm">
      <span className="text-mute">{k}</span>
      <span className={`num ${strong ? "font-semibold" : ""}`}>{v}</span>
    </div>
  );

  return (
    <Section id="math" kicker="4 · The math" title="How one rebalance is scored">
      <p className="max-w-3xl text-sm text-mute">
        Drag the violet handles to choose the curator's new range. Move the pool price and the fair (oracle) price.
        Every number below is computed in your browser by an exact BigInt port of PositionValue and DecisionScore, the
        same code checked against all 1,992 differential-test vectors. The vault starts as the headline scenario's:
        40,000 + 40,000 tokens in a ±600-tick range at price 1.
      </p>
      <Card>
        <svg
          ref={svg} viewBox={`0 0 ${W} 170`} className="w-full touch-none select-none" role="img"
          aria-label="Tick axis with the old range, the new range and the price markers"
          onPointerMove={onMove} onPointerUp={() => (drag.current = null)} onPointerCancel={() => (drag.current = null)}
        >
          <rect x={x(OLD.tickLower)} y={30} width={x(OLD.tickUpper) - x(OLD.tickLower)} height={22} rx={4} fill="#8a94ad" opacity={0.35} />
          <text x={x(OLD.tickLower) + 6} y={46} fill="#e6eaf2" fontSize={12}>old range</text>
          <rect x={x(newLo)} y={66} width={x(newHi) - x(newLo)} height={28} rx={4} fill="var(--color-runC)" opacity={0.35} />
          <text x={x(newLo) + 12} y={85} fill="#e6eaf2" fontSize={12}>new range</text>
          {handle("newLo", newLo)}
          {handle("newHi", newHi)}
          {vline(spotTick, "var(--color-runB)", "pool spot", 14)}
          {vline(fairTick, "var(--color-full)", "fair", 112, "5 4")}
          {vline(spotT, "var(--color-runB)", "spot at T", 132, "2 3")}
          {vline(fairT, "var(--color-full)", "fair at T", 150, "2 3")}
          <line x1={0} x2={W} y1={160} y2={160} stroke="#263049" />
          {[-3000, -2000, -1000, 0, 1000, 2000, 3000].map((t) => (
            <text key={t} x={Math.min(W - 30, Math.max(0, x(t) - 12))} y={169} fill="#8a94ad" fontSize={10}>{t}</text>
          ))}
        </svg>
        <p className="num mt-1 text-xs text-mute">
          new range [{newLo}, {newHi}] ticks = price {price(newLo).toFixed(4)} to {price(newHi).toFixed(4)} · spacing {SPACING}
        </p>
      </Card>

      <div className="grid gap-4 md:grid-cols-3">
        <Card className="space-y-4">
          <h3 className="font-semibold">At the decision</h3>
          <Slider label="Pool spot (tick)" value={spotTick} min={-2400} max={2400} step={20} onChange={setSpot} fmt={(v) => `${v} · ${price(v).toFixed(4)}`} />
          <Slider label="Fair price (tick)" value={fairTick} min={-2400} max={2400} step={20} onChange={setFair} fmt={(v) => `${v} · ${price(v).toFixed(4)}`} />
          <Slider label="Inventory swap at pool spot" value={swapPct} min={-50} max={50} step={5} onChange={setSwap} fmt={(v) => (v === 0 ? "none" : v > 0 ? `sell ${v}% of token0` : `sell ${-v}% of token1`)} />
          <p className="text-xs text-mute">Idealized swap exactly at spot (no fee, no impact). It is where leakage comes from: trading at a spot that is off the fair price.</p>
        </Card>
        <Card className="space-y-2">
          <h3 className="font-semibold">Immediate leakage</h3>
          <Row k="holdings before (token0 / token1)" v={`${fmt(r.hBefore[0], 0)} / ${fmt(r.hBefore[1], 0)}`} />
          <Row k="NAV before, at FAIR" v={fmt(r.navBefore)} />
          <Row k="(at pool spot it would read)" v={fmt(r.navBeforeAtSpot)} />
          <Row k="holdings after (incl. idle)" v={`${fmt(r.hAfter[0], 0)} / ${fmt(r.hAfter[1], 0)}`} />
          <Row k="idle not deployed" v={`${fmt(r.idleNew[0], 0)} / ${fmt(r.idleNew[1], 0)}`} />
          <Row k="NAV after, at FAIR" v={fmt(r.navAfter)} />
          <hr className="border-line" />
          <Row k="L_imm = NAV_before − NAV_after" v={leakText(r.leak)} strong />
          <Row k="charged to the budget" v={fmtPct(Number((r.leakW * 1_000_000n) / WAD) / 1e6, 3) + " of NAV"} strong />
        </Card>
        <Card className="space-y-4">
          <h3 className="font-semibold">Markout after W blocks</h3>
          <Slider label="Pool spot at T (tick)" value={spotT} min={-2400} max={2400} step={20} onChange={setSpotT} fmt={(v) => `${v}`} />
          <Slider label="Fair price at T (tick)" value={fairT} min={-2400} max={2400} step={20} onChange={setFairT} fmt={(v) => `${v}`} />
          <div className="space-y-2">
            <Row k="NAV of the decision at T" v={fmt(r.navNewT)} />
            <Row k="NAV of doing nothing at T" v={fmt(r.navCfT)} />
            <Row k="alpha" v={signed(r.alpha)} strong />
            <Row k="charged (if alpha < 0)" v={fmtPct(Number((r.alphaW * 1_000_000n) / WAD) / 1e6, 3) + " of NAV"} strong />
          </div>
        </Card>
      </div>
      <Card>
        <p className="text-sm">
          Total loss charged for this decision:{" "}
          <span className="num font-semibold text-runC">{fmtPct(Number((r.totalW * 1_000_000n) / WAD) / 1e6, 3)} of NAV</span>{" "}
          = max(0, L_imm) + max(0, −alpha), each rounded against the curator. With the default 2% bucket, decisions like
          this one drain {fmtPct(Number((r.totalW * 1_000_000n) / (2n * 10n ** 16n)) / 1e6, 1)} of the budget.
        </p>
        <Source>
          src/math/position.ts (ports src/libraries/PositionValue.sol + DecisionScore.sol via sim/model.py); sizing
          and the idealized swap in src/math/liquidity.ts. Prices shown as decimals are display-only conversions.
        </Source>
      </Card>
    </Section>
  );
}

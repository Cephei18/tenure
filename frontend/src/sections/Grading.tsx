import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as RPointerEvent } from "react";
import { Sigma } from "lucide-react";
import { Card, SectionHeader, Slider, fmtTok } from "../components/ui";
import { WAD } from "../math/fixed";
import { holdings, lossWad, markoutAlpha, nav, scoreLeakage, sqrtPriceAtTick } from "../math/position";
import { OLD, rebalance } from "../math/example";
import { tokens as weiToTokens } from "../lib/data";
import { tokens } from "../theme/tokens";

const SPACING = 60;
const LO = -1800;
const HI = 1800;
const snap = (t: number) => Math.round(t / SPACING) * SPACING;
const clampTick = (t: number) => Math.max(LO, Math.min(HI, t));
const priceOf = (tick: number) => Math.pow(1.0001, tick); // display only
const pctOf = (w: bigint) => Number((w * 1_000_000n) / WAD) / 1e4; // WAD -> percent (display)

type Drag = "lo" | "hi" | "body" | null;

export default function Grading() {
  const [lo, setLo] = useState(-1020);
  const [hi, setHi] = useState(180);
  const [poolTick, setPool] = useState(-400);
  const [fairTick, setFair] = useState(0);
  const [laterTick, setLater] = useState(0);
  const [showMath, setShowMath] = useState(false);
  const svg = useRef<SVGSVGElement>(null);
  const drag = useRef<{ kind: Drag; grab: number }>({ kind: null, grab: 0 });

  const r = useMemo(() => {
    const S = sqrtPriceAtTick(poolTick);
    const F = sqrtPriceAtTick(fairTick);
    const T = sqrtPriceAtTick(laterTick); // W blocks later, pool and fair agree (arbitraged)
    const { nw, idle, swapped0 } = rebalance(lo, hi, S);
    const hBefore = holdings(OLD, 0n, 0n, S, true);
    const [leak, navBefore] = scoreLeakage(OLD, [0n, 0n], S, nw, idle, S, F);
    const hAfter = holdings(nw, idle[0], idle[1], S, false);
    const navAfter = nav(hAfter, F, false);
    const alpha = markoutAlpha(OLD, [0n, 0n], nw, idle, T, T);
    const navNewT = nav(holdings(nw, idle[0], idle[1], T, false), T, false);
    const navOldT = nav(holdings(OLD, 0n, 0n, T, true), T, true);
    const leakW = lossWad(leak, navBefore);
    const alphaW = lossWad(-alpha, navBefore);
    return { hBefore, navBefore, navAtSpot: nav(hBefore, S, true), hAfter, navAfter, leak, leakW, alpha, alphaW, navNewT, navOldT, swapped0, totalW: leakW + alphaW };
  }, [lo, hi, poolTick, fairTick, laterTick]);

  // ---------------------------------------------------------------- axis geometry and dragging
  // drawing width = container width (1 unit = 1 px): readable labels and finger-sized handles on phones
  const box = useRef<HTMLDivElement>(null);
  const [W, setW] = useState(800);
  useEffect(() => {
    const el = box.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(([e]) => setW(Math.max(300, Math.round(e.contentRect.width))));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const narrow = W < 560;
  const labelTicks = narrow ? [-1800, -900, 0, 900, 1800] : [-1800, -1200, -600, 0, 600, 1200, 1800];
  const x = (t: number) => ((t - LO) / (HI - LO)) * W;
  const tickAt = (clientX: number) => {
    const b = svg.current!.getBoundingClientRect();
    return LO + ((clientX - b.left) / b.width) * (HI - LO);
  };
  const onDown = (kind: Drag) => (e: RPointerEvent) => {
    drag.current = { kind, grab: tickAt(e.clientX) - lo };
    svg.current?.setPointerCapture(e.pointerId);
  };
  const onMove = (e: RPointerEvent<SVGSVGElement>) => {
    const d = drag.current;
    if (!d.kind) return;
    const t = snap(clampTick(tickAt(e.clientX)));
    if (d.kind === "lo") setLo(Math.min(t, hi - SPACING));
    else if (d.kind === "hi") setHi(Math.max(t, lo + SPACING));
    else {
      const width = hi - lo;
      const nlo = snap(clampTick(tickAt(e.clientX) - d.grab));
      const fit = Math.min(nlo, HI - width);
      setLo(fit);
      setHi(fit + width);
    }
  };
  const keyMove = (which: "lo" | "hi") => (e: KeyboardEvent) => {
    const dir = e.key === "ArrowLeft" || e.key === "ArrowDown" ? -1 : e.key === "ArrowRight" || e.key === "ArrowUp" ? 1 : 0;
    if (!dir) return;
    e.preventDefault();
    if (which === "lo") setLo((v) => Math.min(clampTick(v + dir * SPACING), hi - SPACING));
    else setHi((v) => Math.max(clampTick(v + dir * SPACING), lo + SPACING));
  };
  const marker = (t: number, color: string, label: string, y: number, dash?: string) => (
    <g>
      <line x1={x(t)} x2={x(t)} y1={14} y2={118} stroke={color} strokeWidth={2.5} strokeDasharray={dash} />
      <text x={Math.min(W - 70, x(t) + 5)} y={y} fill={color} fontSize={13} fontWeight={600}>{label}</text>
    </g>
  );
  const handle = (which: "lo" | "hi", t: number) => (
    <g role="slider" tabIndex={0} aria-label={which === "lo" ? "Range lower tick" : "Range upper tick"}
      aria-valuemin={LO} aria-valuemax={HI} aria-valuenow={t} onKeyDown={keyMove(which)}
      onPointerDown={onDown(which)} style={{ cursor: "ew-resize", touchAction: "none", outline: "none" }}>
      <rect x={x(t) - 14} y={40} width={28} height={56} fill="transparent" />
      <rect x={x(t) - 4} y={46} width={8} height={44} rx={4} fill={tokens.color.text} />
    </g>
  );

  return (
    <section id="grading" aria-labelledby="grading-title" className="mx-auto max-w-6xl space-y-6 px-4 py-14 sm:px-6">
      <SectionHeader
        id="grading" kicker="How grading works" title="Grade one rebalance yourself"
        tip="Drag the range or its edges. Every number is computed in your browser by an exact BigInt port of the hook's math, checked against 1,992 test vectors."
      />

      <Card>
        <div ref={box}>
        <svg ref={svg} viewBox={`0 0 ${W} 142`} className="w-full touch-none select-none" role="group"
          aria-label="Price axis with the curator's new liquidity range"
          onPointerMove={onMove} onPointerUp={() => (drag.current.kind = null)} onPointerCancel={() => (drag.current.kind = null)}>
          <rect x={x(OLD.tickLower)} y={100} width={x(OLD.tickUpper) - x(OLD.tickLower)} height={10} rx={5} fill={tokens.color.soft} opacity={0.35} />
          <text x={x(OLD.tickUpper) + 6} y={109} fill={tokens.color.muted} fontSize={12}>old range</text>
          <rect x={x(lo)} y={48} width={x(hi) - x(lo)} height={40} rx={10} fill={tokens.color.primary} opacity={0.35}
            onPointerDown={onDown("body")} style={{ cursor: "grab" }} />
          <text x={x(lo) + 14} y={73} fill={tokens.color.text} fontSize={13} pointerEvents="none">new range</text>
          {handle("lo", lo)}
          {handle("hi", hi)}
          {marker(fairTick, tokens.color.full, "fair", 26)}
          {marker(poolTick, tokens.color.restricted, "pool", 26, "5 4")}
          {laterTick !== fairTick && marker(laterTick, tokens.color.soft, "later", 42, "2 3")}
          {labelTicks.map((t) => (
            <text key={t} x={Math.min(W - 18, Math.max(18, x(t)))} y={138} textAnchor="middle" fill={tokens.color.muted} fontSize={11}>
              {priceOf(t).toFixed(2)}
            </text>
          ))}
        </svg>
        </div>
        <p className="num mt-1 text-xs text-muted">
          range {priceOf(lo).toFixed(3)} to {priceOf(hi).toFixed(3)} · pool {priceOf(poolTick).toFixed(3)} · fair {priceOf(fairTick).toFixed(3)}
        </p>
        <div className="mt-4 grid gap-4 sm:grid-cols-3">
          <Slider label="Fair price (oracle)" value={fairTick} min={-1500} max={1500} step={20} onChange={setFair} fmt={(t) => priceOf(t).toFixed(3)} />
          <Slider label="Pool price at the decision" value={poolTick} min={-1500} max={1500} step={20} onChange={setPool} fmt={(t) => priceOf(t).toFixed(3)} tip="An attacker can push the pool price away from fair for a block. The curator trades at this price." />
          <Slider label="Price W blocks later" value={laterTick} min={-1500} max={1500} step={20} onChange={setLater} fmt={(t) => priceOf(t).toFixed(3)} tip="When the markout settles. Pool and fair agree again after arbitrage." />
        </div>
      </Card>

      <div className="grid gap-4 md:grid-cols-3">
        <Result title="Holdings value" value={fmtTok(weiToTokens(r.navBefore))} tone={tokens.color.text}
          meaning="What the vault holds, priced by the oracle, not the pool." />
        <Result title="Leakage" value={signedTok(r.leak, "lost")} tone={r.leak > 0n ? tokens.color.frozen : tokens.color.full}
          meaning="Value lost by trading at a pool price that is off fair." />
        <Result title="Markout vs did nothing" value={signedTok(-r.alpha, "worse", "better")} tone={r.alpha < 0n ? tokens.color.frozen : tokens.color.full}
          meaning="Later, the new range against leaving the old one alone." />
      </div>

      <Card className="flex flex-wrap items-center justify-between gap-3">
        <div className="text-lg font-semibold">
          Charged to the budget: <span className="num" style={{ color: r.totalW > 0n ? tokens.color.frozen : tokens.color.full }}>{pctOf(r.totalW).toFixed(3)}% of NAV</span>
          <span className="ml-2 text-sm font-normal text-soft">= {(pctOf(r.totalW) / 2 * 100).toFixed(0)}% of a 2% bucket</span>
        </div>
        <button type="button" onClick={() => setShowMath((m) => !m)} aria-expanded={showMath}
          className="inline-flex min-h-10 items-center gap-2 rounded-xl border border-border px-4 text-sm hover:border-accent">
          <Sigma size={16} aria-hidden /> {showMath ? "Hide the math" : "Show the math"}
        </button>
      </Card>

      {showMath && (
        <Card className="space-y-3 text-sm">
          <Formula f="H = position(range, L, S) + idle" v={`before: ${wei(r.hBefore[0])} token0, ${wei(r.hBefore[1])} token1 (at pool S)`} />
          <Formula f="NAV(H, P*) = amount0 · P* + amount1" v={`before ${wei(r.navBefore)} at fair; the pool price would say ${wei(r.navAtSpot)}`} />
          <Formula f="L_imm = NAV(H_before, P*) − NAV(H_after, P*)" v={`${wei(r.navBefore)} − ${wei(r.navAfter)} = ${wei(r.leak)} (swapped ${wei(r.swapped0)} token0 at S)`} />
          <Formula f="α = NAV(H_new at S_T, P*_T) − NAV(H_old at S_T, P*_T)" v={`${wei(r.navNewT)} − ${wei(r.navOldT)} = ${wei(r.alpha)}`} />
          <Formula f="charged = ⌈max(0, L_imm) / NAV⌉ + ⌈max(0, −α) / NAV⌉" v={`${r.leakW} + ${r.alphaW} = ${r.totalW} (WAD, rounded up against the curator)`} />
          <p className="text-xs text-muted">All values in wei (18 decimals). Ports of PositionValue.sol and DecisionScore.sol; the swap sizing and LiquidityAmounts only build the example.</p>
        </Card>
      )}
    </section>
  );
}

const wei = (v: bigint) => v.toLocaleString("en-US");
function signedTok(v: bigint, pos: string, neg = "gained") {
  const t = weiToTokens(v < 0n ? -v : v);
  if (t < 0.01) return v === 0n ? "0" : `${(v < 0n ? -v : v).toLocaleString("en-US")} wei (rounding)`;
  return `${fmtTok(t, 2)} ${v > 0n ? pos : neg}`;
}

const Result = ({ title, value, meaning, tone }: { title: string; value: string; meaning: string; tone: string }) => (
  <Card className="space-y-1">
    <div className="text-sm text-soft">{title}</div>
    <div className="num text-2xl font-semibold" style={{ color: tone }}>{value}</div>
    <div className="text-sm text-muted">{meaning}</div>
  </Card>
);
const Formula = ({ f, v }: { f: string; v: string }) => (
  <div>
    <div className="font-mono text-accent">{f}</div>
    <div className="num break-all font-mono text-xs text-soft">{v}</div>
  </div>
);

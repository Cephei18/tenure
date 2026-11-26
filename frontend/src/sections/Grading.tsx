import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as RPointerEvent, type ReactNode } from "react";
import { Ceil, Fn, Frac, MATH_COLORS, N, Op, Result as MathResult, V } from "../components/math";
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

      <Solution r={r} pFair={priceOf(fairTick)} pPool={priceOf(poolTick)} pLater={priceOf(laterTick)} />
    </section>
  );
}

// ------------------------------------------------------------------------------------------------ worked solution
type Graded = {
  hBefore: readonly [bigint, bigint]; navBefore: bigint; navAfter: bigint; leak: bigint; leakW: bigint;
  alpha: bigint; alphaW: bigint; navNewT: bigint; navOldT: bigint; totalW: bigint;
};

function Solution({ r, pFair, pPool, pLater }: { r: Graded; pFair: number; pPool: number; pLater: number }) {
  const [unit, setUnit] = useState<"tokens" | "wei">(() => {
    try {
      return new URLSearchParams(window.location.search).get("units") === "wei" ? "wei" : "tokens";
    } catch {
      return "tokens";
    }
  });
  // magnitude only; `signed` adds the sign once (BigInt's own "-" would double it)
  const amt = (v: bigint) => {
    const m = v < 0n ? -v : v;
    return unit === "wei" ? m.toLocaleString("en-US") : fmtTok(weiToTokens(m), 2);
  };
  const signed = (v: bigint) => `${v < 0n ? "−" : ""}${amt(v)}`;
  const pct = (w: bigint) => `${pctOf(w).toFixed(3)}%`;
  const price = (p: number) => p.toFixed(4);
  const lossColor = (bad: boolean) => (bad ? tokens.color.frozen : tokens.color.full);
  const bucketShare = (pctOf(r.totalW) / 2) * 100;

  return (
    <Card className="space-y-1">
      <div className="flex flex-wrap items-center justify-between gap-3 pb-2">
        <h3 className="text-lg font-semibold">Worked solution</h3>
        <div role="radiogroup" aria-label="Units" className="flex overflow-hidden rounded-xl border border-border text-sm">
          {(["tokens", "wei"] as const).map((u) => (
            <button key={u} type="button" role="radio" aria-checked={unit === u} onClick={() => setUnit(u)}
              className={`min-h-9 px-3 ${unit === u ? "bg-surface2 text-text" : "text-soft"}`}>
              {u === "tokens" ? "Tokens" : "Exact (wei)"}
            </button>
          ))}
        </div>
      </div>

      <Step n={1} title="Value at the fair price" meaning="Holdings priced by the oracle, never by the pool."
        formula={<><Fn>NAV</Fn><Op>=</Op><V sub="0">a</V><Op>·</Op><V sup="*" color={MATH_COLORS.fair}>P</V><Op>+</Op><V sub="1">a</V></>}
        subst={<><N>{amt(r.hBefore[0])}</N><Op>×</Op><N color={MATH_COLORS.fair}>{price(pFair)}</N><Op>+</Op><N>{amt(r.hBefore[1])}</N></>}
        result={<MathResult value={amt(r.navBefore)} color={tokens.color.text}>{amt(r.navBefore)}</MathResult>}
        note={<>holdings taken at the pool price <V color={MATH_COLORS.pool}>S</V> = <N color={MATH_COLORS.pool}>{price(pPool)}</N></>}
      />

      <Step n={2} title="Leakage" meaning="Value lost by trading at a pool price off fair."
        formula={<><V sub="imm">L</V><Op>=</Op><Fn>NAV</Fn><sub className="text-[0.68em]">before</sub><Op>−</Op><Fn>NAV</Fn><sub className="text-[0.68em]">after</sub></>}
        subst={<><N>{amt(r.navBefore)}</N><Op>−</Op><N>{amt(r.navAfter)}</N></>}
        result={<MathResult value={signed(r.leak)} color={lossColor(r.leak > 0n)}>{signed(r.leak)}</MathResult>}
        note={<>both valued at <V sup="*" color={MATH_COLORS.fair}>P</V>; positive means lost</>}
      />

      <Step n={3} title="Markout vs did nothing" meaning="Later, the new range against leaving the old one alone."
        formula={<><V>α</V><Op>=</Op><Fn>NAV</Fn><sub className="text-[0.68em]">new</sub>(<V color={MATH_COLORS.later}>T</V>)<Op>−</Op><Fn>NAV</Fn><sub className="text-[0.68em]">old</sub>(<V color={MATH_COLORS.later}>T</V>)</>}
        subst={<><N>{amt(r.navNewT)}</N><Op>−</Op><N>{amt(r.navOldT)}</N></>}
        result={<MathResult value={signed(r.alpha)} color={lossColor(r.alpha < 0n)}>{signed(r.alpha)}</MathResult>}
        note={<>price <V color={MATH_COLORS.later}>T</V> = <N color={MATH_COLORS.later}>{price(pLater)}</N>, W blocks later; negative means worse</>}
      />

      <Step n={4} title="Charged to the budget" meaning="Both losses as a share of NAV, rounded up."
        formula={<>
          <V>c</V><Op>=</Op>
          <Ceil><Frac num={<><Fn>max</Fn>(0, <V sub="imm">L</V>)</>} den={<Fn>NAV</Fn>} /></Ceil>
          <Op>+</Op>
          <Ceil><Frac num={<><Fn>max</Fn>(0, −<V>α</V>)</>} den={<Fn>NAV</Fn>} /></Ceil>
        </>}
        subst={<><N>{pct(r.leakW)}</N><Op>+</Op><N>{pct(r.alphaW)}</N></>}
        result={<MathResult value={pct(r.totalW)} color={lossColor(r.totalW > 0n)}>{pct(r.totalW)} of NAV</MathResult>}
        note={<><N>{bucketShare.toFixed(0)}%</N> of a 2% bucket{bucketShare >= 80 ? ": one decision like this freezes the curator" : ""}</>}
        last
      />
      <p className="pt-2 text-xs text-muted">
        {unit === "tokens" ? "Rounded for display; computed exactly in wei." : "Exact integers (18 decimals), as the hook computes them."}
      </p>
    </Card>
  );
}

function Step(props: { n: number; title: string; meaning: string; formula: ReactNode; subst: ReactNode; result: ReactNode; note: ReactNode; last?: boolean }) {
  const { n, title, meaning, formula, subst, result, note, last } = props;
  return (
    <div className={`grid gap-3 py-4 sm:grid-cols-[230px_1fr] ${last ? "" : "border-b border-border"}`}>
      <div className="flex gap-3">
        <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary/20 text-sm font-semibold text-accent">{n}</span>
        <div>
          <div className="font-semibold">{title}</div>
          <div className="text-xs text-muted">{meaning}</div>
        </div>
      </div>
      <div className="min-w-0 space-y-1.5 text-base sm:text-lg">
        <div className="flex flex-wrap items-center text-text">{formula}</div>
        <div className="flex flex-wrap items-center break-all">
          <Op>=</Op>{subst}<Op>=</Op>{result}
        </div>
        <div className="text-xs text-soft">{note}</div>
      </div>
    </div>
  );
}

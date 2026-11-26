import { useEffect, useMemo, useRef, useState } from "react";
import { Pause, Play, RotateCcw, SlidersHorizontal, X } from "lucide-react";
import {
  Bar, BarChart, CartesianGrid, Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis,
} from "recharts";
import { headline, lossEvents, sweep, tokens as weiToTokens } from "../lib/data";
import { LAST_STEP, chargedUpTo, eventsFor, stateAt, toastText, type RunKey, type SimEvent } from "../lib/sim";
import { rescore, staticCap } from "../lib/replay";
import { sweepStats } from "../lib/stats";
import { DEFAULT_PARAMS, type BudgetParams } from "../math/budget";
import { on } from "../lib/bus";
import { RUN_COLORS, TIER_COLORS, tokens } from "../theme/tokens";
import { Button, Card, Counter, Ring, SectionHeader, Slider, Tip, TierBadge, fmtInt, fmtTok, useReducedMotion } from "../components/ui";

type Mode = RunKey | "compare";
const MODES: { key: Mode; label: string }[] = [
  { key: "A", label: "Honest curator" },
  { key: "B", label: "Poisoned + static caps" },
  { key: "C", label: "Poisoned + Tenure" },
  { key: "compare", label: "Compare B vs C" },
];
const RUN_NAME: Record<RunKey, string> = { A: "Honest", B: "Static caps", C: "Tenure" };
const BLOCKS_PER_SEC = 20; // at 1x: the 600-block scenario plays in 30 s
const AXIS = { stroke: tokens.color.muted, fontSize: 11 };
const GRID = tokens.color.border;
const TIP_STYLE = { contentStyle: { background: tokens.color.surface2, border: `1px solid ${tokens.color.border}`, borderRadius: 12, fontSize: 12 }, labelStyle: { color: tokens.color.text } };

const runsOf = (m: Mode): RunKey[] => (m === "compare" ? ["B", "C"] : [m]);

export default function Simulator() {
  const [mode, setMode] = useState<Mode>("compare");
  const [frame, setFrame] = useState(LAST_STEP);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [toasts, setToasts] = useState<{ id: number; text: string; tone: string }[]>([]);
  const [tuneOpen, setTuneOpen] = useState(() => {
    try {
      return new URLSearchParams(window.location.search).get("tune") === "1";
    } catch {
      return false;
    }
  });
  const reduce = useReducedMotion();
  const lastFrame = useRef(frame);
  const toastId = useRef(0);
  const toastTimers = useRef<number[]>([]);

  // ---------------------------------------------------------------- playback
  useEffect(() => {
    if (!playing) return;
    // wall-clock ticker (not requestAnimationFrame): playback keeps time in background tabs and recorders
    let prev = performance.now();
    let acc = 0;
    const tick = () => {
      const t = performance.now();
      acc += ((t - prev) / 1000) * BLOCKS_PER_SEC * speed;
      prev = t;
      const whole = Math.floor(acc);
      if (whole > 0) {
        acc -= whole;
        setFrame((f) => {
          const n = Math.min(LAST_STEP, f + whole);
          if (n >= LAST_STEP) setPlaying(false);
          return n;
        });
      }
    };
    const id = window.setInterval(tick, 16);
    return () => window.clearInterval(id);
  }, [playing, speed]);

  // ---------------------------------------------------------------- bus (Hero button, Demo mode)
  useEffect(() => {
    const offs = [
      on("sim:run", ({ mode: m, speed: sp, from }) => {
        setMode(m);
        if (sp) setSpeed(sp);
        lastFrame.current = from ?? 0;
        setFrame(from ?? 0);
        setToasts([]);
        setPlaying(true);
      }),
      on("sim:pause", () => setPlaying(false)),
      on("sim:seek", ({ step }) => setFrame(step)),
      on("sim:speed", ({ speed: sp }) => setSpeed(sp)),
      on("sim:tune", ({ open }) => setTuneOpen(open)),
    ];
    return () => offs.forEach((o) => o());
  }, []);

  // ---------------------------------------------------------------- events -> toasts
  const runs = runsOf(mode);
  const events = useMemo(() => runs.flatMap((r) => eventsFor(r)), [mode]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const prev = lastFrame.current;
    lastFrame.current = frame;
    if (frame <= prev || frame - prev > 60) return; // only while playing forward (not on big scrubs)
    const crossed = events.filter((e) => e.step > prev && e.step <= frame);
    if (!crossed.length) return;
    const add = crossed.slice(-3).map((e) => ({
      id: ++toastId.current,
      text: `${mode === "compare" ? `${RUN_NAME[e.run]} · ` : ""}${toastText(e)}`,
      tone: e.kind === "frozen" ? tokens.color.frozen : e.kind === "restricted" ? tokens.color.restricted : e.kind === "poison" ? tokens.color.accent : tokens.color.soft,
    }));
    setToasts((t) => [...t, ...add].slice(-3));
    // dismissal must survive later frames: keep the timer outside this effect's cleanup
    const ids = add.map((a) => a.id);
    toastTimers.current.push(window.setTimeout(() => setToasts((t) => t.filter((x) => !ids.includes(x.id))), 3500));
  }, [frame, events, mode]);
  useEffect(() => () => toastTimers.current.forEach((id) => window.clearTimeout(id)), []);

  // ---------------------------------------------------------------- chart data (drawn up to the playhead)
  const chart = useMemo(
    () => headline.map((r) => ({
      block: r.block,
      A: r.nav[0],
      B: r.block <= frame ? r.nav[1] : null,
      C: r.block <= frame ? r.nav[2] : null,
      Aplay: r.block <= frame ? r.nav[0] : null,
    })),
    [frame],
  );

  return (
    <section id="simulator" aria-labelledby="simulator-title" className="mx-auto max-w-6xl space-y-6 px-4 py-14 sm:px-6">
      <SectionHeader
        id="simulator" kicker="Simulator" title="Replay the real attack"
        tip="Recorded from the Solidity scenario (test/scenario/Headline.t.sol): one market, three runs, 600 blocks. A poisoned curator parks liquidity away from the price, then follows an attacker's price push."
      />

      {/* scenario selector */}
      <div role="radiogroup" aria-label="Scenario" className="flex flex-wrap gap-2">
        {MODES.map((m) => (
          <button
            key={m.key} type="button" role="radio" aria-checked={mode === m.key}
            onClick={() => {
              setMode(m.key);
              setToasts([]);
            }}
            className={`min-h-10 rounded-xl border px-3.5 text-sm font-medium transition-colors ${mode === m.key ? "border-accent bg-surface2 text-text" : "border-border bg-surface text-soft hover:text-text"}`}
          >
            {m.label}
          </button>
        ))}
      </div>

      <Card className="space-y-5" id="sim-player">
        <Transport
          frame={frame} playing={playing} speed={speed} events={events}
          onPlay={() => {
            if (frame >= LAST_STEP) {
              lastFrame.current = 0;
              setFrame(0);
            }
            setPlaying((p) => !p);
          }}
          onScrub={(f) => {
            setPlaying(false);
            lastFrame.current = f;
            setFrame(f);
          }}
          onSpeed={setSpeed}
        />

        <div className={`grid gap-4 ${runs.length === 2 ? "md:grid-cols-2" : ""}`}>
          {runs.map((r) => <RunPanel key={r} run={r} frame={frame} />)}
        </div>

        <div>
          <div className="mb-1 flex items-center gap-1 text-sm font-medium">
            Vault value at the fair price
            <Tip>NAV of the vault in tokens, valued at the oracle price. The honest run is the faint reference line.</Tip>
          </div>
          <div className="h-56 sm:h-64">
            <ResponsiveContainer>
              <LineChart data={chart} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
                <CartesianGrid stroke={GRID} strokeDasharray="3 3" />
                <XAxis dataKey="block" type="number" domain={[0, LAST_STEP]} tick={AXIS} />
                <YAxis tick={AXIS} width={52} domain={["auto", "auto"]} tickFormatter={(v) => `${(v / 1000).toFixed(1)}k`} />
                <Tooltip {...TIP_STYLE} formatter={(v: number) => fmtTok(v)} labelFormatter={(l) => `block ${l}`} />
                <ReferenceLine x={frame} stroke={tokens.color.soft} strokeOpacity={0.5} />
                <Line dataKey={runs.includes("A") ? "Aplay" : "A"} name="Honest" stroke={RUN_COLORS.A} strokeOpacity={runs.includes("A") ? 1 : 0.3} dot={false} strokeWidth={2} isAnimationActive={false} />
                {runs.includes("B") && <Line dataKey="B" name="Static caps" stroke={RUN_COLORS.B} dot={false} strokeWidth={2.5} isAnimationActive={false} />}
                {runs.includes("C") && <Line dataKey="C" name="Tenure" stroke={RUN_COLORS.C} dot={false} strokeWidth={2.5} isAnimationActive={false} />}
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>

        <div aria-live="polite" className="pointer-events-none fixed right-4 top-16 z-40 flex w-[min(92vw,360px)] flex-col gap-2">
          {toasts.map((t, i) => (
            <div key={t.id} className={`${reduce ? "" : "toast-in"} ${i < toasts.length - 1 ? "hidden sm:block" : ""} rounded-xl border bg-surface2 px-3 py-2 text-xs shadow-xl sm:px-4 sm:py-2.5 sm:text-sm`} style={{ borderColor: `${t.tone}88`, color: tokens.color.text }}>
              <span className="mr-2 inline-block h-2 w-2 rounded-full" style={{ background: t.tone }} aria-hidden />
              {t.text}
            </div>
          ))}
        </div>
      </Card>

      <div className="flex flex-wrap items-center gap-3">
        <Button onClick={() => setTuneOpen((o) => !o)} pressed={tuneOpen}>
          {tuneOpen ? <X size={16} aria-hidden /> : <SlidersHorizontal size={16} aria-hidden />} Tune Tenure
        </Button>
        <span className="text-sm text-soft">Real losses from the Solidity scenario, re-scored live.</span>
      </div>
      {tuneOpen && <TuneDrawer />}

      <SweepResults />
    </section>
  );
}

// ------------------------------------------------------------------------------------------------ transport
function Transport(props: {
  frame: number; playing: boolean; speed: number; events: SimEvent[];
  onPlay: () => void; onScrub: (f: number) => void; onSpeed: (s: number) => void;
}) {
  const { frame, playing, speed, events, onPlay, onScrub, onSpeed } = props;
  const color = (e: SimEvent) =>
    e.kind === "frozen" ? tokens.color.frozen : e.kind === "restricted" ? tokens.color.restricted : e.kind === "poison" ? tokens.color.accent : RUN_COLORS[e.run];
  return (
    <div className="flex flex-wrap items-center gap-3">
      <Button variant="primary" onClick={onPlay} ariaLabel={playing ? "Pause" : "Play"}>
        {playing ? <Pause size={16} aria-hidden /> : <Play size={16} aria-hidden />}
        <span className="hidden sm:inline">{playing ? "Pause" : frame >= LAST_STEP ? "Replay" : "Play"}</span>
      </Button>
      <div className="relative min-w-0 flex-1 basis-48">
        {/* event markers above the scrub bar */}
        <div className="pointer-events-none relative h-3" aria-hidden>
          {events.map((e, i) => (
            <span
              key={i}
              className="absolute top-0 rounded-full"
              style={{
                left: `calc(${(e.step / LAST_STEP) * 100}% - ${e.kind === "round" ? 1 : 3}px)`,
                width: e.kind === "round" ? 2 : 6, height: e.kind === "round" ? 10 : 6,
                background: color(e), opacity: e.step <= frame ? 1 : 0.45,
              }}
            />
          ))}
        </div>
        <input
          type="range" className="w-full" min={0} max={LAST_STEP} value={frame} aria-label="Block"
          aria-valuetext={`block ${frame} of ${LAST_STEP}`} onChange={(e) => onScrub(Number(e.target.value))}
        />
      </div>
      <span className="num w-20 text-right text-sm text-soft">block {frame}</span>
      <div role="radiogroup" aria-label="Speed" className="flex overflow-hidden rounded-xl border border-border">
        {[1, 2, 4].map((s) => (
          <button
            key={s} type="button" role="radio" aria-checked={speed === s} onClick={() => onSpeed(s)}
            className={`min-h-10 px-3 text-sm ${speed === s ? "bg-surface2 text-text" : "bg-surface text-soft"}`}
          >
            {s}x
          </button>
        ))}
      </div>
      <div className="flex w-full flex-wrap gap-x-4 gap-y-1 text-[11px] text-muted" aria-hidden>
        <Legend c={tokens.color.accent} t="poisoned" />
        <Legend c={tokens.color.soft} t="attack round" bar />
        <Legend c={tokens.color.restricted} t="RESTRICTED" />
        <Legend c={tokens.color.frozen} t="FROZEN" />
      </div>
    </div>
  );
}
const Legend = ({ c, t, bar }: { c: string; t: string; bar?: boolean }) => (
  <span className="inline-flex items-center gap-1.5">
    <span className="inline-block rounded-full" style={{ background: c, width: bar ? 2 : 6, height: bar ? 10 : 6 }} />
    {t}
  </span>
);

// ------------------------------------------------------------------------------------------------ one run
function RunPanel({ run, frame }: { run: RunKey; frame: number }) {
  const st = stateAt(run, frame);
  const charged = weiToTokens(chargedUpTo(run, frame));
  const vsHonest = st.nav - st.navA;
  const rounds = eventsFor(run).filter((e) => e.kind === "round" && e.step <= frame).length;
  return (
    <div className="flex items-center gap-3 rounded-2xl border border-border bg-surface2/40 p-3 sm:gap-4 sm:p-4">
      <Ring ratio={Math.min(1, st.ratio)} tier={st.tier} className="h-24 w-24 shrink-0 sm:h-32 sm:w-32" label={run === "B" ? "never binds" : "budget"} />
      <div className="min-w-0 flex-1 space-y-1.5 sm:space-y-2">
        <div className="flex items-center justify-between gap-2">
          <span className="font-semibold" style={{ color: RUN_COLORS[run] }}>{RUN_NAME[run]}</span>
          <TierBadge tier={st.tier} />
        </div>
        <Metric k="Vault value" v={<Counter value={st.nav} format={fmtInt} />} />
        {run !== "A" && <Metric k="vs honest run" v={<Counter value={vsHonest} format={(x) => `${x < 0 ? "−" : "+"}${fmtInt(Math.abs(x))}`} />} tip="Difference to the honest run's value at the same block. Mixes attack damage and market drift." />}
        <Metric k="Loss charged" v={<Counter value={charged} format={(x) => fmtTok(x, 1)} />} tip="Sum of the losses the hook measured and charged for this curator's decisions so far (losses.csv)." />
        {run !== "A" && <Metric k="Attack rounds" v={<span className="num">{rounds}</span>} />}
      </div>
    </div>
  );
}
const Metric = ({ k, v, tip }: { k: string; v: React.ReactNode; tip?: string }) => (
  <div className="flex items-center justify-between gap-2 text-sm">
    <span className="flex items-center gap-1 text-soft">{k}{tip && <Tip label={`About ${k}`}>{tip}</Tip>}</span>
    <span className="font-medium">{v}</span>
  </div>
);

// ------------------------------------------------------------------------------------------------ tune drawer
const WAD = 10n ** 18n;
const pctToWad = (pct: number) => (BigInt(Math.round(pct * 10_000)) * WAD) / 1_000_000n;
const DEFAULTS = { bMaxPct: 2, refillBlocks: 7200, fullPct: 50, restrictedPct: 20, capPct: 0.2 };
const B_EVENTS = lossEvents.filter((e) => e.run === "B");
const A_EVENTS = lossEvents.filter((e) => e.run === "A");
const TOTAL_DECISIONS = B_EVENTS.filter((e) => e.event === "RebalanceScored").length;
const UNCHECKED = B_EVENTS.reduce((s, e) => s + e.lossValue, 0n);

function TuneDrawer() {
  const [v, setV] = useState(DEFAULTS);
  const set = (k: keyof typeof DEFAULTS) => (x: number) => setV((o) => ({ ...o, [k]: x }));
  const params: BudgetParams = useMemo(() => {
    const bMax0 = pctToWad(v.bMaxPct);
    return {
      ...DEFAULT_PARAMS, bMax0, bMaxCap: bMax0 > DEFAULT_PARAMS.bMaxCap ? bMax0 : DEFAULT_PARAMS.bMaxCap,
      refillRate: bMax0 / BigInt(v.refillBlocks), fullThreshold: pctToWad(v.fullPct),
      restrictedThreshold: pctToWad(Math.min(v.restrictedPct, v.fullPct - 5)),
    };
  }, [v]);
  const mine = useMemo(() => rescore(B_EVENTS, params), [params]);
  const honest = useMemo(() => rescore(A_EVENTS, params), [params]);
  const cap = useMemo(() => staticCap(B_EVENTS, pctToWad(v.capPct)), [v.capPct]);
  const series = useMemo(() => mine.points.filter((p) => p.step >= 0).map((p) => ({ step: p.step, ratio: p.ratio * 100 })), [mine]);

  return (
    <Card className="grid gap-6 lg:grid-cols-[300px_1fr]">
      <div className="space-y-4">
        <Slider label="Bucket size" value={v.bMaxPct} min={0.25} max={10} step={0.25} onChange={set("bMaxPct")} fmt={(x) => `${x}% of NAV`} tip="bMax: total loss allowance before the curator is frozen, as a share of vault value." />
        <Slider label="Refill time" value={v.refillBlocks} min={600} max={43200} step={600} onChange={set("refillBlocks")} fmt={(x) => `${x.toLocaleString("en-US")} blocks`} tip="Blocks for an empty budget to refill completely. Frozen budgets never refill." />
        <Slider label="FULL at or above" value={v.fullPct} min={30} max={90} step={5} onChange={set("fullPct")} fmt={(x) => `${x}%`} />
        <Slider label="FROZEN below" value={Math.min(v.restrictedPct, v.fullPct - 5)} min={5} max={v.fullPct - 5} step={5} onChange={set("restrictedPct")} fmt={(x) => `${x}%`} />
        <Slider label="Static cap per action" value={v.capPct} min={0.05} max={1} step={0.05} onChange={set("capPct")} fmt={(x) => `${x.toFixed(2)}% of NAV`} tip="Comparison: a memoryless cap that blocks any single decision losing more than this." />
        <Button onClick={() => setV(DEFAULTS)}><RotateCcw size={16} aria-hidden /> Reset to defaults</Button>
      </div>
      <div className="space-y-4">
        <div className="rounded-2xl border border-border bg-surface2/50 p-4" aria-live="polite">
          <div className="text-lg font-semibold sm:text-xl">
            {mine.frozenStep === null
              ? <>Never freezes · {TOTAL_DECISIONS} of {TOTAL_DECISIONS} decisions</>
              : <>Freezes after {mine.decisionsAllowed} of {TOTAL_DECISIONS} decisions</>}
          </div>
          <div className="mt-1 text-sm text-soft">
            Loss <span className="num text-text">{fmtTok(weiToTokens(mine.lossCharged))}</span> vs{" "}
            <span className="num text-text">{fmtTok(weiToTokens(cap.lossCharged))}</span> with the static cap
            {" "}(<span className="num">{fmtTok(weiToTokens(UNCHECKED))}</span> unchecked)
          </div>
          <div className="mt-2 text-sm" style={{ color: honest.restrictedStep === null ? tokens.color.full : tokens.color.restricted }}>
            {honest.restrictedStep === null ? "Honest curator: never restricted" : `Honest curator restricted at block ${honest.restrictedStep}: too tight`}
          </div>
        </div>
        <div className="h-44">
          <ResponsiveContainer>
            <LineChart data={series} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
              <CartesianGrid stroke={GRID} strokeDasharray="3 3" />
              <XAxis dataKey="step" type="number" domain={[0, LAST_STEP]} tick={AXIS} />
              <YAxis domain={[0, 100]} tick={AXIS} width={40} tickFormatter={(x) => `${x}%`} />
              <Tooltip {...TIP_STYLE} formatter={(x: number) => `${x.toFixed(1)}%`} labelFormatter={(l) => `block ${l}`} />
              <ReferenceLine y={v.fullPct} stroke={TIER_COLORS[0]} strokeDasharray="4 4" />
              <ReferenceLine y={Math.min(v.restrictedPct, v.fullPct - 5)} stroke={TIER_COLORS[2]} strokeDasharray="4 4" />
              <Line dataKey="ratio" name="budget" type="stepAfter" stroke={RUN_COLORS.C} dot={false} strokeWidth={2} isAnimationActive={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>
      </div>
    </Card>
  );
}

// ------------------------------------------------------------------------------------------------ sweep
function SweepResults() {
  const s = useMemo(() => sweepStats(), []);
  const frozen = sweep.filter((r) => r.cBlocksToFrozen > 0).length;
  const honestOk = sweep.every((r) => r.aMinRatio >= 0.5) && headline.every((r) => r.tier[0] === 0);
  const bars = useMemo(() => [...sweep].sort((a, b) => a.lossB - b.lossB).map((r) => ({ seed: `${r.seed}`, B: Math.round(r.lossB), C: Math.round(r.lossC) })), []);
  return (
    <div className="space-y-4 pt-4" id="sweep">
      <h3 className="flex items-center gap-2 text-xl font-semibold">
        Same attack, 20 random markets
        <Tip>test/scenario/Sweep.t.sol, seeds 0-19 (docs/results/sweep.csv). Medians are exact, rounded half up.</Tip>
      </h3>
      <div className="grid grid-cols-3 gap-2 sm:gap-4">
        <Big value={`${frozen}/${s.seeds}`} label="poisoned curators frozen" color={tokens.color.frozen} />
        <Big value={honestOk ? "Never" : "Sometimes"} label="honest curator restricted" color={tokens.color.full} />
        <Big value={`${s.profitCutPct}%`} label="less attacker profit (median)" color={tokens.color.accent} />
      </div>
      <Card>
        <div className="mb-1 flex items-center gap-1 text-sm font-medium">
          Value lost vs the honest run, per market
          <Tip>Tokens, sorted by the static-caps loss. Mixes attack damage with market drift of parked or idle positions.</Tip>
        </div>
        <div className="h-56">
          <ResponsiveContainer>
            <BarChart data={bars} margin={{ top: 8, right: 8, bottom: 0, left: 0 }} barGap={1}>
              <CartesianGrid stroke={GRID} strokeDasharray="3 3" vertical={false} />
              <XAxis dataKey="seed" tick={AXIS} interval="preserveStartEnd" />
              <YAxis tick={AXIS} width={44} tickFormatter={(x) => `${x / 1000}k`} />
              <Tooltip {...TIP_STYLE} formatter={(x: number) => fmtTok(x)} labelFormatter={(l) => `market ${l}`} cursor={{ fill: tokens.color.surface2 }} />
              <Bar dataKey="B" name="Static caps" fill={RUN_COLORS.B} radius={[3, 3, 0, 0]} isAnimationActive={false} />
              <Bar dataKey="C" name="Tenure" fill={RUN_COLORS.C} radius={[3, 3, 0, 0]} isAnimationActive={false} />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <div className="mt-2 flex gap-4 text-xs text-soft">
          <Legend c={RUN_COLORS.B} t="Static caps" />
          <Legend c={RUN_COLORS.C} t="Tenure" />
        </div>
      </Card>
    </div>
  );
}
const Big = ({ value, label, color }: { value: string; label: string; color: string }) => (
  <Card className="!p-3 sm:!p-5">
    <div className="num text-2xl font-bold sm:text-4xl" style={{ color }}>{value}</div>
    <div className="mt-1 text-xs text-soft sm:text-sm">{label}</div>
  </Card>
);

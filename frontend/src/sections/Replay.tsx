import { useEffect, useMemo, useRef, useState } from "react";
import {
  Bar, BarChart, CartesianGrid, Legend, Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis,
} from "recharts";
import { POISON_AT, attackRounds, headline, sweep } from "../lib/data";
import { Card, RUN_COLORS, RUN_LABELS, Section, Source, Stat, TierBadge, fmtPct, fmtTok } from "../components/ui";
import { FROZEN, RESTRICTED } from "../math/budget";

const RUNS = ["A", "B", "C"] as const;
const LAST = headline.length - 1;
const firstBlock = (run: number, pred: (t: number) => boolean) => headline.find((r) => pred(r.tier[run]))?.block ?? null;
const C_RESTRICTED = firstBlock(2, (t) => t === RESTRICTED);
const C_FROZEN = firstBlock(2, (t) => t === FROZEN);
const ROUNDS = { B: attackRounds("B"), C: attackRounds("C") };
const AXIS = { stroke: "#8a94ad", fontSize: 11 };
const TIP = { contentStyle: { background: "#121826", border: "1px solid #263049", fontSize: 12 }, labelStyle: { color: "#e6eaf2" } };

function median(xs: number[]) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

export default function Replay() {
  const [frame, setFrame] = useState(LAST);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(4); // blocks per animation tick
  const raf = useRef<number | null>(null);

  useEffect(() => {
    if (!playing) return;
    let last = performance.now();
    const step = (t: number) => {
      if (t - last > 50) {
        last = t;
        setFrame((f) => {
          if (f >= LAST) {
            setPlaying(false);
            return LAST;
          }
          return Math.min(LAST, f + speed);
        });
      }
      raf.current = requestAnimationFrame(step);
    };
    raf.current = requestAnimationFrame(step);
    return () => {
      if (raf.current) cancelAnimationFrame(raf.current);
    };
  }, [playing, speed]);

  const data = useMemo(
    () => headline.map((r) => ({
      block: r.block,
      A: r.block <= frame ? r.nav[0] : null, B: r.block <= frame ? r.nav[1] : null, C: r.block <= frame ? r.nav[2] : null,
      rA: r.block <= frame ? r.ratio[0] * 100 : null, rB: r.block <= frame ? Math.min(100, r.ratio[1] * 100) : null,
      rC: r.block <= frame ? r.ratio[2] * 100 : null,
    })),
    [frame],
  );
  const row = headline[frame];
  const lossVsA = (i: number) => row.nav[0] - row.nav[i];
  const roundsSoFar = (run: "B" | "C") => ROUNDS[run].filter((b) => b <= frame).length;

  const sw = useMemo(() => {
    const frozen = sweep.filter((r) => r.cBlocksToFrozen > 0).length;
    const honestNeverRestricted = sweep.every((r) => r.aMinRatio >= 0.5);
    const mB = median(sweep.map((r) => r.profitB));
    const mC = median(sweep.map((r) => r.profitC));
    const freezeMin = Math.min(...sweep.map((r) => r.cBlocksToFrozen));
    const freezeMax = Math.max(...sweep.map((r) => r.cBlocksToFrozen));
    const minA = Math.min(...sweep.map((r) => r.aMinRatio));
    const bars = [...sweep].sort((a, b) => a.lossB - b.lossB).map((r) => ({
      seed: `#${r.seed}`, B: Math.round(r.lossB), C: Math.round(r.lossC), freeze: r.cBlocksToFrozen,
    }));
    return { frozen, honestNeverRestricted, mB, mC, cut: 1 - mC / mB, freezeMin, freezeMax, minA, bars, n: sweep.length };
  }, []);
  const honestHeadline = headline.every((r) => r.tier[0] === 0);

  const markers = (
    <>
      <ReferenceLine x={POISON_AT} stroke="#f87171" strokeDasharray="4 3" label={{ value: "poisoned", fill: "#f87171", fontSize: 11, position: "insideTopLeft" }} />
      {C_RESTRICTED !== null && <ReferenceLine x={C_RESTRICTED} stroke="var(--color-restricted)" strokeDasharray="2 3" />}
      {C_FROZEN !== null && (
        <ReferenceLine x={C_FROZEN} stroke="var(--color-frozen)" label={{ value: "C frozen", fill: "#38bdf8", fontSize: 11, position: "insideTopRight" }} />
      )}
      {ROUNDS.C.map((b) => <ReferenceLine key={`c${b}`} x={b} stroke="var(--color-runC)" strokeOpacity={0.35} />)}
    </>
  );

  return (
    <Section id="replay" kicker="2 · Replay of the Solidity scenario" title="Same attack, with and without Tenure">
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Poisoned curator FROZEN" value={`${sw.frozen} / ${sw.n} seeds`} sub={`${sw.freezeMin}-${sw.freezeMax} blocks after poisoning`} color="var(--color-frozen)" />
        <Stat
          label="Honest curator restricted"
          value={sw.honestNeverRestricted && honestHeadline ? "never" : "yes"}
          sub={`lowest budget seen: ${fmtPct(sw.minA)} (FULL needs 50%)`} color="var(--color-full)"
        />
        <Stat label="Attacker profit (median)" value={`−${(sw.cut * 100).toFixed(0)}%`} sub={`${fmtTok(sw.mB)} → ${fmtTok(sw.mC)} tokens`} color="var(--color-runC)" />
        <Stat label="Attack rounds (headline seed)" value={`${ROUNDS.B.length} → ${ROUNDS.C.length}`} sub="static caps vs Tenure" />
      </div>

      <Card>
        <div className="flex flex-wrap items-center gap-3">
          <button
            className="rounded-md bg-runC/20 px-4 py-1.5 text-sm font-medium text-runC ring-1 ring-runC/40"
            onClick={() => {
              if (frame >= LAST) setFrame(0);
              setPlaying((p) => !p);
            }}
          >
            {playing ? "Pause" : frame >= LAST ? "Replay" : "Play"}
          </button>
          <input
            type="range" className="min-w-40 flex-1" min={0} max={LAST} value={frame} aria-label="Block"
            onChange={(e) => {
              setPlaying(false);
              setFrame(Number(e.target.value));
            }}
          />
          <span className="num w-24 text-sm">block {frame}</span>
          <select className="rounded-md border border-line bg-ink px-2 py-1 text-sm" value={speed} onChange={(e) => setSpeed(Number(e.target.value))} aria-label="Speed">
            <option value={1}>1×</option>
            <option value={4}>4×</option>
            <option value={10}>10×</option>
          </select>
        </div>
        <div className="mt-4 grid gap-3 sm:grid-cols-3">
          {RUNS.map((run, i) => (
            <div key={run} className="rounded-lg border border-line bg-panel2 p-3">
              <div className="flex items-center justify-between gap-2">
                <span className="text-sm font-medium" style={{ color: RUN_COLORS[run] }}>{RUN_LABELS[run]}</span>
                <TierBadge tier={row.tier[i]} />
              </div>
              <div className="num mt-2 text-sm text-mute">
                NAV {fmtTok(row.nav[i])}
                {i > 0 && <> · vs A {lossVsA(i) >= 0 ? "−" : "+"}{fmtTok(Math.abs(lossVsA(i)))}</>}
                {run !== "A" && <> · rounds {roundsSoFar(run)}</>}
              </div>
            </div>
          ))}
        </div>

        <h3 className="mt-6 text-sm font-semibold">Vault NAV at the fair price (tokens)</h3>
        <div className="h-64">
          <ResponsiveContainer>
            <LineChart data={data} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
              <CartesianGrid stroke="#263049" strokeDasharray="3 3" />
              <XAxis dataKey="block" type="number" domain={[0, LAST]} tick={AXIS} />
              <YAxis tick={AXIS} domain={["auto", "auto"]} width={60} tickFormatter={(v) => fmtTok(v)} />
              <Tooltip {...TIP} formatter={(v: number) => fmtTok(v)} />
              {markers}
              {RUNS.map((r) => <Line key={r} dataKey={r} name={RUN_LABELS[r]} stroke={RUN_COLORS[r]} dot={false} strokeWidth={2} isAnimationActive={false} />)}
            </LineChart>
          </ResponsiveContainer>
        </div>
        <h3 className="mt-4 text-sm font-semibold">Risk budget, % of bucket (run B's bucket is 100% of NAV, so it never binds)</h3>
        <div className="h-48">
          <ResponsiveContainer>
            <LineChart data={data} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
              <CartesianGrid stroke="#263049" strokeDasharray="3 3" />
              <XAxis dataKey="block" type="number" domain={[0, LAST]} tick={AXIS} />
              <YAxis tick={AXIS} domain={[0, 100]} width={60} tickFormatter={(v) => `${v}%`} />
              <Tooltip {...TIP} formatter={(v: number) => `${v.toFixed(1)}%`} />
              <ReferenceLine y={50} stroke="var(--color-full)" strokeDasharray="4 4" />
              <ReferenceLine y={20} stroke="var(--color-frozen)" strokeDasharray="4 4" />
              {markers}
              <Line dataKey="rA" name="A" stroke={RUN_COLORS.A} dot={false} strokeWidth={2} isAnimationActive={false} />
              <Line dataKey="rB" name="B" stroke={RUN_COLORS.B} dot={false} strokeWidth={2} isAnimationActive={false} />
              <Line dataKey="rC" name="C" stroke={RUN_COLORS.C} dot={false} strokeWidth={2} isAnimationActive={false} />
            </LineChart>
          </ResponsiveContainer>
        </div>
        <p className="mt-2 text-xs text-mute">
          Red dashed: curator poisoned (block {POISON_AT}). Faint violet: C's attack rounds; amber dotted: C enters
          RESTRICTED (block {C_RESTRICTED}); blue: C FROZEN (block {C_FROZEN}), after which the owner pulls liquidity
          to idle. Budget thresholds: 50% FULL, 20% FROZEN.
        </p>
        <Source>
          docs/results/headline.csv (test/scenario/Headline.t.sol, seed 0x7e2a, 600 blocks); attack rounds from
          docs/results/losses.csv (decisions leaking more than 0.01% of NAV at once, which reproduces the scenario's
          own counters: B 25, C 3).
        </Source>
      </Card>

      <Card>
        <h3 className="font-semibold">20 seeds: value lost vs the honest run (tokens), sorted by B</h3>
        <div className="mt-2 h-64">
          <ResponsiveContainer>
            <BarChart data={sw.bars} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
              <CartesianGrid stroke="#263049" strokeDasharray="3 3" />
              <XAxis dataKey="seed" tick={AXIS} interval={1} />
              <YAxis tick={AXIS} width={60} tickFormatter={(v) => fmtTok(v)} />
              <Tooltip {...TIP} formatter={(v: number) => fmtTok(v)} />
              <Legend wrapperStyle={{ fontSize: 12 }} />
              <Bar dataKey="B" name="B static caps" fill={RUN_COLORS.B} isAnimationActive={false} />
              <Bar dataKey="C" name="C Tenure" fill={RUN_COLORS.C} isAnimationActive={false} />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <h3 className="mt-4 text-sm font-semibold">Blocks from poisoning to FROZEN (run C)</h3>
        <div className="h-40">
          <ResponsiveContainer>
            <BarChart data={sw.bars} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
              <CartesianGrid stroke="#263049" strokeDasharray="3 3" />
              <XAxis dataKey="seed" tick={AXIS} interval={1} />
              <YAxis tick={AXIS} width={60} />
              <Tooltip {...TIP} />
              <Bar dataKey="freeze" name="blocks to FROZEN" fill="var(--color-frozen)" isAnimationActive={false} />
            </BarChart>
          </ResponsiveContainer>
        </div>
        <p className="mt-2 text-xs text-mute">
          "Loss vs honest" mixes attack damage with market divergence of the parked/idle positions (docs/RESULTS.md
          explains this); attacker profit is the cleaner damage measure.
        </p>
        <Source>docs/results/sweep.csv (test/scenario/Sweep.t.sol, seeds 0-19).</Source>
      </Card>
    </Section>
  );
}

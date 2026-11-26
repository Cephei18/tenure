import { useMemo, useState } from "react";
import { CartesianGrid, Legend, Line, LineChart, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";
import { DEFAULT_PARAMS, type BudgetParams } from "../math/budget";
import { POISON_AT, ROUND_LOSS_WAD, lossEvents, tokens } from "../lib/data";
import { rescore, staticCap } from "../lib/replay";
import { Card, RUN_COLORS, Section, Slider, Source, Stat, fmtTok } from "../components/ui";

const WAD = 10n ** 18n;
/** percent (float) -> WAD bigint, via integer basis points x100 so the BigInt math stays exact */
const pctToWad = (pct: number) => (BigInt(Math.round(pct * 10_000)) * WAD) / 1_000_000n;
const AXIS = { stroke: "#8a94ad", fontSize: 11 };

const B_EVENTS = lossEvents.filter((e) => e.run === "B");
const A_EVENTS = lossEvents.filter((e) => e.run === "A");
const DEFAULTS = { bMaxPct: 2, refillBlocks: 7200, fullPct: 50, restrictedPct: 20, capPct: 0.2 };
const roundLeaks = B_EVENTS.filter((e) => e.event === "RebalanceScored" && e.lossWad > ROUND_LOSS_WAD)
  .map((e) => Number(e.lossWad / 10n ** 10n) / 1e6)
  .sort((a, b) => a - b);
const roundLeakPct = roundLeaks[roundLeaks.length >> 1] ?? 0; // percent of NAV

export default function Playground() {
  const [bMaxPct, setBMax] = useState(DEFAULTS.bMaxPct);
  const [refillBlocks, setRefill] = useState(DEFAULTS.refillBlocks);
  const [fullPct, setFull] = useState(DEFAULTS.fullPct);
  const [restrictedPct, setRestricted] = useState(DEFAULTS.restrictedPct);
  const [capPct, setCap] = useState(DEFAULTS.capPct);

  const params: BudgetParams = useMemo(() => {
    const bMax0 = pctToWad(bMaxPct);
    return {
      ...DEFAULT_PARAMS,
      bMax0,
      bMaxCap: bMax0 > DEFAULT_PARAMS.bMaxCap ? bMax0 : DEFAULT_PARAMS.bMaxCap,
      refillRate: bMax0 / BigInt(refillBlocks),
      fullThreshold: pctToWad(fullPct),
      restrictedThreshold: pctToWad(Math.min(restrictedPct, fullPct)),
    };
  }, [bMaxPct, refillBlocks, fullPct, restrictedPct]);

  const mine = useMemo(() => rescore(B_EVENTS, params), [params]);
  const base = useMemo(() => rescore(B_EVENTS, DEFAULT_PARAMS), []);
  const honest = useMemo(() => rescore(A_EVENTS, params), [params]);
  const cap = useMemo(() => staticCap(B_EVENTS, pctToWad(capPct)), [capPct]);
  const unchecked = useMemo(() => B_EVENTS.reduce((s, e) => s + e.lossValue, 0n), []);
  const totalDecisions = B_EVENTS.filter((e) => e.event === "RebalanceScored").length;

  const chart = useMemo(() => {
    const byStep = new Map<number, { step: number; mine?: number; base?: number }>();
    for (const p of base.points) byStep.set(p.step, { step: p.step, base: p.ratio * 100 });
    for (const p of mine.points) byStep.set(p.step, { ...(byStep.get(p.step) ?? { step: p.step }), mine: p.ratio * 100 });
    return [...byStep.values()].filter((d) => d.step >= 0).sort((a, b) => a.step - b.step);
  }, [mine, base]);

  const after = (s: number | null) => (s === null ? "never" : `block ${s} (${s - POISON_AT} after poisoning)`);
  const isDefault = bMaxPct === DEFAULTS.bMaxPct && refillBlocks === DEFAULTS.refillBlocks && fullPct === DEFAULTS.fullPct && restrictedPct === DEFAULTS.restrictedPct;

  return (
    <Section id="playground" kicker="3 · Playground" title="Tune the risk budget against the real attack">
      <div className="rounded-lg border border-runC/40 bg-runC/10 p-3 text-sm">
        <strong>Real losses from the Solidity scenario, re-scored with your parameters.</strong> The stream is every
        scored decision of the poisoned curator in run B (static caps only, so nothing ever stopped it):{" "}
        {totalDecisions} decisions and their markouts, from docs/results/losses.csv. Your parameters are applied with an
        exact BigInt port of RiskBudget (refill, charge, credit, sticky FROZEN), the same code that reproduces the hook's
        own budget after every event.
      </div>

      <div className="grid gap-4 lg:grid-cols-[320px_1fr]">
        <Card className="space-y-4">
          <Slider label="Bucket size bMax (% of NAV)" value={bMaxPct} min={0.25} max={10} step={0.25} onChange={setBMax} fmt={(v) => `${v}%`} />
          <Slider label="Refill: empty to full in" value={refillBlocks} min={600} max={43200} step={600} onChange={setRefill} fmt={(v) => `${v.toLocaleString("en-US")} blocks`} />
          <Slider label="FULL at or above" value={fullPct} min={25} max={90} step={5} onChange={setFull} fmt={(v) => `${v}%`} />
          <Slider label="RESTRICTED at or above (else FROZEN)" value={restrictedPct} min={5} max={fullPct} step={5} onChange={setRestricted} fmt={(v) => `${v}%`} />
          <hr className="border-line" />
          <Slider label="Static per-action cap (comparison)" value={capPct} min={0.05} max={1} step={0.05} onChange={setCap} fmt={(v) => `${v.toFixed(2)}% of NAV`} />
          <button
            className="text-xs text-mute underline"
            onClick={() => {
              setBMax(DEFAULTS.bMaxPct); setRefill(DEFAULTS.refillBlocks); setFull(DEFAULTS.fullPct);
              setRestricted(DEFAULTS.restrictedPct); setCap(DEFAULTS.capPct);
            }}
          >
            Reset to the scenario's parameters
          </button>
        </Card>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Stat label="Poisoned curator FROZEN at" value={mine.frozenStep === null ? "never" : `block ${mine.frozenStep}`} sub={mine.frozenStep === null ? "the budget never ran out" : `${mine.frozenStep - POISON_AT} blocks after poisoning`} color="var(--color-frozen)" />
            <Stat label="Decisions it still made" value={`${mine.decisionsAllowed} / ${totalDecisions}`} />
            <Stat label="Losses charged (tokens)" value={fmtTok(tokens(mine.lossCharged))} sub={`unchecked: ${fmtTok(tokens(unchecked))}`} color="var(--color-runC)" />
            <Stat
              label="Honest curator (run A)"
              value={honest.restrictedStep === null ? "never restricted" : "restricted!"}
              sub={honest.restrictedStep === null ? "no false positive" : `at ${after(honest.restrictedStep)}: too tight`}
              color={honest.restrictedStep === null ? "var(--color-full)" : "var(--color-restricted)"}
            />
          </div>
          <Card>
            <h3 className="text-sm font-semibold">Budget, % of bucket: your parameters vs the scenario's</h3>
            <div className="mt-2 h-56">
              <ResponsiveContainer>
                <LineChart data={chart} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
                  <CartesianGrid stroke="#263049" strokeDasharray="3 3" />
                  <XAxis dataKey="step" type="number" domain={[0, 600]} tick={AXIS} />
                  <YAxis domain={[0, 100]} tick={AXIS} width={44} tickFormatter={(v) => `${v}%`} />
                  <Tooltip contentStyle={{ background: "#121826", border: "1px solid #263049", fontSize: 12 }} formatter={(v: number) => `${v.toFixed(1)}%`} labelFormatter={(l) => `block ${l}`} />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                  <ReferenceLine x={POISON_AT} stroke="#f87171" strokeDasharray="4 3" />
                  <ReferenceLine y={fullPct} stroke="var(--color-full)" strokeDasharray="4 4" />
                  <ReferenceLine y={restrictedPct} stroke="var(--color-frozen)" strokeDasharray="4 4" />
                  {!isDefault && <Line dataKey="base" name="scenario params" stroke="#8a94ad" dot={false} strokeDasharray="5 4" isAnimationActive={false} connectNulls />}
                  <Line dataKey="mine" name="your params" stroke={RUN_COLORS.C} dot={false} strokeWidth={2} type="stepAfter" isAnimationActive={false} connectNulls />
                </LineChart>
              </ResponsiveContainer>
            </div>
            <p className="mt-2 text-xs text-mute">
              Points are the scored events (immediate leakage and markouts). With the scenario's parameters this stream
              freezes at block {base.frozenStep}.
            </p>
          </Card>
          <Card>
            <h3 className="text-sm font-semibold">Against a static per-action cap of {capPct.toFixed(2)}% of NAV</h3>
            <p className="mt-1 text-sm text-mute">
              A static cap blocks any single decision losing more than the cap, with no memory. Here it blocks{" "}
              <span className="num text-text">{cap.decisionsBlocked}</span> of {totalDecisions} decisions and lets
              through <span className="num text-text">{fmtTok(tokens(cap.lossCharged))}</span> tokens of losses
              (Tenure with your parameters: <span className="num text-text">{fmtTok(tokens(mine.lossCharged))}</span>).
              Each attack round leaks about {roundLeakPct.toFixed(2)}% of NAV at once (median of the{" "}
              {roundLeaks.length} rounds) and the rest arrives later as markouts, so a cap loose enough for that lets
              the whole slow bleed through.
            </p>
          </Card>
        </div>
      </div>
      <Source>
        docs/results/losses.csv (test/scenario/LossesExport.t.sol). Counterfactual caveats: the decision sequence is
        held fixed; after the replay freezes, later decisions (and their markouts) are dropped; a real RESTRICTED tier
        would also double the curator's cooldown. Loss amounts are the hook's own charged values in token1 units.
      </Source>
    </Section>
  );
}

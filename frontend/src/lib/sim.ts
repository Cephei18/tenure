// Timeline model of the headline scenario for the Simulator: per-block state from docs/results/headline.csv and
// discrete events from docs/results/losses.csv. Pure functions, no invented values (tested in sim.test.ts).
import { POISON_AT, ROUND_LOSS_WAD, headline, lossEvents, tokens as toTokens, type ScoreEvent } from "./data";

export type RunKey = "A" | "B" | "C";
export const RUN_INDEX: Record<RunKey, number> = { A: 0, B: 1, C: 2 };
export const LAST_STEP = headline.length - 1;

export type SimEventKind = "poison" | "round" | "restricted" | "frozen";
export interface SimEvent {
  run: RunKey;
  step: number;
  kind: SimEventKind;
  round?: number; // 1-based attack round
  leakTokens?: number; // the round's immediate leakage, tokens (the hook's own charged value)
}

/** First block a run's recorded tier satisfies `pred` (headline.csv), or null. */
export function firstStep(run: RunKey, pred: (tier: number) => boolean): number | null {
  const i = RUN_INDEX[run];
  return headline.find((r) => pred(r.tier[i]))?.block ?? null;
}

/** Events of one run, in time order. Rounds: decisions leaking > 0.01% of NAV at once (reproduces 25 / 3). */
export function eventsFor(run: RunKey): SimEvent[] {
  const out: SimEvent[] = [];
  if (run !== "A") out.push({ run, step: POISON_AT, kind: "poison" });
  lossEvents
    .filter((e) => e.run === run && e.event === "RebalanceScored" && e.lossWad > ROUND_LOSS_WAD)
    .forEach((e, i) => out.push({ run, step: e.step, kind: "round", round: i + 1, leakTokens: toTokens(e.lossValue) }));
  const r = firstStep(run, (t) => t === 1);
  const f = firstStep(run, (t) => t === 2);
  if (r !== null) out.push({ run, step: r, kind: "restricted" });
  if (f !== null) out.push({ run, step: f, kind: "frozen" });
  return out.sort((a, b) => a.step - b.step || order(a.kind) - order(b.kind));
}
const order = (k: SimEventKind) => ["poison", "round", "restricted", "frozen"].indexOf(k);

const eventsOf = (run: RunKey) => lossEvents.filter((e: ScoreEvent) => e.run === run && e.event !== "init");

/** Loss value the hook charged to the curator up to and including `step` (token1 wei, BigInt exact). */
export function chargedUpTo(run: RunKey, step: number): bigint {
  return eventsOf(run).filter((e) => e.step <= step).reduce((s, e) => s + e.lossValue, 0n);
}

/** Recorded state of a run at a block. */
export function stateAt(run: RunKey, step: number) {
  const row = headline[Math.max(0, Math.min(LAST_STEP, step))];
  const i = RUN_INDEX[run];
  return { nav: row.nav[i], ratio: row.ratio[i], tier: row.tier[i], navA: row.nav[0] };
}

/** Plain-language toast text for an event (short, no invented numbers). */
export function toastText(e: SimEvent): string {
  switch (e.kind) {
    case "poison":
      return "Curator poisoned · every action still inside the mandate";
    case "round":
      return `Attack round ${e.round} · vault leaks ${e.leakTokens!.toFixed(1)} at once`;
    case "restricted":
      return "Budget below 50% · curator RESTRICTED";
    case "frozen":
      return "Budget below 20% · curator FROZEN";
  }
}

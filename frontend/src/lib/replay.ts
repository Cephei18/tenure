// Re-scores a recorded stream of scoring events (docs/results/losses.csv) with any RiskBudget params, using the
// exact BigInt port of RiskBudget. With the scenario's own params it reproduces the hook's emitted budget and tier
// after every event (lib/replay.test.ts).
import { FROZEN, charge, credit, initState, refill, type BudgetParams, type BudgetState } from "../math/budget";
import type { ScoreEvent } from "./data";

/** Apply one recorded event exactly as the hook does: refill at the event's block, then charge or credit. */
export function applyEvent(st: BudgetState, p: BudgetParams, e: ScoreEvent): BudgetState {
  st = refill(st, p, e.blockNumber);
  if (e.event === "RebalanceScored") return e.lossWad !== 0n ? charge(st, p, e.lossWad, e.lossValue) : st;
  // MarkoutSettled: alpha < 0 charges (lossValue = -alpha > 0), alpha >= 0 credits reputation only
  return e.lossValue > 0n ? charge(st, p, e.lossWad, e.lossValue) : credit(st, p, e.gainWad, e.gainValue);
}

export interface ReplayPoint {
  step: number;
  ratio: number; // budget / bMax (display)
  tier: number;
}

export interface ReplayResult {
  points: ReplayPoint[];
  frozenStep: number | null; // first step the tier is FROZEN
  restrictedStep: number | null;
  decisionsAllowed: number; // RebalanceScored events that still happen under these params
  lossCharged: bigint; // sum of loss values (token1 wei) of the events that still happen
  gainCredited: bigint;
}

/**
 * Counterfactual re-scoring. The decision sequence is held fixed (it is the recorded one); once the replay is
 * FROZEN, the curator can no longer act, so later RebalanceScored events (and the markouts of those records) are
 * dropped, while markouts of records made before the freeze still settle. RESTRICTED is reported but does not
 * reshape the sequence (in the hook it would also double the cooldown, i.e. slow the curator down further).
 */
export function rescore(events: ScoreEvent[], p: BudgetParams): ReplayResult {
  const init = events.find((e) => e.event === "init");
  if (!init) throw new Error("no init row");
  let st = initState(p, init.blockNumber);
  const points: ReplayPoint[] = [];
  let frozenStep: number | null = null;
  let restrictedStep: number | null = null;
  let decisionsAllowed = 0;
  let lossCharged = 0n;
  let gainCredited = 0n;
  const dropped = new Set<number>();
  for (const e of events) {
    if (e.event === "init") continue;
    if (e.event === "RebalanceScored" && st.tier === FROZEN) {
      dropped.add(e.recordId);
      continue;
    }
    if (e.event === "MarkoutSettled" && dropped.has(e.recordId)) continue;
    st = applyEvent(st, p, e);
    if (e.event === "RebalanceScored") decisionsAllowed++;
    lossCharged += e.lossValue;
    gainCredited += e.gainValue;
    if (st.tier === FROZEN && frozenStep === null) frozenStep = e.step;
    if (st.tier >= 1 && restrictedStep === null) restrictedStep = e.step;
    points.push({ step: e.step, ratio: Number((st.budget * 10n ** 6n) / st.bMax) / 1e6, tier: st.tier });
  }
  return { points, frozenStep, restrictedStep, decisionsAllowed, lossCharged, gainCredited };
}

/** A hypothetical static per-action cap: blocks any single decision whose immediate loss exceeds `capWad` of NAV
 *  (and its later markout), with no memory of earlier losses. */
export function staticCap(events: ScoreEvent[], capWad: bigint) {
  const blocked = new Set<number>();
  let lossCharged = 0n;
  let decisionsAllowed = 0;
  for (const e of events) {
    if (e.event === "RebalanceScored") {
      if (e.lossWad > capWad) {
        blocked.add(e.recordId);
        continue;
      }
      decisionsAllowed++;
    } else if (e.event !== "MarkoutSettled" || blocked.has(e.recordId)) continue;
    lossCharged += e.lossValue;
  }
  return { lossCharged, decisionsAllowed, decisionsBlocked: blocked.size };
}

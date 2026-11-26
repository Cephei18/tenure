// The Playground's engine must reproduce the hook itself: replaying the recorded events of runs A, B and C with
// the scenario's params gives the hook's emitted post-event budget, bMax and tier after EVERY event, exactly.
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { DEFAULT_PARAMS, initState, type BudgetParams } from "../math/budget";
import { applyEvent, rescore } from "./replay";
import { parseCsv, type ScoreEvent } from "./data";

// Load the CSV with node fs (vitest runs outside Vite's ?raw pipeline for this file's own reads).
const rows = parseCsv(readFileSync(new URL("../../../docs/results/losses.csv", import.meta.url), "utf8"));
const events: ScoreEvent[] = rows.map((r) => ({
  run: r.run as ScoreEvent["run"], step: Number(r.step), blockNumber: BigInt(r.blockNumber),
  event: r.event as ScoreEvent["event"], recordId: r.recordId === "" ? -1 : Number(r.recordId),
  lossWad: BigInt(r.lossWad), lossValue: BigInt(r.lossValue), gainWad: BigInt(r.gainWad),
  gainValue: BigInt(r.gainValue), budget: BigInt(r.budget), bMax: r.bMax === "" ? null : BigInt(r.bMax),
  tier: Number(r.tier),
}));

// Run B = the same hook with the budget set to 100% of NAV (HeadlineBase._vaultSettings, staticOnly).
const paramsFor = (run: string): BudgetParams =>
  run === "B" ? { ...DEFAULT_PARAMS, bMax0: 10n ** 18n, bMaxCap: 10n ** 18n } : DEFAULT_PARAMS;

describe("losses.csv replay == hook (bit for bit)", () => {
  for (const run of ["A", "B", "C"] as const) {
    it(`run ${run}: budget, bMax and tier after every event`, () => {
      const evs = events.filter((e) => e.run === run);
      const p = paramsFor(run);
      const init = evs[0];
      expect(init.event).toBe("init");
      let st = initState(p, init.blockNumber);
      expect(st.budget).toBe(init.budget);
      let n = 0;
      for (const e of evs.slice(1)) {
        st = applyEvent(st, p, e);
        expect({ step: e.step, budget: st.budget, tier: st.tier }).toEqual({ step: e.step, budget: e.budget, tier: e.tier });
        if (e.bMax !== null) expect(st.bMax).toBe(e.bMax);
        n++;
      }
      expect(n).toBeGreaterThan(5);
    });
  }

  it("re-scoring run C with its own params freezes where the scenario froze (step 170)", () => {
    const r = rescore(events.filter((e) => e.run === "C"), DEFAULT_PARAMS);
    expect(r.frozenStep).toBe(170);
    expect(r.restrictedStep).toBe(160);
  });

  it("attack-round rule reproduces the scenario's counters (B 25, C 3, A 0)", () => {
    const rounds = (run: string) =>
      events.filter((e) => e.run === run && e.event === "RebalanceScored" && e.lossWad > 10n ** 14n).length;
    expect([rounds("A"), rounds("B"), rounds("C")]).toEqual([0, 25, 3]);
  });
});

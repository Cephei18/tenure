// Simulator timeline and Tune-drawer re-scoring: every value traces back to the committed CSVs.
import { describe, expect, it } from "vitest";
import { DEFAULT_PARAMS, FROZEN } from "../math/budget";
import { lossEvents } from "./data";
import { chargedUpTo, eventsFor, firstStep, stateAt, toastText } from "./sim";
import { rescore, staticCap } from "./replay";

const B = lossEvents.filter((e) => e.run === "B");
const A = lossEvents.filter((e) => e.run === "A");
const withBMax = (pct: bigint) => ({ ...DEFAULT_PARAMS, bMax0: pct * 10n ** 14n, refillRate: (pct * 10n ** 14n) / 7200n });

describe("simulator timeline", () => {
  it("events match the scenario: C restricted 160, frozen 170, 3 rounds; B 25 rounds, never frozen; A nothing", () => {
    const c = eventsFor("C");
    expect(c.filter((e) => e.kind === "round").map((e) => e.step)).toEqual([100, 120, 140]);
    expect(c.find((e) => e.kind === "restricted")?.step).toBe(160);
    expect(c.find((e) => e.kind === "frozen")?.step).toBe(170);
    expect(eventsFor("B").filter((e) => e.kind === "round")).toHaveLength(25);
    expect(eventsFor("B").some((e) => e.kind === "frozen")).toBe(false);
    expect(eventsFor("A")).toEqual([]);
    expect(firstStep("A", (t) => t > 0)).toBeNull();
  });

  it("toasts quote the hook's own charged leakage", () => {
    const r1 = eventsFor("C").find((e) => e.kind === "round")!;
    const csvRow = lossEvents.find((e) => e.run === "C" && e.event === "RebalanceScored" && e.step === 100)!;
    expect(r1.leakTokens).toBeCloseTo(Number(csvRow.lossValue) / 1e18, 6);
    expect(toastText(r1)).toMatch(/^Attack round 1 · vault leaks \d+\.\d at once$/);
  });

  it("charged-loss counter is cumulative and stops growing for C after the freeze decisions are settled", () => {
    expect(chargedUpTo("C", 99)).toBeLessThan(chargedUpTo("C", 300));
    expect(chargedUpTo("C", 301)).toBe(chargedUpTo("C", 599)); // last C event is at step 200 (losses.csv)
    expect(chargedUpTo("B", 599)).toBeGreaterThan(chargedUpTo("C", 599) * 2n);
  });

  it("stateAt reads headline.csv", () => {
    expect(stateAt("C", 170).tier).toBe(FROZEN);
    expect(stateAt("A", 599).tier).toBe(0);
  });
});

describe("Tune Tenure re-scoring (real losses of run B)", () => {
  it("scenario defaults: freezes at block 170 after 9 of 52 decisions; honest run never restricted", () => {
    const r = rescore(B, DEFAULT_PARAMS);
    expect([r.frozenStep, r.decisionsAllowed]).toEqual([170, 9]);
    expect(B.filter((e) => e.event === "RebalanceScored")).toHaveLength(52);
    expect(rescore(A, DEFAULT_PARAMS).restrictedStep).toBeNull();
  });

  it("a bigger bucket never freezes earlier, and charges at least as much loss", () => {
    let prevStep = 0;
    let prevLoss = 0n;
    for (const pct of [50n, 100n, 200n, 400n, 800n]) { // 0.5% .. 8% of NAV
      const r = rescore(B, withBMax(pct));
      const step = r.frozenStep ?? Infinity;
      expect(step).toBeGreaterThanOrEqual(prevStep);
      expect(r.lossCharged).toBeGreaterThanOrEqual(prevLoss);
      prevStep = step;
      prevLoss = r.lossCharged;
    }
  });

  it("once frozen, no later decision is applied (only markouts of earlier records)", () => {
    const r = rescore(B, withBMax(50n));
    const frozenAt = r.frozenStep!;
    const decisions = B.filter((e) => e.event === "RebalanceScored");
    const before = decisions.filter((e) => e.step < frozenAt).length; // all of these happened
    const upTo = decisions.filter((e) => e.step <= frozenAt).length; // same-block ones only if emitted before
    expect(r.decisionsAllowed).toBeGreaterThanOrEqual(before);
    expect(r.decisionsAllowed).toBeLessThanOrEqual(upTo);
    expect(r.points.every((p) => p.step <= frozenAt || p.tier === FROZEN)).toBe(true); // sticky
    expect(r.points.at(-1)!.tier).toBe(FROZEN);
  });

  it("static cap: a huge cap blocks nothing and lets every loss through; a 0 cap blocks every leaking decision", () => {
    const all = B.reduce((s, e) => s + e.lossValue, 0n);
    expect(staticCap(B, 10n ** 18n)).toMatchObject({ decisionsBlocked: 0, lossCharged: all });
    const zero = staticCap(B, 0n);
    expect(zero.decisionsBlocked).toBe(B.filter((e) => e.event === "RebalanceScored" && e.lossWad > 0n).length);
  });
});

// Differential tests: the TypeScript ports must reproduce test/vectors/*.json EXACTLY, the same vectors the
// Solidity differential tests (test/diff/*) check. No tolerance anywhere.
import { readFileSync } from "node:fs";
import { describe, expect, it, afterAll } from "vitest";
import { holdings, nav, scoreLeakage, markoutAlpha, lossWad, gainWad, type Position } from "./position";
import {
  DEFAULT_PARAMS, charge, credit, depositCap, initState, refill, restore, type BudgetParams, type BudgetState,
} from "./budget";
import { chainlinkSqrtPriceX96, estimateFees, feeGrowthDelta, markoutAlphaFees } from "./extras";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
const load = (name: string): Any =>
  JSON.parse(readFileSync(new URL(`../../../test/vectors/${name}.json`, import.meta.url), "utf8"));
const B = (s: string) => BigInt(s);
const pos = (p: Any): Position => ({ tickLower: Number(p.tickLower), tickUpper: Number(p.tickUpper), liquidity: B(p.liquidity) });

const checked: Record<string, number> = {};
let customSeqs = 0; // budget sequences with their own params (not a vector count)
const count = (k: string) => (checked[k] = (checked[k] ?? 0) + 1);
afterAll(() => {
  const total = Object.values(checked).reduce((a, b) => a + b, 0);
  console.log(`vectors checked: ${JSON.stringify(checked)} total=${total}`);
});

describe("test/vectors (exact match with Solidity / sim/model.py)", () => {
  it("holdings.json", () => {
    const v = load("holdings");
    for (const c of v.cases) {
      const h = holdings(pos(c), B(c.idle0), B(c.idle1), B(c.sqrtPrice), c.roundUp);
      expect([h[0].toString(), h[1].toString()]).toEqual([c.amount0, c.amount1]);
      count("holdings");
    }
    expect(checked.holdings).toBe(v.count);
  });

  it("nav.json", () => {
    const v = load("nav");
    for (const c of v.cases) {
      expect(nav([B(c.amount0), B(c.amount1)], B(c.sqrtFair), c.roundUp).toString()).toBe(c.nav);
      count("nav");
    }
    expect(checked.nav).toBe(v.count);
  });

  it("leakage.json", () => {
    const v = load("leakage");
    for (const c of v.cases) {
      const [leak, navBefore] = scoreLeakage(pos(c.old), [B(c.idleOld0), B(c.idleOld1)], B(c.sqrtSpot), pos(c.new),
        [B(c.idleNew0), B(c.idleNew1)], B(c.sqrtSpotAfter), B(c.sqrtFair));
      expect([leak.toString(), navBefore.toString()]).toEqual([c.leakage, c.navBefore]);
      count("leakage");
    }
    expect(checked.leakage).toBe(v.count);
  });

  it("alpha.json", () => {
    const v = load("alpha");
    for (const c of v.cases) {
      const a = markoutAlpha(pos(c.old), [B(c.idleOld0), B(c.idleOld1)], pos(c.new), [B(c.idleNew0), B(c.idleNew1)],
        B(c.sqrtSpotT), B(c.sqrtFairT));
      expect(a.toString()).toBe(c.alpha);
      count("alpha");
    }
    expect(checked.alpha).toBe(v.count);
  });

  it("loss.json", () => {
    const v = load("loss");
    for (const c of v.cases) {
      expect([lossWad(B(c.value), B(c.navRef)).toString(), gainWad(B(c.value), B(c.navRef)).toString()])
        .toEqual([c.lossWad, c.gainWad]);
      count("loss");
    }
    expect(checked.loss).toBe(v.count);
  });

  it("budget.json (every op of every sequence: full state + deposit cap)", () => {
    const v = load("budget");
    for (const seq of v.cases) {
      // optional per-case params (tier-boundary cases with non-round thresholds); defaults otherwise
      const p: BudgetParams = seq.params
        ? (Object.fromEntries(Object.entries(seq.params).map(([k, x]) => [k, B(x as string)])) as unknown as BudgetParams)
        : DEFAULT_PARAMS;
      if (seq.params) customSeqs++;
      let st: BudgetState = initState(p, B(seq.startBlock));
      for (const op of seq.ops) {
        const blk = B(op.block);
        if (op.kind === "1") st = charge(refill(st, p, blk), p, B(op.a), B(op.b));
        else if (op.kind === "2") st = credit(refill(st, p, blk), p, B(op.a), B(op.b));
        else if (op.kind === "3") st = restore(st, p, blk);
        else st = refill(st, p, blk);
        expect({
          budget: st.budget.toString(), bMax: st.bMax.toString(), lastBlock: st.lastBlock.toString(),
          tier: String(st.tier), cumAlphaWad: st.cumAlphaWad.toString(), cumAlphaValue: st.cumAlphaValue.toString(),
          depositCap: depositCap(st, p).toString(),
        }).toEqual({
          budget: op.budget, bMax: op.bMax, lastBlock: op.lastBlock, tier: op.tier, cumAlphaWad: op.cumAlphaWad,
          cumAlphaValue: op.cumAlphaValue, depositCap: op.depositCap,
        });
        count("budget-ops");
      }
    }
    expect(checked["budget-ops"]).toBe(v.cases.reduce((n: number, s: Any) => n + s.ops.length, 0));
    expect(customSeqs).toBeGreaterThanOrEqual(2); // the non-round-threshold boundary sequences are present
  });

  it("fees.json (fee estimates and fee-aware alpha)", () => {
    const v = load("fees");
    for (const c of v.cases) {
      const old = pos(c.old), nw = pos(c.new);
      const dg: [bigint, bigint] = [feeGrowthDelta(B(c.gNow0), B(c.gThen0)), feeGrowthDelta(B(c.gNow1), B(c.gThen1))];
      const dOld: [bigint, bigint] = [feeGrowthDelta(B(c.oNow0), B(c.oThen0)), feeGrowthDelta(B(c.oNow1), B(c.oThen1))];
      const dNew: [bigint, bigint] = [feeGrowthDelta(B(c.nNow0), B(c.nThen0)), feeGrowthDelta(B(c.nNow1), B(c.nThen1))];
      const fCf = estimateFees(dOld, dg, old.liquidity, c.validOld, true);
      const fNew = estimateFees(dNew, dg, nw.liquidity, c.validNew, false);
      expect([fCf, fNew].flat().map(String)).toEqual([c.feesCf0, c.feesCf1, c.feesNew0, c.feesNew1]);
      const a = markoutAlphaFees(old, [B(c.idleOld0), B(c.idleOld1)], fCf, nw, [B(c.idleNew0), B(c.idleNew1)], fNew,
        B(c.sqrtSpotT), B(c.sqrtFairT));
      expect(a.toString()).toBe(c.alpha);
      count("fees");
    }
    expect(checked.fees).toBe(v.count);
  });

  it("chainlink.json (fair price, including the cases that must revert)", () => {
    const v = load("chainlink");
    for (const c of v.cases) {
      let got: string;
      try {
        got = chainlinkSqrtPriceX96(B(c.a0), c.fd0, B(c.a1), c.fd1, c.dec0, c.dec1).toString();
      } catch {
        got = "REVERT";
      }
      expect(got).toBe(c.ok ? c.sqrtPriceX96 : "REVERT");
      count("chainlink");
    }
    expect(checked.chainlink).toBe(v.count);
  });
});

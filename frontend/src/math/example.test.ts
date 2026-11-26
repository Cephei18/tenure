// "How grading works": the worked example behaves as the explanation says.
import { describe, expect, it } from "vitest";
import { OLD, rebalance } from "./example";
import { holdings, markoutAlpha, scoreLeakage, sqrtPriceAtTick } from "./position";

const leakOf = (lo: number, hi: number, poolTick: number, fairTick: number) => {
  const S = sqrtPriceAtTick(poolTick);
  const { nw, idle } = rebalance(lo, hi, S);
  return scoreLeakage(OLD, [0n, 0n], S, nw, idle, S, sqrtPriceAtTick(fairTick));
};

describe("worked example", () => {
  it("the starting vault is the headline scenario's: ~40,000 + 40,000 tokens at price 1", () => {
    const [a0, a1] = holdings(OLD, 0n, 0n, sqrtPriceAtTick(0), false);
    for (const a of [a0, a1]) expect(Number(a / 10n ** 18n)).toBeGreaterThanOrEqual(39_999);
  });

  it("pool at fair: the rebalance leaks only rounding dust (< 1e-9 of NAV), never in the curator's favour", () => {
    const [leak, navBefore] = leakOf(-1020, 180, 0, 0);
    expect(leak).toBeGreaterThanOrEqual(0n);
    expect(leak * 10n ** 9n).toBeLessThan(navBefore);
  });

  it("trading at a pushed pool price leaks real value, more the further the push", () => {
    const [l200] = leakOf(-1020, 180, -200, 0);
    const [l400] = leakOf(-1020, 180, -400, 0);
    expect(l200).toBeGreaterThan(10n ** 18n); // > 1 token
    expect(l400).toBeGreaterThan(l200);
  });

  it("default story: following a -400 push and the price returning gives negative alpha", () => {
    const S = sqrtPriceAtTick(-400);
    const { nw, idle } = rebalance(-1020, 180, S);
    const T = sqrtPriceAtTick(0);
    expect(markoutAlpha(OLD, [0n, 0n], nw, idle, T, T)).toBeLessThan(0n);
  });
});

describe("worked solution identities (what the Grading steps display)", () => {
  it("each substituted line equals its result exactly, in wei", async () => {
    const { nav, scoreLeakage, markoutAlpha, holdings, sqrtPriceAtTick: sp, lossWad } = await import("./position");
    for (const [poolTick, fairTick, laterTick] of [[-400, 0, 0], [0, 0, 240], [300, -200, 500]]) {
      const S = sp(poolTick), F = sp(fairTick), T = sp(laterTick);
      const { nw, idle } = rebalance(-1020, 180, S);
      const [leak, navBefore] = scoreLeakage(OLD, [0n, 0n], S, nw, idle, S, F);
      const navAfter = nav(holdings(nw, idle[0], idle[1], S, false), F, false);
      expect(leak).toBe(navBefore - navAfter); // step 2
      expect(navBefore).toBe(nav(holdings(OLD, 0n, 0n, S, true), F, true)); // step 1
      const alpha = markoutAlpha(OLD, [0n, 0n], nw, idle, T, T);
      const navNewT = nav(holdings(nw, idle[0], idle[1], T, false), T, false);
      const navOldT = nav(holdings(OLD, 0n, 0n, T, true), T, true);
      expect(alpha).toBe(navNewT - navOldT); // step 3
      expect(lossWad(leak, navBefore) + lossWad(-alpha, navBefore)).toBeGreaterThanOrEqual(0n); // step 4 sum
    }
  });
});

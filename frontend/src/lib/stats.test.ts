// The frontend, README.md and docs/RESULTS.md must quote the same sweep figures (one rounding rule: half up).
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { roundHalfUp, sweepStats } from "./stats";

const read = (p: string) => readFileSync(new URL(`../../../${p}`, import.meta.url), "utf8");
const fmt = (n: bigint) => Number(n).toLocaleString("en-US");

describe("sweep statistics", () => {
  const s = sweepStats(read("docs/results/sweep.csv"));

  it("round half up", () => {
    expect([roundHalfUp(5n, 2n), roundHalfUp(7n, 2n), roundHalfUp(4n, 3n), roundHalfUp(5n, 3n)]).toEqual([3n, 4n, 1n, 2n]);
  });

  it("exact medians (raw wei, including any .5) and rounded values", () => {
    expect(s.seeds).toBe(20);
    expect(s.exact.medianProfitBWei).toBe("1586986428681362438015");
    expect(s.exact.medianProfitCWei).toBe("650211858490743348921.5");
    expect([s.medianProfitB, s.medianProfitC, s.profitCutPct, s.medianGapBC]).toEqual([1587n, 650n, 59n, 2771n]);
  });

  it("README.md and docs/RESULTS.md quote exactly these figures", () => {
    const readme = read("README.md");
    const results = read("docs/RESULTS.md");
    expect(readme).toContain(`| Attacker profit (median of 20 seeds) | ${fmt(s.medianProfitB)} tokens | **${fmt(s.medianProfitC)} tokens (-${s.profitCutPct}%)** |`);
    expect(readme).toContain(`**${fmt(s.medianGapBC)} tokens`);
    expect(results).toContain(`| B: attacker profit (tokens) | ${fmt(s.medianProfitB)} |`);
    expect(results).toContain(`| C: attacker profit (tokens) | ${fmt(s.medianProfitC)} |`);
    expect(results).toContain(`cut attacker profit by ${s.profitCutPct}% (median)`);
    expect(results).toContain(`median ${fmt(s.medianGapBC)})`);
    for (const doc of [readme, results]) {
      expect(doc).not.toContain("1,586");
      expect(doc).not.toMatch(/about 60%/);
    }
  });
});

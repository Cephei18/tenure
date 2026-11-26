// Headline sweep statistics, computed EXACTLY from docs/results/sweep.csv (BigInt wei), then rounded with the one
// rule stated in docs/RESULTS.md: round half up (whole tokens; percentages to the shown digit).
import { parseCsv } from "./data";
import sweepCsv from "../../../docs/results/sweep.csv?raw";

const WEI = 10n ** 18n;

/** round(num / den) half up, for num >= 0, den > 0 */
export const roundHalfUp = (num: bigint, den: bigint) => (2n * num + den) / (2n * den);

/** Median of 20 (even count) as an exact fraction: (sum of the two middle values) / 2. Returns that SUM. */
function middleSum(values: bigint[]): bigint {
  const s = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const m = s.length >> 1;
  return s.length % 2 ? 2n * s[m] : s[m - 1] + s[m];
}

export function sweepStats(csv: string = sweepCsv) {
  const rows = parseCsv(csv);
  const col = (k: string) => rows.map((r) => BigInt(r[k]));
  const sB = middleSum(col("profitB")); // = 2 x median, in wei
  const sC = middleSum(col("profitC"));
  const gap = middleSum(rows.map((r) => BigInt(r.lossB) - BigInt(r.lossC)));
  return {
    seeds: rows.length,
    medianProfitB: roundHalfUp(sB, 2n * WEI), // whole tokens
    medianProfitC: roundHalfUp(sC, 2n * WEI),
    profitCutPct: roundHalfUp(100n * (sB - sC), sB), // 1 - medC/medB, whole percent
    medianGapBC: roundHalfUp(gap, 2n * WEI),
    exact: { medianProfitBWei: `${sB / 2n}${sB % 2n ? ".5" : ""}`, medianProfitCWei: `${sC / 2n}${sC % 2n ? ".5" : ""}` },
  };
}

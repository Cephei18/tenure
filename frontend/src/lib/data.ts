// Committed data, imported straight from the repo (no copies): docs/results/*.csv and deployments/*.json.
import headlineCsv from "../../../docs/results/headline.csv?raw";
import sweepCsv from "../../../docs/results/sweep.csv?raw";
import lossesCsv from "../../../docs/results/losses.csv?raw";
import unichain from "../../../deployments/1301.json";
import lasna from "../../../deployments/5318007.json";

export { unichain, lasna };

export function parseCsv(text: string): Record<string, string>[] {
  const lines = text.trim().split(/\r?\n/);
  const head = lines[0].split(",");
  return lines.slice(1).map((l) => {
    const cells = l.split(",");
    return Object.fromEntries(head.map((h, i) => [h, cells[i] ?? ""]));
  });
}

/** wei (18 decimals) -> tokens as a float, for DISPLAY only (all scoring stays in BigInt). */
export const tokens = (wei: bigint | string) => Number(BigInt(wei) / 10n ** 12n) / 1e6;
/** WAD -> fraction as a float, for display only. */
export const frac = (wad: bigint | string) => Number(BigInt(wad) / 10n ** 9n) / 1e9;

export interface HeadlineRow {
  block: number;
  nav: [number, number, number]; // A, B, C in tokens
  ratio: [number, number, number]; // budget / bMax
  tier: [number, number, number];
}
export const headline: HeadlineRow[] = parseCsv(headlineCsv).map((r) => ({
  block: Number(r.block),
  nav: [tokens(r.navA), tokens(r.navB), tokens(r.navC)],
  ratio: [frac(r.ratioA), frac(r.ratioB), frac(r.ratioC)],
  tier: [Number(r.tierA), Number(r.tierB), Number(r.tierC)],
}));

export interface SweepRow {
  seed: number;
  lossB: number;
  lossC: number;
  profitB: number;
  profitC: number;
  roundsB: number;
  roundsC: number;
  cBlocksToRestricted: number; // 0 = no RESTRICTED block was sampled (FULL -> FROZEN within one block)
  cBlocksToFrozen: number; // 0 = never frozen
  aMinRatio: number;
}
export const sweep: SweepRow[] = parseCsv(sweepCsv).map((r) => ({
  seed: Number(r.seed),
  lossB: tokens(r.lossB),
  lossC: tokens(r.lossC),
  profitB: tokens(r.profitB),
  profitC: tokens(r.profitC),
  roundsB: Number(r.roundsB),
  roundsC: Number(r.roundsC),
  cBlocksToRestricted: Number(r.cBlocksToRestricted),
  cBlocksToFrozen: Number(r.cBlocksToFrozen),
  aMinRatio: frac(r.aMinRatio),
}));

export type ScoreEvent = {
  run: "A" | "B" | "C";
  step: number; // headline.csv block index; -1 = first action before block 0; -2 = init row
  blockNumber: bigint;
  event: "init" | "RebalanceScored" | "MarkoutSettled";
  recordId: number;
  lossWad: bigint;
  lossValue: bigint;
  gainWad: bigint;
  gainValue: bigint;
  budget: bigint; // hook's post-event budget (WAD)
  bMax: bigint | null; // hook's post-event bMax (markouts and init only)
  tier: number; // hook's post-event tier
};
export const lossEvents: ScoreEvent[] = parseCsv(lossesCsv).map((r) => ({
  run: r.run as ScoreEvent["run"],
  step: Number(r.step),
  blockNumber: BigInt(r.blockNumber),
  event: r.event as ScoreEvent["event"],
  recordId: r.recordId === "" ? -1 : Number(r.recordId),
  lossWad: BigInt(r.lossWad),
  lossValue: BigInt(r.lossValue),
  gainWad: BigInt(r.gainWad),
  gainValue: BigInt(r.gainValue),
  budget: BigInt(r.budget),
  bMax: r.bMax === "" ? null : BigInt(r.bMax),
  tier: Number(r.tier),
}));

/** Headline scenario constant (test/scenario/Headline.t.sol POISON_AT). */
export const POISON_AT = 100;
/** Attack rounds = the follow-the-push legs: decisions whose immediate leakage exceeds 0.01% of NAV. This rule
 *  reproduces the scenario's own round counters exactly (B: 25, C: 3; checked in lib/replay.test.ts). */
export const ROUND_LOSS_WAD = 10n ** 14n;
export const attackRounds = (run: "A" | "B" | "C") =>
  lossEvents.filter((e) => e.run === run && e.event === "RebalanceScored" && e.lossWad > ROUND_LOSS_WAD).map((e) => e.step);

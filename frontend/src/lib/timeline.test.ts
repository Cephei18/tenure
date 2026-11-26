// No invented data: every live event hash and block shown in the UI must appear in the committed docs.
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { relayDelayBlocks, timeline, txUrl } from "../data/timeline";
import snapshot from "../data/live-snapshot.json";

const docs = ["docs/INCIDENT_REACTIVE.md", "docs/RESULTS.md", "README.md"]
  .map((p) => readFileSync(new URL(`../../../${p}`, import.meta.url), "utf8"))
  .join("\n");
const withCommas = (n: string) => Number(n).toLocaleString("en-US");

describe("timeline is sourced from the docs", () => {
  for (const e of timeline) {
    it(e.title, () => {
      expect(docs).toContain(e.tx);
      expect(docs.includes(e.block) || docs.includes(withCommas(e.block))).toBe(true);
    });
  }
  it("derived numbers shown in Live proof agree with the docs", () => {
    expect(relayDelayBlocks).toBe(2);
    expect(docs).toContain(`${relayDelayBlocks} Unichain blocks`);
  });

  it("every card has a one-line copy (<= 12 words) and a correct explorer link", () => {
    for (const e of timeline) {
      expect(e.short.split(/\s+/).length, e.title).toBeLessThanOrEqual(12);
      expect(txUrl(e)).toBe(`${e.chain === "Lasna" ? "https://lasna.reactscan.net" : "https://sepolia.uniscan.xyz"}/tx/${e.tx}`);
      expect(e.tx).toMatch(/^0x[0-9a-f]{64}$/);
    }
  });

  it("snapshot is a real read of chain 1301", () => {
    expect(snapshot.chainId).toBe(1301);
    expect(Number(snapshot.blockNumber)).toBeGreaterThan(68844903); // after the withdrawal it reflects
  });
});

import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { DEMO_STEPS, DEMO_TOTAL_MS } from "./demoScript";
import { sweepStats } from "../lib/stats";
import { eventsFor } from "../lib/sim";
import { relayDelayBlocks } from "../data/timeline";

const src = ["Hero.tsx", "Simulator.tsx", "LiveProof.tsx", "Grading.tsx"]
  .map((f) => readFileSync(new URL(`./${f}`, import.meta.url), "utf8")).join("\n");

describe("demo script", () => {
  it("runs 60-90 s with short captions", () => {
    expect(DEMO_TOTAL_MS).toBeGreaterThanOrEqual(60_000);
    expect(DEMO_TOTAL_MS).toBeLessThanOrEqual(90_000);
    for (const s of DEMO_STEPS) expect(s.caption.split(/\s+/).length, s.caption).toBeLessThanOrEqual(16);
  });

  it("every spotlight target exists in the page", () => {
    for (const s of DEMO_STEPS) expect(src, s.target).toMatch(new RegExp(`id(=|: )"?${s.target}"?|id=\\{?"${s.target}"`));
  });

  it("captions land on their events at the demo's playback speed (0.25x = 5 blocks/s from block 90)", () => {
    const startAt = DEMO_STEPS.slice(0, 1).reduce((s, x) => s + x.ms, 0); // run starts with step 2
    const atStep = (i: number) => DEMO_STEPS.slice(0, i).reduce((s, x) => s + x.ms, 0) - startAt; // ms after start
    const blockAt = (ms: number) => 90 + (ms / 1000) * 5;
    const c = eventsFor("C");
    const frozen = c.find((e) => e.kind === "frozen")!.step;
    const firstRound = c.find((e) => e.kind === "round")!.step;
    // the "each round leaks" caption is on screen while the first round happens
    expect(blockAt(atStep(1))).toBeLessThanOrEqual(firstRound);
    // the "RESTRICTED, then FROZEN" caption (step index 3) is on screen when C freezes
    expect(blockAt(atStep(3))).toBeLessThanOrEqual(frozen);
    expect(blockAt(atStep(4))).toBeGreaterThanOrEqual(frozen);
  });

  it("the numbers in captions come from the data", () => {
    const text = DEMO_STEPS.map((s) => s.caption).join(" ");
    const rounds = (r: "B" | "C") => eventsFor(r).filter((e) => e.kind === "round").length;
    expect(text).toContain(`${rounds("B")} attack rounds instead of ${rounds("C")}`);
    expect(text).toContain(`${sweepStats().seeds} random markets`);
    expect(text).toContain(`${relayDelayBlocks} blocks later`);
  });
});

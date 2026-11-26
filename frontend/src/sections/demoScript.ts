// The scripted demo tour (pure data, tested in demoScript.test.ts: 60-90 s, short captions, valid targets).
import { emit } from "../lib/bus";

export interface DemoStep {
  target: string; // element id to spotlight and scroll to
  caption: string; // <= 16 words
  ms: number;
  run?: () => void; // side effect when the step starts
}

export const DEMO_STEPS: DemoStep[] = [
  { target: "overview", ms: 7000, caption: "AI curators manage depositors' liquidity. Tenure grades every decision they make." },
  {
    target: "sim-player", ms: 7000, caption: "Same market, two vaults: static caps (amber) versus Tenure (pink).",
    // 0.25x = 5 blocks/s from block 90: rounds ~2, 6, 10 s in; RESTRICTED ~14 s; FROZEN ~16 s (captions below)
    run: () => emit("sim:run", { mode: "compare", speed: 0.25, from: 90 }),
  },
  { target: "sim-player", ms: 7000, caption: "The poisoned curator follows the attacker's price push. Each round leaks value." },
  { target: "sim-player", ms: 7000, caption: "Tenure charges every loss to a budget: RESTRICTED, then FROZEN. The attack stops." },
  {
    target: "sim-player", ms: 8000, caption: "Static caps never react: 25 attack rounds instead of 3.",
    run: () => emit("sim:speed", { speed: 4 }),
  },
  {
    target: "sweep", ms: 8000, caption: "Across 20 random markets: frozen every time, honest curator never restricted.",
    run: () => emit("sim:pause"),
  },
  {
    target: "live-steps", ms: 9000, caption: "It ran on Unichain Sepolia: the deployed hook froze the curator.",
    run: () => emit("live:scrollTo", { index: 4 }),
  },
  {
    target: "live-steps", ms: 8000, caption: "Reactive Network relayed the freeze to the curator's other vault, 2 blocks later.",
    run: () => emit("live:scrollTo", { index: 6 }),
  },
  {
    target: "live-steps", ms: 7000, caption: "Depositors still withdrew everything while the curator was FROZEN.",
    run: () => emit("live:scrollTo", { index: 7 }),
  },
  { target: "grading", ms: 9000, caption: "Grading: value leaked at the trade, then a markout against doing nothing." },
  { target: "overview", ms: 5000, caption: "Don't just detect the compromise. Measure the damage." },
];

export const DEMO_TOTAL_MS = DEMO_STEPS.reduce((s, x) => s + x.ms, 0);

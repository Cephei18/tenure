// tenure-math sections 6-7: leaky-bucket risk budget, autonomy tiers, reputation. Exact port of sim/model.py
// (BudgetParams / refill / charge / credit / restore), which src/libraries/RiskBudget.sol matches bit for bit.
import { WAD, min, mulDiv } from "./fixed";

export const FULL = 0;
export const RESTRICTED = 1;
export const FROZEN = 2;
export const TIER_NAMES = ["FULL", "RESTRICTED", "FROZEN"] as const;

export interface BudgetParams {
  bMax0: bigint;
  bMaxCap: bigint;
  refillRate: bigint; // WAD per block
  fullThreshold: bigint;
  restrictedThreshold: bigint;
  restoreWad: bigint;
  k: bigint;
  cap0: bigint;
  capMax: bigint;
  m: bigint;
}

/** The defaults: equal to sim/model.py BudgetParams() and test/utils/TenureDefaults.sol. */
export const DEFAULT_PARAMS: BudgetParams = {
  bMax0: 2n * 10n ** 16n,
  bMaxCap: 10n * 10n ** 16n,
  refillRate: (2n * 10n ** 16n) / 7200n,
  fullThreshold: 5n * 10n ** 17n,
  restrictedThreshold: 2n * 10n ** 17n,
  restoreWad: 35n * 10n ** 16n,
  k: 5n * 10n ** 17n,
  cap0: 100_000n * WAD,
  capMax: 10_000_000n * WAD,
  m: 50n * WAD,
};

export interface BudgetState {
  budget: bigint;
  bMax: bigint;
  lastBlock: bigint;
  tier: number;
  cumAlphaWad: bigint;
  cumAlphaValue: bigint;
}

export function initState(p: BudgetParams, block: bigint): BudgetState {
  return { budget: p.bMax0, bMax: p.bMax0, lastBlock: block, tier: FULL, cumAlphaWad: 0n, cumAlphaValue: 0n };
}

export function tierFor(budget: bigint, bMax: bigint, p: BudgetParams): number {
  const ratio = (budget * WAD) / bMax; // floor
  if (ratio >= p.fullThreshold) return FULL;
  if (ratio >= p.restrictedThreshold) return RESTRICTED;
  return FROZEN;
}

export const bMaxFor = (cumAlphaWad: bigint, p: BudgetParams) => min(p.bMaxCap, p.bMax0 + mulDiv(p.k, cumAlphaWad, WAD));

export const depositCap = (s: BudgetState, p: BudgetParams) => min(p.capMax, p.cap0 + mulDiv(p.m, s.cumAlphaValue, WAD));

/** Time-based refill, floor. FROZEN is sticky: no refill while frozen. */
export function refill(s: BudgetState, p: BudgetParams, block: bigint): BudgetState {
  if (block <= s.lastBlock) return s;
  if (s.tier === FROZEN) return { ...s, lastBlock: block };
  const budget = min(s.bMax, s.budget + p.refillRate * (block - s.lastBlock));
  return { ...s, budget, lastBlock: block, tier: tierFor(budget, s.bMax, p) };
}

const satSub = (a: bigint, b: bigint) => (a > b ? a - b : 0n);

/** Charge a loss: decay reputation first, then drain the budget (floor at 0). FROZEN stays FROZEN. */
export function charge(s: BudgetState, p: BudgetParams, lossW: bigint, lossValue: bigint): BudgetState {
  const cumAlphaWad = satSub(s.cumAlphaWad, lossW);
  const cumAlphaValue = satSub(s.cumAlphaValue, lossValue);
  const bMax = bMaxFor(cumAlphaWad, p);
  const budget = satSub(min(s.budget, bMax), lossW);
  const tier = s.tier === FROZEN ? FROZEN : tierFor(budget, bMax, p);
  return { ...s, budget, bMax, tier, cumAlphaWad, cumAlphaValue };
}

/** Positive alpha grows reputation (bMax, deposit cap) but never refills spent budget or changes the tier. */
export function credit(s: BudgetState, p: BudgetParams, gainW: bigint, gainValue: bigint): BudgetState {
  const cumAlphaWad = s.cumAlphaWad + gainW;
  const cumAlphaValue = s.cumAlphaValue + gainValue;
  const bMax = bMaxFor(cumAlphaWad, p);
  if (s.tier === FROZEN) return { ...s, bMax, cumAlphaWad, cumAlphaValue };
  const budget = mulDiv(s.budget, bMax, s.bMax); // floor: curator-adverse
  return { ...s, budget, bMax, cumAlphaWad, cumAlphaValue };
}

/** Guardian restore from FROZEN: lands in RESTRICTED (autonomy is re-earned). */
export function restore(s: BudgetState, p: BudgetParams, block: bigint): BudgetState {
  const budget = mulDiv(s.bMax, p.restoreWad, WAD);
  return { ...s, budget, lastBlock: block, tier: tierFor(budget, s.bMax, p) };
}

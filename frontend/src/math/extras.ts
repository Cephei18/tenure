// M3.3 fee-aware markout and M4.6 Chainlink fair price: exact ports of sim/model.py (not used by the UI's main
// views, but ported and vector-checked so every vector file of the Solidity differential tests is covered).
import { Q128, U256, UINT256_MAX, mulDiv, mulDivUp } from "./fixed";
import { markoutAlpha, type Pair, type Position } from "./position";

/** v4 fee growth deltas wrap mod 2^256 (Solidity unchecked). */
export const feeGrowthDelta = (now: bigint, then: bigint) => (((now - then) % U256) + U256) % U256;

export function feeAmounts(d0: bigint, d1: bigint, liq: bigint, roundUp: boolean): Pair {
  const f = roundUp ? mulDivUp : mulDiv;
  return [f(d0, liq, Q128), f(d1, liq, Q128)];
}

/** Fees a hypothetical position earned; curator-adverse fallback when fee-growth-inside is untrustworthy. */
export function estimateFees(dInside: Pair, dGlobal: Pair, liq: bigint, insideValid: boolean, counterfactual: boolean): Pair {
  if (liq === 0n) return [0n, 0n];
  const ok = insideValid && dInside[0] <= dGlobal[0] && dInside[1] <= dGlobal[1];
  if (counterfactual) return ok ? feeAmounts(dInside[0], dInside[1], liq, true) : feeAmounts(dGlobal[0], dGlobal[1], liq, true);
  return ok ? feeAmounts(dInside[0], dInside[1], liq, false) : [0n, 0n];
}

export function markoutAlphaFees(
  old: Position, idleOld: Pair, feesCf: Pair, nw: Position, idleNew: Pair, feesNew: Pair, sT: bigint, sFairT: bigint,
): bigint {
  const noop = old.tickLower === nw.tickLower && old.tickUpper === nw.tickUpper && old.liquidity === nw.liquidity &&
    idleOld[0] === idleNew[0] && idleOld[1] === idleNew[1];
  if (noop) return 0n;
  return markoutAlpha(old, [idleOld[0] + feesCf[0], idleOld[1] + feesCf[1]], nw,
    [idleNew[0] + feesNew[0], idleNew[1] + feesNew[1]], sT, sFairT);
}

const MIN_SQRT_PRICE = 4295128739n;
const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;
const TWO_64 = 1n << 64n;

/** floor(sqrt(x)) (Newton). */
export function isqrt(x: bigint): bigint {
  if (x < 0n) throw new Error("isqrt of negative");
  if (x < 2n) return x;
  let r = 1n << BigInt(Math.ceil(x.toString(2).length / 2));
  for (;;) {
    const n = (r + x / r) >> 1n;
    if (n >= r) return r;
    r = n;
  }
}

/** Fair sqrtPriceX96 from two Chainlink answers (or one direct feed: a1 = 1, fd1 = 0). Throws where Solidity reverts. */
export function chainlinkSqrtPriceX96(a0: bigint, fd0: number, a1: bigint, fd1: number, dec0: number, dec1: number): bigint {
  if (a0 <= 0n || a1 <= 0n) throw new Error("non-positive answer");
  const e = fd1 + dec1 - fd0 - dec0;
  const [num, den] = e >= 0 ? [a0 * 10n ** BigInt(e), a1] : [a0, a1 * 10n ** BigInt(-e)];
  if (num > UINT256_MAX || den > UINT256_MAX) throw new Error("scale overflow");
  const s = num / den < TWO_64 ? isqrt(mulDiv(num, 1n << 192n, den)) : isqrt(mulDiv(num, 1n << 128n, den)) << 32n;
  if (s < MIN_SQRT_PRICE || s >= MAX_SQRT_PRICE) throw new Error("price out of range");
  return s;
}

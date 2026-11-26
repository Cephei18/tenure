// Sizing helpers for the Math view only (not part of Tenure's scoring): v4-periphery LiquidityAmounts (floor) and an
// idealized swap at the pool's spot price (no fee, no price impact). Scoring itself uses position.ts.
import { Q96, min, mulDiv } from "./fixed";

const l0 = (sa: bigint, sb: bigint, a0: bigint) => mulDiv(a0, mulDiv(sa, sb, Q96), sb - sa);
const l1 = (sa: bigint, sb: bigint, a1: bigint) => mulDiv(a1, Q96, sb - sa);

/** LiquidityAmounts.getLiquidityForAmounts: the most liquidity (amount0, amount1) can fund at sqrt price s. */
export function liquidityForAmounts(s: bigint, sa: bigint, sb: bigint, a0: bigint, a1: bigint): bigint {
  if (sa > sb) [sa, sb] = [sb, sa];
  if (s <= sa) return l0(sa, sb, a0);
  if (s < sb) return min(l0(s, sb, a0), l1(sa, s, a1));
  return l1(sa, sb, a1);
}

/** token0 -> token1 at sqrt price s (floor): x * (s/Q96)^2 */
export const sell0At = (x0: bigint, s: bigint) => mulDiv(mulDiv(x0, s, Q96), s, Q96);
/** token1 -> token0 at sqrt price s (floor): y / (s/Q96)^2 */
export const sell1At = (y1: bigint, s: bigint) => mulDiv(mulDiv(y1, Q96, s), Q96, s);

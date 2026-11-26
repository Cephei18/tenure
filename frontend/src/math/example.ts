// The worked example of "How grading works": the headline vault and a curator rebalance at the pool price.
// Example construction only (sizing + an idealized swap at spot); the SCORING uses position.ts.
import { Q96 } from "./fixed";
import { holdings, sqrtPriceAtTick, type Pair, type Position } from "./position";
import { liquidityForAmounts, sell0At, sell1At } from "./liquidity";

const E18 = 10n ** 18n;

// The vault before the decision: 40,000 + 40,000 tokens in a +-600 tick range at price 1 (the headline scenario).
export const OLD: Position = (() => {
  const L = liquidityForAmounts(sqrtPriceAtTick(0), sqrtPriceAtTick(-600), sqrtPriceAtTick(600), 40_000n * E18, 40_000n * E18);
  return { tickLower: -600, tickUpper: 600, liquidity: L };
})();

/** The rebalance: take the old position out at pool spot S, swap at S into the new range's token mix, add it. */
export function rebalance(nwLo: number, nwHi: number, S: bigint) {
  let [a0, a1] = holdings(OLD, 0n, 0n, S, false);
  const unit = holdings({ tickLower: nwLo, tickUpper: nwHi, liquidity: E18 }, 0n, 0n, S, false); // token mix per unit L
  // x token0 to sell so that (a0 - x) : (a1 + x*P) = u0 : u1, with P = (S/Q96)^2 (negative x = buy token0)
  const Q192 = Q96 * Q96;
  const num = (a0 * unit[1] - a1 * unit[0]) * Q192;
  const den = unit[1] * Q192 + S * S * unit[0];
  const x = den === 0n ? 0n : num / den;
  if (x > 0n) {
    a0 -= x;
    a1 += sell0At(x, S);
  } else if (x < 0n) {
    const y = sell0At(-x, S); // token1 spent to buy -x token0 at S
    const y1 = y > a1 ? a1 : y;
    a1 -= y1;
    a0 += sell1At(y1, S);
  }
  const nw: Position = {
    tickLower: nwLo, tickUpper: nwHi,
    liquidity: liquidityForAmounts(S, sqrtPriceAtTick(nwLo), sqrtPriceAtTick(nwHi), a0, a1),
  };
  const used = holdings(nw, 0n, 0n, S, true);
  const idle: Pair = [a0 > used[0] ? a0 - used[0] : 0n, a1 > used[1] ? a1 - used[1] : 0n];
  return { nw, idle, swapped0: x };
}


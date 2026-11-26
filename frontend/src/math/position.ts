// tenure-math sections 1-5: tick math, position holdings, NAV at the FAIR price, immediate leakage, markout alpha,
// loss/gain fractions. Exact port of sim/model.py's integer layer (which Solidity matches bit for bit).
import { Q96, UINT256_MAX, WAD, divUp, mulDiv, mulDivUp } from "./fixed";

export const MIN_TICK = -887272;
export const MAX_TICK = 887272;

const TICK_CONSTS: [number, bigint][] = [
  [0x2, 0xfff97272373d413259a46990580e213an],
  [0x4, 0xfff2e50f5f656932ef12357cf3c7fdccn],
  [0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
  [0x10, 0xffcb9843d60f6159c9db58835c926644n],
  [0x20, 0xff973b41fa98c081472e6896dfb254c0n],
  [0x40, 0xff2ea16466c96a3843ec78b326b52861n],
  [0x80, 0xfe5dee046a99a2a811c461f1969c3053n],
  [0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
  [0x200, 0xf987a7253ac413176f2b074cf7815e54n],
  [0x400, 0xf3392b0822b70005940c7a398e4b70f3n],
  [0x800, 0xe7159475a2c29b7443b29c7fa6e889d9n],
  [0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825n],
  [0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5n],
  [0x4000, 0x70d869a156d2a1b890bb3df62baf32f7n],
  [0x8000, 0x31be135f97d08fd981231505542fcfa6n],
  [0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
  [0x20000, 0x5d6af8dedb81196699c329225ee604n],
  [0x40000, 0x2216e584f5fa1ea926041bedfe98n],
  [0x80000, 0x48a170391f7dc42444e8fa2n],
];

/** TickMath.getSqrtPriceAtTick (exact). */
export function sqrtPriceAtTick(tick: number): bigint {
  const absTick = Math.abs(tick);
  if (!Number.isInteger(tick) || absTick > MAX_TICK) throw new Error("InvalidTick");
  let price = absTick & 0x1 ? 0xfffcb933bd6fad37aa2d162d1a594001n : 1n << 128n;
  for (const [bit, c] of TICK_CONSTS) if (absTick & bit) price = (price * c) >> 128n;
  if (tick > 0) price = UINT256_MAX / price;
  return (price + (1n << 32n) - 1n) >> 32n;
}

/** SqrtPriceMath.getAmount0Delta. */
export function amount0Delta(sa: bigint, sb: bigint, liq: bigint, roundUp: boolean): bigint {
  if (sa > sb) [sa, sb] = [sb, sa];
  if (sa === 0n) throw new Error("InvalidPrice");
  const n1 = liq << 96n;
  const n2 = sb - sa;
  return roundUp ? divUp(mulDivUp(n1, n2, sb), sa) : mulDiv(n1, n2, sb) / sa;
}

/** SqrtPriceMath.getAmount1Delta. */
export function amount1Delta(sa: bigint, sb: bigint, liq: bigint, roundUp: boolean): bigint {
  const n = sa > sb ? sa - sb : sb - sa;
  return roundUp ? mulDivUp(liq, n, Q96) : mulDiv(liq, n, Q96);
}

export interface Position {
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
}
export type Pair = [bigint, bigint];

/** Token amounts of `pos` if the pool sat at sqrt price `s` (path independent, fees ignored). */
export function positionHoldings(pos: Position, s: bigint, roundUp: boolean): Pair {
  if (pos.liquidity === 0n) return [0n, 0n];
  const a = sqrtPriceAtTick(pos.tickLower);
  const b = sqrtPriceAtTick(pos.tickUpper);
  if (s <= a) return [amount0Delta(a, b, pos.liquidity, roundUp), 0n];
  if (s >= b) return [0n, amount1Delta(a, b, pos.liquidity, roundUp)];
  return [amount0Delta(s, b, pos.liquidity, roundUp), amount1Delta(a, s, pos.liquidity, roundUp)];
}

/** Vault holdings H = position amounts + idle balances. */
export function holdings(pos: Position, idle0: bigint, idle1: bigint, s: bigint, roundUp: boolean): Pair {
  const [p0, p1] = positionHoldings(pos, s, roundUp);
  return [p0 + idle0, p1 + idle1];
}

// NAV at the FAIR price in token1 units: amount0 * (Sfair / Q96)^2 + amount1 (nested mulDiv, like Solidity).
export function nav(h: Pair, sFair: bigint, roundUp: boolean): bigint {
  const [a0, a1] = h;
  return roundUp
    ? mulDivUp(mulDivUp(a0, sFair, Q96), sFair, Q96) + a1
    : mulDiv(mulDiv(a0, sFair, Q96), sFair, Q96) + a1;
}

const samePos = (x: Position, y: Position) =>
  x.tickLower === y.tickLower && x.tickUpper === y.tickUpper && x.liquidity === y.liquidity;

/** (L_imm, NAV_before): immediate leakage of a rebalance, rounded against the curator. An exact no-op scores 0. */
export function scoreLeakage(
  old: Position, idleOld: Pair, sBefore: bigint, nw: Position, idleNew: Pair, sAfter: bigint, sFair: bigint,
): [bigint, bigint] {
  const hBefore = holdings(old, idleOld[0], idleOld[1], sBefore, true);
  const navBefore = nav(hBefore, sFair, true);
  if (samePos(old, nw) && idleOld[0] === idleNew[0] && idleOld[1] === idleNew[1] && sBefore === sAfter) {
    return [0n, navBefore];
  }
  const hAfter = holdings(nw, idleNew[0], idleNew[1], sAfter, false);
  return [navBefore - nav(hAfter, sFair, false), navBefore];
}

/** Markout alpha = NAV(H_new at S_T) - NAV(H_counterfactual at S_T), both at fair S*_T; biased down. */
export function markoutAlpha(old: Position, idleOld: Pair, nw: Position, idleNew: Pair, sT: bigint, sFairT: bigint) {
  if (samePos(old, nw) && idleOld[0] === idleNew[0] && idleOld[1] === idleNew[1]) return 0n;
  const hNew = holdings(nw, idleNew[0], idleNew[1], sT, false);
  const hCf = holdings(old, idleOld[0], idleOld[1], sT, true);
  return nav(hNew, sFairT, false) - nav(hCf, sFairT, true);
}

/** max(0, loss) as a WAD fraction of navRef, rounded UP. */
export function lossWad(lossValue: bigint, navRef: bigint): bigint {
  if (navRef === 0n) throw new Error("navRef == 0");
  return lossValue <= 0n ? 0n : mulDivUp(lossValue, WAD, navRef);
}

/** max(0, gain) as a WAD fraction of navRef, rounded DOWN (reputation is never over-credited). */
export function gainWad(gainValue: bigint, navRef: bigint): bigint {
  if (navRef === 0n) throw new Error("navRef == 0");
  return gainValue <= 0n ? 0n : mulDiv(gainValue, WAD, navRef);
}

// Fixed-point primitives: exact BigInt ports of v4-core FullMath / UnsafeMath, as mirrored by sim/model.py.
// Every function here must agree with Solidity to the wei (checked against test/vectors/*.json).

export const Q96 = 1n << 96n;
export const Q128 = 1n << 128n;
export const U256 = 1n << 256n;
export const WAD = 10n ** 18n;
export const UINT256_MAX = U256 - 1n;

/** FullMath.mulDiv: floor(a*b/d). Throws on d == 0 or a uint256 overflow (Solidity reverts). */
export function mulDiv(a: bigint, b: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("mulDiv by zero");
  const r = (a * b) / d; // operands are non-negative: BigInt division truncates = floors
  if (r > UINT256_MAX) throw new Error("mulDiv overflow");
  return r;
}

/** FullMath.mulDivRoundingUp: ceil(a*b/d). */
export function mulDivUp(a: bigint, b: bigint, d: bigint): bigint {
  let r = mulDiv(a, b, d);
  if ((a * b) % d !== 0n) {
    r += 1n;
    if (r > UINT256_MAX) throw new Error("mulDivUp overflow");
  }
  return r;
}

/** UnsafeMath.divRoundingUp. */
export function divUp(a: bigint, b: bigint): bigint {
  return a / b + (a % b !== 0n ? 1n : 0n);
}

/** Python-style floor division for possibly negative values (only used where model.py uses `//` on signed ints). */
export function floorDiv(a: bigint, b: bigint): bigint {
  const q = a / b;
  return (a % b !== 0n && (a < 0n) !== (b < 0n)) ? q - 1n : q;
}

export const min = (a: bigint, b: bigint) => (a < b ? a : b);
export const max = (a: bigint, b: bigint) => (a > b ? a : b);
export const abs = (a: bigint) => (a < 0n ? -a : a);

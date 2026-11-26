// Small maths typography kit: formulas look like formulas (italic serif variables, real subscripts, stacked
// fractions, ceiling brackets) without a TeX dependency. Colours tie symbols to the price markers on the axis.
import type { ReactNode } from "react";
import { tokens } from "../theme/tokens";

export const MATH_COLORS = {
  fair: tokens.color.full, // P*: the fair (oracle) price, green like the "fair" marker
  pool: tokens.color.restricted, // S: the pool price at the decision, amber like the "pool" marker
  later: tokens.color.accent, // T: W blocks later
} as const;

/** A variable: italic serif, optional subscript / superscript, optional colour. */
export function V({ children, sub, sup, color }: { children: ReactNode; sub?: ReactNode; sup?: ReactNode; color?: string }) {
  return (
    <span className="whitespace-nowrap" style={color ? { color } : undefined}>
      <span className="font-serif italic">{children}</span>
      {sup && <sup className="ml-px text-[0.7em]">{sup}</sup>}
      {sub && <sub className="ml-px text-[0.68em] not-italic">{sub}</sub>}
    </span>
  );
}

/** A binary operator with breathing room. */
export const Op = ({ children }: { children: ReactNode }) => <span className="mx-1.5 text-soft">{children}</span>;

/** Upright function name (NAV, max). */
export const Fn = ({ children }: { children: ReactNode }) => <span className="font-serif not-italic">{children}</span>;

/** Stacked fraction. */
export function Frac({ num, den }: { num: ReactNode; den: ReactNode }) {
  return (
    <span className="mx-0.5 inline-flex flex-col items-center align-middle leading-tight">
      <span className="px-1 pb-0.5">{num}</span>
      <span className="w-full border-t border-current px-1 pt-0.5">{den}</span>
    </span>
  );
}

/** Ceiling brackets: rounded up, against the curator. */
export const Ceil = ({ children }: { children: ReactNode }) => (
  <span className="inline-flex items-center">
    <span className="text-[1.6em] font-extralight leading-none text-soft">⌈</span>
    {children}
    <span className="text-[1.6em] font-extralight leading-none text-soft">⌉</span>
  </span>
);

/** A number inside a substituted formula (tabular, slightly emphasised). */
export const N = ({ children, color }: { children: ReactNode; color?: string }) => (
  <span className="num font-medium text-text" style={color ? { color } : undefined}>{children}</span>
);

/** The result of a step: re-keyed on its value so it flashes whenever the number changes. */
export function Result({ value, children, color }: { value: string; children: ReactNode; color: string }) {
  return (
    <span key={value} className="flash num inline-flex items-center rounded-lg px-2 py-0.5 text-lg font-semibold sm:text-xl" style={{ color }}>
      {children}
    </span>
  );
}

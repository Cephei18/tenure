import type { ReactNode } from "react";
import { TIER_NAMES } from "../math/budget";

export const RUN_COLORS = { A: "var(--color-runA)", B: "var(--color-runB)", C: "var(--color-runC)" } as const;
export const RUN_LABELS = {
  A: "A · honest + Tenure",
  B: "B · poisoned + static caps",
  C: "C · poisoned + Tenure",
} as const;

export function Section({ id, title, kicker, children }: { id: string; title: string; kicker: string; children: ReactNode }) {
  return (
    <section id={id} className="mx-auto max-w-6xl px-4 py-12 sm:px-6">
      <p className="text-xs font-semibold uppercase tracking-[0.2em] text-mute">{kicker}</p>
      <h2 className="mt-1 text-2xl font-semibold sm:text-3xl">{title}</h2>
      <div className="mt-6 space-y-6">{children}</div>
    </section>
  );
}

export function Card({ children, className = "" }: { children: ReactNode; className?: string }) {
  return <div className={`rounded-xl border border-line bg-panel p-4 sm:p-5 ${className}`}>{children}</div>;
}

export function Stat({ label, value, sub, color }: { label: string; value: ReactNode; sub?: ReactNode; color?: string }) {
  return (
    <div className="rounded-xl border border-line bg-panel p-4">
      <div className="text-xs text-mute">{label}</div>
      <div className="num mt-1 text-2xl font-semibold" style={color ? { color } : undefined}>{value}</div>
      {sub && <div className="mt-1 text-xs text-mute">{sub}</div>}
    </div>
  );
}

const TIER_STYLE = [
  "bg-full/15 text-full ring-full/40",
  "bg-restricted/15 text-restricted ring-restricted/40",
  "bg-frozen/15 text-frozen ring-frozen/40",
];
export function TierBadge({ tier, size = "md" }: { tier: number; size?: "md" | "lg" }) {
  const pad = size === "lg" ? "px-3 py-1 text-sm" : "px-2 py-0.5 text-xs";
  return (
    <span className={`inline-block rounded-full font-semibold ring-1 ${pad} ${TIER_STYLE[tier] ?? ""}`}>
      {TIER_NAMES[tier] ?? `tier ${tier}`}
    </span>
  );
}

export function Source({ children }: { children: ReactNode }) {
  return <p className="text-xs text-mute">Source: {children}</p>;
}

export function Slider(props: {
  label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void; fmt?: (v: number) => string;
}) {
  const { label, value, min, max, step, onChange, fmt } = props;
  return (
    <label className="block">
      <div className="flex items-baseline justify-between gap-2 text-sm">
        <span className="text-mute">{label}</span>
        <span className="num font-medium">{fmt ? fmt(value) : value}</span>
      </div>
      <input
        type="range" className="mt-1 w-full" min={min} max={max} step={step} value={value}
        onChange={(e) => onChange(Number(e.target.value))} aria-label={label}
      />
    </label>
  );
}

export const fmtTok = (x: number, digits = 0) => x.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits });
export const fmtPct = (x: number, digits = 1) => `${(x * 100).toFixed(digits)}%`;
export const short = (h: string) => `${h.slice(0, 8)}…${h.slice(-6)}`;

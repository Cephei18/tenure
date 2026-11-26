import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { CircleHelp } from "lucide-react";
import { TIER_COLORS, tokens } from "../theme/tokens";
import { TIER_NAMES } from "../math/budget";

// ------------------------------------------------------------------------------------------------ motion
export function useReducedMotion(): boolean {
  const [reduce, setReduce] = useState(false);
  useEffect(() => {
    const m = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    if (!m) return;
    setReduce(m.matches);
    const f = () => setReduce(m.matches);
    m.addEventListener?.("change", f);
    return () => m.removeEventListener?.("change", f);
  }, []);
  return reduce;
}

/** Tweens a number towards `value` (no tween under reduced motion). */
export function useTween(value: number, ms: number = tokens.motion.slow): number {
  const reduce = useReducedMotion();
  const [shown, setShown] = useState(value);
  const from = useRef(value);
  useEffect(() => {
    if (reduce) {
      setShown(value);
      from.current = value;
      return;
    }
    // wall-clock ticker (not requestAnimationFrame): keeps running in background tabs and screen recorders
    const start = performance.now();
    const a = from.current;
    const id = window.setInterval(() => {
      const k = Math.min(1, (performance.now() - start) / ms);
      const v = a + (value - a) * (1 - Math.pow(1 - k, 3));
      setShown(v);
      from.current = v;
      if (k >= 1) window.clearInterval(id);
    }, 16);
    return () => window.clearInterval(id);
  }, [value, ms, reduce]);
  return shown;
}

export function Counter({ value, format }: { value: number; format: (v: number) => string }) {
  return <span className="num">{format(useTween(value))}</span>;
}

// ------------------------------------------------------------------------------------------------ format
export const fmtInt = (x: number) => Math.round(x).toLocaleString("en-US");
export const fmtTok = (x: number, d = 0) => x.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
export const fmtPct = (x: number, d = 0) => `${(x * 100).toFixed(d)}%`;
export const short = (h: string) => `${h.slice(0, 6)}…${h.slice(-4)}`;

// ------------------------------------------------------------------------------------------------ atoms
export function Card({ children, className = "", id }: { children: ReactNode; className?: string; id?: string }) {
  return <div id={id} className={`rounded-2xl border border-border bg-surface p-4 sm:p-5 ${className}`}>{children}</div>;
}

/** "?" button with a short explanation: hover, focus or tap. */
export function Tip({ children, label = "More info" }: { children: ReactNode; label?: string }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  return (
    <span className="relative inline-flex align-middle" onMouseLeave={() => setOpen(false)}>
      <button
        type="button" aria-label={label} aria-describedby={open ? id : undefined} aria-expanded={open}
        className="inline-flex h-6 w-6 items-center justify-center rounded-full text-soft hover:text-text"
        onMouseEnter={() => setOpen(true)} onFocus={() => setOpen(true)} onBlur={() => setOpen(false)}
        onClick={() => setOpen((o) => !o)} onKeyDown={(e) => e.key === "Escape" && setOpen(false)}
      >
        <CircleHelp size={16} aria-hidden />
      </button>
      {open && (
        <span
          role="tooltip" id={id}
          className="absolute left-1/2 top-7 z-30 w-64 max-w-[80vw] -translate-x-1/2 rounded-xl border border-border bg-surface2 p-3 text-left text-xs font-normal normal-case leading-relaxed tracking-normal text-soft shadow-xl"
        >
          {children}
        </span>
      )}
    </span>
  );
}

export function SectionHeader({ id, kicker, title, tip }: { id: string; kicker: string; title: string; tip?: ReactNode }) {
  return (
    <div>
      <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">{kicker}</p>
      <h2 id={`${id}-title`} className="mt-1 flex items-center gap-2 text-2xl font-semibold sm:text-3xl">
        {title}
        {tip && <Tip label={`About ${title}`}>{tip}</Tip>}
      </h2>
    </div>
  );
}

export function TierBadge({ tier, size = "md" }: { tier: number; size?: "sm" | "md" | "lg" }) {
  const color = TIER_COLORS[tier] ?? tokens.color.soft;
  const pad = size === "lg" ? "px-3.5 py-1.5 text-sm" : size === "sm" ? "px-2 py-0.5 text-[11px]" : "px-2.5 py-1 text-xs";
  return (
    <span
      key={tier} // re-mount on change => pop animation
      className={`pop inline-flex items-center rounded-full font-semibold tracking-wide ring-1 ${pad}`}
      style={{ color, background: `${color}1f`, boxShadow: `inset 0 0 0 1px ${color}66` }}
    >
      {TIER_NAMES[tier] ?? "?"}
    </span>
  );
}

/** Budget gauge: ring filled to `ratio`, coloured by tier, with the 50% and 20% thresholds marked. */
export function Ring({ ratio, tier, size = 160, label, className }: { ratio: number; tier: number; size?: number; label?: string; className?: string }) {
  const r = 42;
  const c = 2 * Math.PI * r;
  const shown = useTween(Math.max(0, Math.min(1, ratio)), tokens.motion.base);
  const color = TIER_COLORS[tier] ?? tokens.color.soft;
  const mark = (p: number) => {
    const a = p * 2 * Math.PI - Math.PI / 2;
    return { x1: 50 + 37 * Math.cos(a), y1: 50 + 37 * Math.sin(a), x2: 50 + 47 * Math.cos(a), y2: 50 + 47 * Math.sin(a) };
  };
  return (
    <svg viewBox="0 0 100 100" width={className ? undefined : size} height={className ? undefined : size} className={className} role="img" aria-label={`${label ?? "Budget"}: ${fmtPct(ratio)} of the bucket`}>
      <circle cx="50" cy="50" r={r} fill="none" stroke={tokens.color.surface2} strokeWidth="9" />
      <circle
        cx="50" cy="50" r={r} fill="none" stroke={color} strokeWidth="9" strokeLinecap="butt"
        strokeOpacity={shown > 0.002 ? 1 : 0}
        strokeDasharray={`${shown * c} ${c}`} transform="rotate(-90 50 50)"
        style={{ transition: "stroke 300ms" }}
      />
      {[0.5, 0.2].map((p) => <line key={p} {...mark(p)} stroke={tokens.color.soft} strokeOpacity={0.6} strokeWidth="1.2" />)}
      <text x="50" y="50" textAnchor="middle" fontSize="18" fontWeight="600" fill={tokens.color.text} className="num">
        {fmtPct(shown)}
      </text>
      <text x="50" y="64" textAnchor="middle" fontSize="7.5" fill={tokens.color.soft}>{label ?? "budget"}</text>
    </svg>
  );
}

/** Horizontal budget gauge: big number + bar with the FROZEN (20%) and FULL (50%) thresholds marked. */
export function Gauge({ ratio, tier }: { ratio: number; tier: number }) {
  const shown = useTween(Math.max(0, Math.min(1, ratio)), tokens.motion.base);
  const color = TIER_COLORS[tier] ?? tokens.color.soft;
  return (
    <div className="w-full">
      <span className="num" style={{ color }}>{fmtPct(shown, 1)}</span>
      <div className="relative mt-2 h-2.5 w-full rounded-full bg-surface2" role="meter" aria-valuemin={0} aria-valuemax={100}
        aria-valuenow={Math.round(ratio * 100)} aria-label="Budget left">
        <div className="h-2.5 rounded-full" style={{ width: `${shown * 100}%`, background: color }} />
        {[0.2, 0.5].map((p) => (
          <span key={p} className="absolute -top-1 h-4.5 w-0.5 rounded bg-soft/70" style={{ left: `${p * 100}%` }} aria-hidden />
        ))}
      </div>
      <div className="relative mt-1 h-3 text-[10px] text-muted" aria-hidden>
        <span className="absolute -translate-x-1/2" style={{ left: "20%" }}>20%</span>
        <span className="absolute -translate-x-1/2" style={{ left: "50%" }}>50%</span>
      </div>
    </div>
  );
}

export function Button(props: {
  children: ReactNode; onClick?: () => void; variant?: "primary" | "ghost"; ariaLabel?: string; disabled?: boolean; pressed?: boolean;
}) {
  const { children, onClick, variant = "ghost", ariaLabel, disabled, pressed } = props;
  const base = "inline-flex min-h-10 items-center justify-center gap-2 rounded-xl px-4 text-sm font-medium transition-colors disabled:opacity-50";
  const look = variant === "primary"
    ? "bg-primary text-white hover:bg-[#be123c]"
    : `border border-border text-text hover:border-accent ${pressed ? "bg-surface2 border-accent" : "bg-surface"}`;
  return (
    <button type="button" className={`${base} ${look}`} onClick={onClick} aria-label={ariaLabel} disabled={disabled} aria-pressed={pressed}>
      {children}
    </button>
  );
}

export function Slider(props: {
  label: string; value: number; min: number; max: number; step: number; onChange: (v: number) => void;
  fmt: (v: number) => string; tip?: ReactNode;
}) {
  const { label, value, min, max, step, onChange, fmt, tip } = props;
  const id = useId();
  return (
    <div>
      <div className="flex items-center justify-between gap-2 text-sm">
        <label htmlFor={id} className="flex items-center gap-1 text-soft">{label}{tip && <Tip label={`About ${label}`}>{tip}</Tip>}</label>
        <span className="num font-medium">{fmt(value)}</span>
      </div>
      <input id={id} type="range" className="mt-1 w-full" min={min} max={max} step={step} value={value} onChange={(e) => onChange(Number(e.target.value))} />
    </div>
  );
}

export function ChainBadge({ chain }: { chain: "Unichain" | "Lasna" }) {
  const lasna = chain === "Lasna";
  return (
    <span className={`inline-flex items-center rounded-md px-2 py-0.5 text-[11px] font-semibold ${lasna ? "bg-accent/15 text-accent" : "bg-soft/10 text-soft"}`}>
      {lasna ? "Reactive Lasna" : "Unichain Sepolia"}
    </span>
  );
}

export function StatTile({ label, children, sub, tip }: { label: string; children: ReactNode; sub?: ReactNode; tip?: ReactNode }) {
  return (
    <Card className="flex flex-col gap-2">
      <div className="flex items-center gap-1 text-xs text-soft">{label}{tip && <Tip label={`About ${label}`}>{tip}</Tip>}</div>
      <div className="text-2xl font-semibold sm:text-3xl">{children}</div>
      {sub && <div className="text-xs text-muted">{sub}</div>}
    </Card>
  );
}

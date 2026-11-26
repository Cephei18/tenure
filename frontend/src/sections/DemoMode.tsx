import { useCallback, useEffect, useRef, useState } from "react";
import { Pause, Play, SkipForward, X } from "lucide-react";
import { emit, on } from "../lib/bus";
import { DEMO_STEPS } from "./demoScript";

/** Demo tour: spotlight + caption bar, pause / skip / exit. Start from the Hero button or with ?demo=1. */
export default function DemoMode() {
  const [step, setStep] = useState<number | null>(null);
  const [paused, setPaused] = useState(false);
  const remaining = useRef(0);
  const startedAt = useRef(0);
  const timer = useRef<number | undefined>(undefined);

  const stop = useCallback(() => {
    window.clearTimeout(timer.current);
    setStep(null);
    setPaused(false);
    emit("sim:pause");
  }, []);

  // enter a step: run its action, scroll + spotlight its target
  useEffect(() => {
    if (step === null) return;
    const s = DEMO_STEPS[step];
    s.run?.();
    const el = document.getElementById(s.target);
    const reduce = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    el?.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: s.target === "overview" ? "start" : "center" });
    el?.classList.add("demo-spotlight");
    remaining.current = s.ms;
    return () => el?.classList.remove("demo-spotlight");
  }, [step]);

  // step timer (pausable)
  useEffect(() => {
    if (step === null || paused) return;
    startedAt.current = performance.now();
    timer.current = window.setTimeout(() => {
      if (step + 1 < DEMO_STEPS.length) setStep(step + 1);
      else stop();
    }, remaining.current);
    return () => {
      window.clearTimeout(timer.current);
      remaining.current = Math.max(0, remaining.current - (performance.now() - startedAt.current));
    };
  }, [step, paused, stop]);

  useEffect(() => on("demo:start", () => {
    setPaused(false);
    setStep(0);
  }), []);

  useEffect(() => {
    try {
      if (new URLSearchParams(window.location.search).get("demo") === "1") setTimeout(() => setStep(0), 600);
    } catch {
      /* no URL access */
    }
  }, []);

  useEffect(() => {
    if (step === null) return;
    const k = (e: KeyboardEvent) => {
      if (e.key === "Escape") stop();
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, [step, stop]);

  if (step === null) return null;
  const s = DEMO_STEPS[step];
  return (
    <div role="region" aria-label="Demo mode" className="fixed inset-x-0 bottom-0 z-50 border-t border-border bg-bg/95 backdrop-blur">
      <div className="h-1 bg-surface2">
        <div className="h-1 bg-primary transition-all duration-300" style={{ width: `${((step + 1) / DEMO_STEPS.length) * 100}%` }} />
      </div>
      <div className="mx-auto flex max-w-6xl items-center gap-3 px-4 py-3 sm:px-6">
        <span className="num hidden shrink-0 text-xs text-muted sm:inline">{step + 1}/{DEMO_STEPS.length}</span>
        <p aria-live="polite" className="min-w-0 flex-1 text-base font-medium sm:text-lg">{s.caption}</p>
        <button type="button" onClick={() => setPaused((p) => !p)} aria-label={paused ? "Resume demo" : "Pause demo"}
          className="inline-flex h-10 w-10 items-center justify-center rounded-xl border border-border hover:border-accent">
          {paused ? <Play size={16} aria-hidden /> : <Pause size={16} aria-hidden />}
        </button>
        <button type="button" onClick={() => (step + 1 < DEMO_STEPS.length ? setStep(step + 1) : stop())} aria-label="Next step"
          className="inline-flex h-10 w-10 items-center justify-center rounded-xl border border-border hover:border-accent">
          <SkipForward size={16} aria-hidden />
        </button>
        <button type="button" onClick={stop} aria-label="Exit demo"
          className="inline-flex h-10 w-10 items-center justify-center rounded-xl border border-border hover:border-accent">
          <X size={16} aria-hidden />
        </button>
      </div>
    </div>
  );
}

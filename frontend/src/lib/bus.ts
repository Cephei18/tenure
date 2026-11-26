// Tiny typed event bus: lets Demo mode and the Hero buttons drive the Simulator without prop drilling.
export type BusEvents = {
  "sim:run": { mode: "A" | "B" | "C" | "compare"; speed?: number; from?: number };
  "sim:pause": undefined;
  "sim:seek": { step: number };
  "sim:speed": { speed: number };
  "sim:tune": { open: boolean };
  "live:scrollTo": { index: number };
  "demo:start": undefined;
};
type Handler<K extends keyof BusEvents> = (payload: BusEvents[K]) => void;
type AnyHandler = (payload: unknown) => void;

const handlers = new Map<keyof BusEvents, Set<AnyHandler>>();

export function on<K extends keyof BusEvents>(event: K, h: Handler<K>): () => void {
  if (!handlers.has(event)) handlers.set(event, new Set());
  const set = handlers.get(event)!;
  set.add(h as AnyHandler);
  return () => {
    set.delete(h as AnyHandler);
  };
}

export function emit<K extends keyof BusEvents>(event: K, ...payload: BusEvents[K] extends undefined ? [] : [BusEvents[K]]) {
  handlers.get(event)?.forEach((h) => h(payload[0]));
}

/** Smooth-scroll to a section (instant when the user prefers reduced motion). */
export function scrollToSection(id: string) {
  const reduce = typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
  document.getElementById(id)?.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
}

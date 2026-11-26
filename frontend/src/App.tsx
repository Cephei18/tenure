import { LiveProvider } from "./lib/live";
import Hero from "./sections/Hero";
import Simulator from "./sections/Simulator";
import LiveProof from "./sections/LiveProof";
import Grading from "./sections/Grading";
import DemoMode from "./sections/DemoMode";

const NAV = [
  ["overview", "Overview", "Overview"],
  ["simulator", "Simulator", "Simulator"],
  ["live", "Live proof", "Live"],
  ["grading", "How grading works", "Grading"],
] as const;

export default function App() {
  return (
    <LiveProvider>
      <a href="#simulator" className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-3 focus:z-50 focus:rounded-lg focus:bg-primary focus:px-3 focus:py-2">
        Skip to the simulator
      </a>
      <header className="sticky top-0 z-40 border-b border-border bg-bg/85 backdrop-blur">
        <nav aria-label="Sections" className="mx-auto flex max-w-6xl items-center gap-1 overflow-x-auto px-4 py-2.5 sm:px-6">
          <a href="#overview" className="mr-2 shrink-0 font-bold tracking-tight">
            Tenure<span className="text-primary"> Lab</span>
          </a>
          {NAV.map(([id, label, shortLabel]) => (
            <a key={id} href={`#${id}`} className="shrink-0 rounded-lg px-2 py-2 text-sm text-soft hover:bg-surface2 hover:text-text sm:px-2.5">
              <span className="sm:hidden">{shortLabel}</span>
              <span className="hidden sm:inline">{label}</span>
            </a>
          ))}
          <a href="https://github.com/Cephei18/tenure" className="ml-auto hidden shrink-0 rounded-lg px-2.5 py-2 text-sm text-soft hover:text-text sm:inline">
            GitHub
          </a>
        </nav>
      </header>
      <main>
        <Hero />
        <Simulator />
        <LiveProof />
        <Grading />
      </main>
      <footer className="border-t border-border py-8 pb-28 text-center text-xs text-muted">
        Tenure · UHI11 hookathon · read-only, no wallet
      </footer>
      <DemoMode />
    </LiveProvider>
  );
}

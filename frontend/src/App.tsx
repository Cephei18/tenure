import Live from "./sections/Live";
import Replay from "./sections/Replay";
import Playground from "./sections/Playground";
import MathLab from "./sections/MathLab";

const NAV = [
  ["live", "Live"],
  ["replay", "Replay"],
  ["playground", "Playground"],
  ["math", "Math"],
] as const;

export default function App() {
  return (
    <>
      <header className="sticky top-0 z-20 border-b border-line bg-ink/85 backdrop-blur">
        <nav className="mx-auto flex max-w-6xl items-center gap-1 overflow-x-auto px-4 py-3 sm:px-6">
          <a href="#top" className="mr-3 shrink-0 font-semibold">Tenure Lab</a>
          {NAV.map(([id, label]) => (
            <a key={id} href={`#${id}`} className="shrink-0 rounded-md px-3 py-1.5 text-sm text-mute hover:bg-panel2 hover:text-text">
              {label}
            </a>
          ))}
          <a href="https://github.com/Cephei18/tenure" className="ml-auto shrink-0 text-sm text-mute hover:text-text">GitHub</a>
        </nav>
      </header>

      <main id="top">
        <div className="mx-auto max-w-6xl px-4 pt-12 sm:px-6">
          <h1 className="max-w-3xl text-3xl font-semibold leading-tight sm:text-4xl">
            Earned autonomy for AI liquidity curators
          </h1>
          <p className="mt-4 max-w-3xl text-mute">
            Tenure is a Uniswap v4 hook. It does not try to detect a compromised curator. It measures the damage each
            decision causes at a fair oracle price, and the curator's autonomy shrinks automatically (FULL, RESTRICTED,
            FROZEN) when it starts losing depositors' money. Everything on this page is read from the chain, from the
            repository's committed results, or computed in your browser by an exact port of the contracts' math.
          </p>
        </div>
        <Live />
        <Replay />
        <Playground />
        <MathLab />
      </main>

      <footer className="border-t border-line py-8 text-center text-xs text-mute">
        Tenure · UHI11 hookathon · read-only, no wallet ·{" "}
        <a className="underline" href="https://github.com/Cephei18/tenure/tree/main/frontend">source</a>
      </footer>
    </>
  );
}

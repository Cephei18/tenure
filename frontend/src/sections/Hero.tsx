import { Clapperboard, Play } from "lucide-react";
import { budgetRatio, useLive } from "../lib/live";
import { emit, scrollToSection } from "../lib/bus";
import { Button, Gauge, StatTile, TierBadge } from "../components/ui";
import { tokens } from "../theme/tokens";

export default function Hero() {
  const { state: s } = useLive();
  return (
    <section id="overview" aria-labelledby="overview-title" className="mx-auto max-w-6xl px-4 pb-12 pt-10 sm:px-6 sm:pt-16">
      <p className="text-xs font-semibold uppercase tracking-[0.18em] text-accent">Tenure · Uniswap v4 hook</p>
      <h1 id="overview-title" className="mt-2 max-w-3xl text-4xl font-bold leading-tight sm:text-5xl">
        Don't just detect the compromise. Measure the damage.
      </h1>
      <p className="mt-4 max-w-xl text-lg text-soft">
        AI liquidity curators lose autonomy automatically when their decisions start losing depositors' money.
      </p>
      <div className="mt-6 flex flex-wrap gap-3">
        <Button
          variant="primary"
          onClick={() => {
            scrollToSection("simulator");
            emit("sim:run", { mode: "compare", speed: 2, from: 80 });
          }}
        >
          <Play size={16} aria-hidden /> Run the attack
        </Button>
        <Button onClick={() => emit("demo:start")}>
          <Clapperboard size={16} aria-hidden /> Watch demo mode
        </Button>
      </div>

      <div className="mt-10 grid gap-3 sm:grid-cols-3 sm:gap-4" aria-live="polite">
        <StatTile
          label="Vault A tier (live)"
          sub={s?.source === "snapshot" ? "last recorded value" : "hook.tierOf on Unichain Sepolia"}
          tip="Read from the deployed TenureHook. The scripted attack drove vault A's curator to FROZEN."
        >
          {s ? <TierBadge tier={s.tier} size="lg" /> : <span className="text-soft">…</span>}
        </StatTile>
        <StatTile
          label="Vault A budget (live)"
          sub="FROZEN below 20% · no refill while frozen"
          tip="hook.budgetOf: risk budget left as a share of the bucket. Losses drain it; time refills it, except when FROZEN."
        >
          {s ? <Gauge ratio={budgetRatio(s)} tier={s.tier} /> : <span className="text-soft">…</span>}
        </StatTile>
        <StatTile
          label="Vault B relayFrozen (live)"
          sub="freeze relayed cross-chain by Reactive"
          tip="Vault B is another vault of the same curator. Reactive Network relayed A's FROZEN to it, blocking the curator there too."
        >
          {s ? (
            <span style={{ color: s.relayFrozen ? tokens.color.frozen : tokens.color.full }}>{s.relayFrozen ? "true" : "false"}</span>
          ) : <span className="text-soft">…</span>}
        </StatTile>
      </div>
    </section>
  );
}

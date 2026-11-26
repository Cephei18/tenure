import { useEffect, useRef, useState } from "react";
import { on } from "../lib/bus";
import { ArrowRight, ExternalLink, RefreshCw, Settings2 } from "lucide-react";
import { relayDelayBlocks, timeline, txUrl, UNISCAN, REACTSCAN } from "../data/timeline";
import { budgetRatio, useLive } from "../lib/live";
import { lasna, unichain } from "../lib/data";
import { Button, Card, ChainBadge, SectionHeader, TierBadge, Tip, fmtPct, short } from "../components/ui";
import { TIER_COLORS, tokens } from "../theme/tokens";

const DOT: Record<string, string> = {
  guardian: tokens.color.soft, curator: tokens.color.restricted, freeze: tokens.color.frozen,
  reactive: tokens.color.accent, exit: tokens.color.full,
};
const ADDRESSES: [string, string, string][] = [
  ["TenureHook", unichain.tenureHook, UNISCAN],
  ["Vault A", unichain.demoVault, UNISCAN],
  ["Vault B", unichain.chainlinkVault, UNISCAN],
  ["Freeze receiver", unichain.freezeReceiver, UNISCAN],
  ["Freeze RC (Lasna)", lasna.freezeRC, REACTSCAN],
  ["Settler RC (Lasna)", lasna.settlerRC, REACTSCAN],
];

export default function LiveProof() {
  const { state: s, loading, refresh, rpc, setRpc } = useLive();
  const [showRpc, setShowRpc] = useState(false);
  const [draft, setDraft] = useState(rpc);
  const strip = useRef<HTMLOListElement>(null);
  useEffect(() => on("live:scrollTo", ({ index }) => {
    const el = strip.current?.children[index] as HTMLElement | undefined;
    if (el && strip.current) strip.current.scrollTo({ left: el.offsetLeft - strip.current.offsetLeft - 16, behavior: "smooth" });
  }), []);
  const when = s?.timestamp ? new Date(s.timestamp * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC" : "";

  return (
    <section id="live" aria-labelledby="live-title" className="mx-auto max-w-6xl space-y-6 px-4 py-14 sm:px-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <SectionHeader
          id="live" kicker="Live proof" title="It already happened on testnet"
          tip="The same attack, run on Unichain Sepolia against the deployed hook. Reactive Network relayed the freeze to the curator's other vault. Every step links to its transaction."
        />
        <div className="flex items-center gap-2 text-xs text-soft">
          <span className="inline-flex items-center gap-1.5 rounded-full border border-border px-3 py-1.5">
            <span className="h-2 w-2 rounded-full" style={{ background: s?.source === "chain" ? tokens.color.full : tokens.color.restricted }} aria-hidden />
            {s ? `${s.source === "chain" ? "Read from chain" : "Recorded"} at block ${s.blockNumber.toLocaleString("en-US")}` : "Reading chain…"}
          </span>
          <button type="button" onClick={refresh} disabled={loading} aria-label="Refresh chain reads"
            className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-border hover:border-accent disabled:opacity-50">
            <RefreshCw size={15} className={loading ? "animate-spin" : ""} aria-hidden />
          </button>
          <button type="button" onClick={() => setShowRpc((x) => !x)} aria-label="RPC settings" aria-expanded={showRpc}
            className="inline-flex h-9 w-9 items-center justify-center rounded-full border border-border hover:border-accent">
            <Settings2 size={15} aria-hidden />
          </button>
        </div>
      </div>

      {showRpc && (
        <Card className="flex flex-wrap items-center gap-2">
          <label htmlFor="rpc" className="text-sm text-soft">Unichain Sepolia RPC</label>
          <input id="rpc" value={draft} onChange={(e) => setDraft(e.target.value)}
            className="min-w-0 flex-1 rounded-xl border border-border bg-bg px-3 py-2 text-sm" />
          <Button onClick={() => setRpc(draft)}>Use</Button>
        </Card>
      )}

      {s?.source === "snapshot" && (
        <div role="status" className="rounded-xl border border-restricted/50 bg-restricted/10 px-4 py-3 text-sm text-restricted">
          RPC unreachable. Showing last recorded values (block {s.blockNumber.toString()}, {when}).
        </div>
      )}

      {/* now: three facts */}
      <div className="grid gap-3 sm:grid-cols-3">
        <Fact label="Vault A curator">{s ? <TierBadge tier={s.tier} /> : "…"}</Fact>
        <Fact label="Vault A budget">
          <span className="num" style={{ color: s ? TIER_COLORS[s.tier] : undefined }}>{s ? fmtPct(budgetRatio(s), 1) : "…"}</span>
        </Fact>
        <Fact label="Vault A shares left">
          <span className="num">{s ? s.totalSupplyA.toLocaleString("en-US") : "…"}</span>
          <Tip>Only the 1,000,000 base-unit dead shares minted at the first deposit remain: the depositor withdrew everything while FROZEN.</Tip>
        </Fact>
      </div>

      {/* the proven sequence */}
      <ol ref={strip} id="live-steps" className="-mx-4 flex snap-x snap-mandatory gap-3 overflow-x-auto px-4 pb-3 lg:mx-0 lg:grid lg:grid-cols-4 lg:gap-4 lg:overflow-visible lg:px-0" aria-label="Proven live sequence">
        {timeline.map((e, i) => (
          <li key={e.tx} className="flex shrink-0 snap-start items-stretch lg:shrink">
            <Card className="flex w-60 flex-col gap-2 lg:w-full">
              <div className="flex items-center justify-between gap-2">
                <ChainBadge chain={e.chain === "Lasna" ? "Lasna" : "Unichain"} />
                <span className="text-xs text-muted">{i + 1}/{timeline.length}</span>
              </div>
              <div className="flex items-center gap-2 font-semibold">
                <span className="h-2.5 w-2.5 rounded-full" style={{ background: DOT[e.kind] }} aria-hidden />
                {e.title}
                <Tip label={`About ${e.title}`}>{e.detail}</Tip>
              </div>
              <p className="text-sm text-soft">{e.short}</p>
              {e.title === "Relay to vault B" && (
                <span className="w-fit rounded-md bg-accent/15 px-2 py-0.5 text-xs font-semibold text-accent">
                  {relayDelayBlocks} blocks later
                </span>
              )}
              <a href={txUrl(e)} target="_blank" rel="noreferrer"
                className="mt-auto inline-flex items-center gap-1 text-xs text-accent underline-offset-2 hover:underline">
                <span className="num">block {Number(e.block).toLocaleString("en-US")} · {short(e.tx)}</span>
                <ExternalLink size={12} aria-hidden />
              </a>
            </Card>
            {i < timeline.length - 1 && <ArrowRight size={16} className="mx-1 self-center text-muted lg:hidden" aria-hidden />}
          </li>
        ))}
      </ol>

      <details className="group rounded-2xl border border-border bg-surface p-4 text-sm">
        <summary className="cursor-pointer select-none text-soft">Deployed contracts</summary>
        <ul className="mt-3 grid gap-2 sm:grid-cols-2">
          {ADDRESSES.map(([name, a, base]) => (
            <li key={a} className="flex items-center justify-between gap-2">
              <span className="text-soft">{name}</span>
              <a className="num inline-flex items-center gap-1 text-xs text-accent" href={`${base}/address/${a}`} target="_blank" rel="noreferrer">
                {short(a)} <ExternalLink size={12} aria-hidden />
              </a>
            </li>
          ))}
        </ul>
        <p className="mt-3 text-xs text-muted">Not shown live yet: a Reactive settlement callback (covered by tests).</p>
      </details>
    </section>
  );
}

const Fact = ({ label, children }: { label: string; children: React.ReactNode }) => (
  <Card className="flex items-center justify-between gap-3">
    <span className="text-sm text-soft">{label}</span>
    <span className="flex items-center gap-1 text-lg font-semibold">{children}</span>
  </Card>
);

import { useCallback, useEffect, useState } from "react";
import { createPublicClient, http } from "viem";
import { unichainSepolia } from "viem/chains";
import { TenureHookAbi } from "../abi/TenureHook";
import { CuratedVaultAbi } from "../abi/CuratedVault";
import { DemoDirectorAbi } from "../abi/DemoDirector";
import snapshot from "../data/live-snapshot.json";
import { timeline, txUrl, UNISCAN, REACTSCAN } from "../data/timeline";
import { lasna, unichain } from "../lib/data";
import { Card, Section, Source, Stat, TierBadge, fmtPct, short } from "../components/ui";

const DEFAULT_RPC = "https://sepolia.unichain.org";
const RPC_KEY = "tenure-lab-rpc";

interface LiveState {
  source: "chain" | "snapshot";
  blockNumber: bigint;
  timestamp: number | null;
  tier: number;
  budget: bigint;
  bMax: bigint;
  relayFrozen: boolean;
  totalSupplyA: bigint;
  ticks: bigint;
  rounds: bigint;
  recordCount: bigint;
  settlePointer: bigint;
  error?: string;
}

const fromSnapshot = (error?: string): LiveState => ({
  source: "snapshot",
  blockNumber: BigInt(snapshot.blockNumber),
  timestamp: snapshot.timestamp,
  tier: snapshot.poolA.tier,
  budget: BigInt(snapshot.poolA.budget),
  bMax: BigInt(snapshot.poolA.bMax),
  relayFrozen: snapshot.vaultB.relayFrozen,
  totalSupplyA: BigInt(snapshot.vaultA.totalSupply),
  ticks: BigInt(snapshot.director.ticks),
  rounds: BigInt(snapshot.director.rounds),
  recordCount: BigInt(snapshot.poolA.recordCount),
  settlePointer: BigInt(snapshot.poolA.settlePointer),
  error,
});

function initialRpc(): string {
  try {
    const q = new URLSearchParams(window.location.search).get("rpc");
    return q || localStorage.getItem(RPC_KEY) || DEFAULT_RPC;
  } catch {
    return DEFAULT_RPC;
  }
}

async function readChain(rpc: string): Promise<LiveState> {
  const client = createPublicClient({
    chain: unichainSepolia,
    transport: http(rpc, { retryCount: 3, retryDelay: 600, timeout: 12_000 }),
  });
  const hook = unichain.tenureHook as `0x${string}`;
  const pool = unichain.demoPoolId as `0x${string}`;
  const chainId = await client.getChainId();
  if (chainId !== 1301) throw new Error(`RPC is chain ${chainId}, not Unichain Sepolia (1301)`);
  // Read 2 blocks behind the head: a load-balanced public RPC may route a call to a node that has not seen the
  // newest block yet ("resource not found"); 2 s of staleness is irrelevant for this page.
  const blockNumber = (await client.getBlockNumber()) - 2n;
  const at = { blockNumber };
  const [tier, budget, relayFrozen, totalSupplyA, ticks, rounds, recordCount, settlePointer, block] = await Promise.all([
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "tierOf", args: [pool], ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "budgetOf", args: [pool], ...at }),
    client.readContract({ address: unichain.chainlinkVault as `0x${string}`, abi: CuratedVaultAbi, functionName: "relayFrozen", ...at }),
    client.readContract({ address: unichain.demoVault as `0x${string}`, abi: CuratedVaultAbi, functionName: "totalSupply", ...at }),
    client.readContract({ address: unichain.demoDirector as `0x${string}`, abi: DemoDirectorAbi, functionName: "ticks", ...at }),
    client.readContract({ address: unichain.demoDirector as `0x${string}`, abi: DemoDirectorAbi, functionName: "rounds", ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "recordCount", args: [pool], ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "settlePointer", args: [pool], ...at }),
    client.getBlock(at),
  ]);
  return {
    source: "chain", blockNumber, timestamp: Number(block.timestamp), tier: Number(tier),
    budget: budget.budget, bMax: budget.bMax, relayFrozen, totalSupplyA, ticks, rounds, recordCount, settlePointer,
  };
}

const addr = (label: string, a: string, base = UNISCAN) => ({ label, a, url: `${base}/address/${a}` });
const ADDRESSES = [
  addr("TenureHook", unichain.tenureHook),
  addr("Vault A (demo, mock oracle)", unichain.demoVault),
  addr("Vault B (Chainlink oracle)", unichain.chainlinkVault),
  addr("DemoDirector", unichain.demoDirector),
  addr("ChainlinkReferencePrice", unichain.chainlinkOracle),
  addr("TenureFreezeReceiver", unichain.freezeReceiver),
  addr("TenureReactiveReceiver", unichain.settleReceiver),
  addr("TenureFreezeRC (Lasna)", lasna.freezeRC, REACTSCAN),
  addr("TenureSettlerRC (Lasna)", lasna.settlerRC, REACTSCAN),
];

const KIND_DOT: Record<string, string> = {
  guardian: "bg-mute", curator: "bg-runB", freeze: "bg-frozen", reactive: "bg-runC", exit: "bg-full",
};

export default function Live() {
  const [rpc, setRpc] = useState(initialRpc);
  const [draft, setDraft] = useState(rpc);
  const [state, setState] = useState<LiveState | null>(null);
  const [loading, setLoading] = useState(false);

  const load = useCallback(async (url: string) => {
    setLoading(true);
    try {
      setState(await readChain(url));
    } catch (e) {
      setState(fromSnapshot(e instanceof Error ? e.message.split("\n")[0] : String(e)));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load(rpc);
  }, [rpc, load]);

  const applyRpc = () => {
    try {
      localStorage.setItem(RPC_KEY, draft);
    } catch {
      /* storage unavailable: the RPC still applies for this visit */
    }
    setRpc(draft);
  };

  const s = state;
  const ratio = s ? Number((s.budget * 1_000_000n) / s.bMax) / 1e6 : 0;
  const when = s?.timestamp ? new Date(s.timestamp * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC" : "";

  return (
    <Section id="live" kicker="1 · Live on Unichain Sepolia" title="What the deployed hook says right now">
      {s?.source === "snapshot" && (
        <div className="rounded-lg border border-restricted/40 bg-restricted/10 p-3 text-sm text-restricted">
          RPC unreachable ({s.error}). Showing the last recorded values, read at block {s.blockNumber.toString()} ({when}).
        </div>
      )}
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Pool A tier (hook.tierOf)" value={s ? <TierBadge tier={s.tier} size="lg" /> : "…"} sub="the scripted attack froze it" />
        <Stat label="Pool A budget / bMax" value={s ? fmtPct(ratio) : "…"} sub="FROZEN below 20%; no refill while frozen" />
        <Stat
          label="Vault B relayFrozen()"
          value={s ? (s.relayFrozen ? "true" : "false") : "…"}
          color={s?.relayFrozen ? "var(--color-frozen)" : undefined}
          sub="freeze relayed by Reactive Network"
        />
        <Stat
          label="Vault A shares outstanding"
          value={s ? s.totalSupplyA.toLocaleString("en-US") : "…"}
          sub="only the 1e6 dead shares: depositor exited while FROZEN"
        />
      </div>
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        <Stat label="Demo ticks run" value={s ? s.ticks.toString() : "…"} />
        <Stat label="Attack rounds before the freeze" value={s ? s.rounds.toString() : "…"} />
        <Stat label="Decisions recorded / settled" value={s ? `${s.recordCount} / ${s.settlePointer}` : "…"} sub="every rebalance is marked out" />
        <Stat label={s?.source === "chain" ? "Read live at block" : "Recorded at block"} value={s ? s.blockNumber.toLocaleString("en-US") : "…"} sub={when} />
      </div>

      <Card>
        <h3 className="font-semibold">Proven live sequence</h3>
        <p className="mt-1 text-sm text-mute">
          Restore, re-freeze by the scripted attack, cross-chain relay, and a full exit while FROZEN. Each step links to
          its transaction.
        </p>
        <ol className="mt-4 space-y-3">
          {timeline.map((e) => (
            <li key={e.tx} className="grid grid-cols-[auto_1fr] gap-3">
              <span className={`mt-1.5 h-2.5 w-2.5 rounded-full ${KIND_DOT[e.kind]}`} />
              <div>
                <div className="flex flex-wrap items-baseline gap-x-3">
                  <span className="font-medium">{e.title}</span>
                  <span className="num text-xs text-mute">{e.chain} · block {Number(e.block).toLocaleString("en-US")}</span>
                </div>
                <p className="text-sm text-mute">{e.detail}</p>
                <a className="num text-xs text-runC underline" href={txUrl(e)} target="_blank" rel="noreferrer">
                  {short(e.tx)}
                </a>
              </div>
            </li>
          ))}
        </ol>
        <p className="mt-4 text-xs text-mute">
          Not yet shown live: a Reactive <em>settlement</em> callback (the settler RC reacts, but every record so far was
          settled by afterSwap or by hand first). That path is covered by tests only.
        </p>
      </Card>

      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <h3 className="font-semibold">Deployed contracts</h3>
          <ul className="mt-3 space-y-1.5 text-sm">
            {ADDRESSES.map((x) => (
              <li key={x.a} className="flex flex-wrap justify-between gap-2">
                <span className="text-mute">{x.label}</span>
                <a className="num text-xs underline" href={x.url} target="_blank" rel="noreferrer">{short(x.a)}</a>
              </li>
            ))}
          </ul>
        </Card>
        <Card>
          <h3 className="font-semibold">RPC</h3>
          <p className="mt-1 text-sm text-mute">Read-only calls, 3 retries each. No wallet, no keys.</p>
          <div className="mt-3 flex gap-2">
            <input
              className="min-w-0 flex-1 rounded-md border border-line bg-ink px-3 py-1.5 text-sm"
              value={draft} onChange={(e) => setDraft(e.target.value)} aria-label="Unichain Sepolia RPC URL"
            />
            <button className="rounded-md bg-panel2 px-3 py-1.5 text-sm ring-1 ring-line hover:ring-runC" onClick={applyRpc}>
              Use
            </button>
            <button className="rounded-md bg-panel2 px-3 py-1.5 text-sm ring-1 ring-line hover:ring-runC" onClick={() => void load(rpc)} disabled={loading}>
              {loading ? "Reading…" : "Refresh"}
            </button>
          </div>
          <Source>
            hook.tierOf / budgetOf / recordCount / settlePointer, vault.relayFrozen / totalSupply, director.ticks / rounds
            (ABI fragments copied from forge's out/); addresses from deployments/1301.json and 5318007.json.
          </Source>
        </Card>
      </div>
    </Section>
  );
}

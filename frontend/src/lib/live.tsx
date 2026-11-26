// Read-only chain state shared by the Hero tiles and the Live proof section (one fetch, one refresh button).
// Falls back to the last recorded values (src/data/live-snapshot.json) when the RPC cannot be reached.
import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from "react";
import { createPublicClient, http } from "viem";
import { unichainSepolia } from "viem/chains";
import { TenureHookAbi } from "../abi/TenureHook";
import { CuratedVaultAbi } from "../abi/CuratedVault";
import { DemoDirectorAbi } from "../abi/DemoDirector";
import snapshot from "../data/live-snapshot.json";
import { unichain } from "./data";

export const DEFAULT_RPC = "https://sepolia.unichain.org";
const RPC_KEY = "tenure-lab-rpc";

export interface LiveState {
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

export const fromSnapshot = (error?: string): LiveState => ({
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

async function readChain(rpc: string): Promise<LiveState> {
  const client = createPublicClient({
    chain: unichainSepolia,
    transport: http(rpc, { retryCount: 3, retryDelay: 600, timeout: 12_000 }),
  });
  const hook = unichain.tenureHook as `0x${string}`;
  const pool = unichain.demoPoolId as `0x${string}`;
  const director = unichain.demoDirector as `0x${string}`;
  const chainId = await client.getChainId();
  if (chainId !== 1301) throw new Error(`RPC is chain ${chainId}, not Unichain Sepolia (1301)`);
  // 2 blocks behind the head: a load-balanced public RPC may route a call to a node without the newest block.
  const blockNumber = (await client.getBlockNumber()) - 2n;
  const at = { blockNumber };
  const [tier, budget, relayFrozen, totalSupplyA, ticks, rounds, recordCount, settlePointer, block] = await Promise.all([
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "tierOf", args: [pool], ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "budgetOf", args: [pool], ...at }),
    client.readContract({ address: unichain.chainlinkVault as `0x${string}`, abi: CuratedVaultAbi, functionName: "relayFrozen", ...at }),
    client.readContract({ address: unichain.demoVault as `0x${string}`, abi: CuratedVaultAbi, functionName: "totalSupply", ...at }),
    client.readContract({ address: director, abi: DemoDirectorAbi, functionName: "ticks", ...at }),
    client.readContract({ address: director, abi: DemoDirectorAbi, functionName: "rounds", ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "recordCount", args: [pool], ...at }),
    client.readContract({ address: hook, abi: TenureHookAbi, functionName: "settlePointer", args: [pool], ...at }),
    client.getBlock(at),
  ]);
  return {
    source: "chain", blockNumber, timestamp: Number(block.timestamp), tier: Number(tier),
    budget: budget.budget, bMax: budget.bMax, relayFrozen, totalSupplyA, ticks, rounds, recordCount, settlePointer,
  };
}

function initialRpc(): string {
  try {
    return new URLSearchParams(window.location.search).get("rpc") || localStorage.getItem(RPC_KEY) || DEFAULT_RPC;
  } catch {
    return DEFAULT_RPC;
  }
}

interface LiveCtx {
  state: LiveState | null;
  loading: boolean;
  rpc: string;
  setRpc: (url: string) => void;
  refresh: () => void;
}
const Ctx = createContext<LiveCtx | null>(null);

export function LiveProvider({ children }: { children: ReactNode }) {
  const [rpc, setRpcState] = useState(initialRpc);
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

  const setRpc = (url: string) => {
    try {
      localStorage.setItem(RPC_KEY, url);
    } catch {
      /* storage unavailable: applies for this visit only */
    }
    setRpcState(url);
  };

  return <Ctx.Provider value={{ state, loading, rpc, setRpc, refresh: () => void load(rpc) }}>{children}</Ctx.Provider>;
}

export function useLive(): LiveCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useLive outside LiveProvider");
  return c;
}

/** budget / bMax as a float in [0, 1] (display). */
export const budgetRatio = (s: LiveState) => Number((s.budget * 1_000_000n) / s.bMax) / 1e6;

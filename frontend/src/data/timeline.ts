// Proven live events. Every hash and block below is copied from docs/INCIDENT_REACTIVE.md ("Live verification")
// and docs/RESULTS.md ("Live testnet run"); lib/timeline.test.ts fails if any of them is missing from those docs.
export const UNISCAN = "https://sepolia.uniscan.xyz";
export const REACTSCAN = "https://lasna.reactscan.net";

export interface LiveEvent {
  title: string;
  short: string; // one line for the card (<= 12 words)
  detail: string;
  chain: "Unichain Sepolia" | "Lasna";
  block: string;
  tx: string;
  kind: "guardian" | "curator" | "freeze" | "reactive" | "exit";
}

export const timeline: LiveEvent[] = [
  {
    title: "Request restore",
    short: "Guardian asks to un-freeze vault A; timelocked.",
    detail: "Vault A was FROZEN; restore is timelocked (600 blocks) so autonomy cannot be handed back instantly.",
    chain: "Unichain Sepolia", block: "68836944", kind: "guardian",
    tx: "0x1fa6170ab1c2179ee8a1abdf6a72ebbdb0de6e5655dc29f5bd722efd79a443ae",
  },
  {
    title: "Restore",
    short: "Back to RESTRICTED only: autonomy must be re-earned.",
    detail: "608 blocks later. The curator is back, but only in RESTRICTED (35% of the bucket): autonomy is re-earned.",
    chain: "Unichain Sepolia", block: "68837552", kind: "guardian",
    tx: "0x2c73d02bbec5774e33e4247019255435443656faf56fa34aff0037f1d6961b2a",
  },
  {
    title: "Curator parks",
    short: "Poisoned curator moves liquidity far from the price.",
    detail: "Director note: \"poisoned curator parks its range 1,500 ticks away from the price | TIER -> RESTRICTED\".",
    chain: "Unichain Sepolia", block: "68837588", kind: "curator",
    tx: "0x7c07e27e289238a25251e461b8cc7510085b60bc52637594fbbf2049dce499af",
  },
  {
    title: "Attack",
    short: "Attacker pushes the price; curator follows.",
    detail: "Director note: \"ATTACK round 3: push spot -400 ticks, curator follows, arb back; attacker +133 tokens\".",
    chain: "Unichain Sepolia", block: "68837703", kind: "curator",
    tx: "0x586fd4af5bf18768197530ce3cf411a3649e00238b9470ae65a648f6d7bb6c1e",
  },
  {
    title: "Freeze",
    short: "Markouts drain the budget: curator FROZEN.",
    detail: "The markouts of the bad decisions drain the budget below 20%: the hook freezes the curator.",
    chain: "Unichain Sepolia", block: "68837823", kind: "freeze",
    tx: "0xd31fd9de3c171b1d174253ca8d7f5e81c1a4ff36a5be6608ce8629c71d469051",
  },
  {
    title: "Reactive reacts",
    short: "Freeze RC sees FROZEN and requests a callback.",
    detail: "TenureFreezeRC sees the FROZEN and requests a callback to vault B's freeze receiver.",
    chain: "Lasna", block: "9291302", kind: "reactive",
    tx: "0x40e3a5e7e3184993eccf23c3c7d1bc6459e4ace17beefd5c9a274fc22368c3ed",
  },
  {
    title: "Relay to vault B",
    short: "Same curator blocked on vault B.",
    detail: "2 Unichain blocks after the freeze, the same curator is blocked on vault B (relayFrozen() == true).",
    chain: "Unichain Sepolia", block: "68837825", kind: "reactive",
    tx: "0xede7e97dbbaa5b0a1290f479ac21b5e096d3a4ab8371c16b248a933cd44a9696",
  },
  {
    title: "Withdraw",
    short: "Depositor exits fully while FROZEN.",
    detail: "All 79,999,999,999,999,999,000,000 shares redeemed in one tx (249,186 gas). Exit is never blocked.",
    chain: "Unichain Sepolia", block: "68844903", kind: "exit",
    tx: "0xfd84e1bc71bf633e8bd0453d1057ecc343301d21a04171a6e332188a2ae78ce7",
  },
];

export const txUrl = (e: LiveEvent) => `${e.chain === "Lasna" ? REACTSCAN : UNISCAN}/tx/${e.tx}`;

/** Unichain blocks between the freeze and the relayed freeze on vault B (computed, not typed in). */
export const relayDelayBlocks = (() => {
  const freeze = timeline.find((e) => e.kind === "freeze")!;
  const relay = timeline.find((e) => e.title === "Relay to vault B")!;
  return Number(relay.block) - Number(freeze.block);
})();

# Incident: the Lasna reactive contracts went INACTIVE on their first event (2026-11-25)

**Status: RESOLVED (2026-11-26).** The rebuilt contracts are live, `CheckReactive.s.sol` printed ALL CHECKS
PASSED, and a fresh FROZEN on vault A was relayed to vault B on Unichain Sepolia (`relayFrozen() == true`). See
"Live verification" below.

## Live verification (2026-11-26)

After steps 0-3 of "Fix the live deployment" (new receivers on Unichain, new RCs on Lasna, `CheckReactive` ALL
CHECKS PASSED), the guardian restored vault A and the demo machinery froze it again. The new `TenureFreezeRC`
relayed that FROZEN to vault B. All txs are on Unichain Sepolia (chain 1301). Steps 1-5 were sent by the deployer
`0xD9df64Cb859206eECF3761ec4eb5057B579438A2`; the relay was sent by the network through the callback proxy.

| # | Step | Block | Tx | Hook / receiver events |
|---|---|---:|---|---|
| 1 | `requestRestore(A)` | 68,836,944 | [`0x1fa6170a...a443ae`](https://sepolia.uniscan.xyz/tx/0x1fa6170ab1c2179ee8a1abdf6a72ebbdb0de6e5655dc29f5bd722efd79a443ae) | `RestoreRequested` |
| 2 | `restore(A)` (608 blocks later; timelock 600) | 68,837,552 | [`0x2c73d02b...61b2a`](https://sepolia.uniscan.xyz/tx/0x2c73d02bbec5774e33e4247019255435443656faf56fa34aff0037f1d6961b2a) | `TierChanged(A, FROZEN, RESTRICTED)`, `Restored` |
| 3 | `DemoDirector.tick()`: curator parks (**verified**) | 68,837,588 | [`0x7c07e27e...499af`](https://sepolia.uniscan.xyz/tx/0x7c07e27e289238a25251e461b8cc7510085b60bc52637594fbbf2049dce499af) | rebalance session, `RebalanceScored` |
| 4 | `DemoDirector.tick()`: attack round 3 (**verified**) | 68,837,703 | [`0x586fd4af...6c1e`](https://sepolia.uniscan.xyz/tx/0x586fd4af5bf18768197530ce3cf411a3649e00238b9470ae65a648f6d7bb6c1e) | `MarkoutSettled`, rebalance session, `RebalanceScored` |
| 5 | `settleMany(A, [6, 7])`: **Unichain freeze** | 68,837,823 | [`0xd31fd9de...69051`](https://sepolia.uniscan.xyz/tx/0xd31fd9de3c171b1d174253ca8d7f5e81c1a4ff36a5be6608ce8629c71d469051) | `MarkoutSettled`, `TierChanged(A, RESTRICTED, FROZEN)` |
| 6 | **Lasna reaction**: `0x8888` -> `TenureFreezeRC.react()` | Lasna 9,291,302 | [`0x40e3a5e7...68c3ed`](https://lasna.reactscan.net/tx/0x40e3a5e7e3184993eccf23c3c7d1bc6459e4ace17beefd5c9a274fc22368c3ed) | RC: `FreezeRelayRequested(1301, 1301, vault B)`; `0x8888`: callback request to chain 1301, RC `0xD543...C93F` -> receiver `0x8466...E5FD` |
| 7 | **Unichain relay**: callback proxy -> `TenureFreezeReceiver` -> vault B | 68,837,825 | [`0xede7e97d...a9696`](https://sepolia.uniscan.xyz/tx/0xede7e97dbbaa5b0a1290f479ac21b5e096d3a4ab8371c16b248a933cd44a9696) | `FreezeRelayed(B, 1301, A)` |

Tick labels, verified by reading the director's `note()` right after each tick:

- Step 3: "poisoned curator parks its range 1,500 ticks away from the price | TIER -> RESTRICTED".
- Step 4: "ATTACK round 3: push spot -400 ticks, curator follows, arb back; attacker +133 tokens".

- The relay landed **2 Unichain blocks** after the freeze: Unichain freeze (68,837,823) -> Lasna reaction
  (9,291,302) -> Unichain relay (68,837,825).
- The Lasna reaction tx was identified with read-only log queries on Lasna. It is the only `FreezeRelayRequested` the RC
  emitted in Lasna blocks 9,291,250-9,291,450. Its payload matches the relay (vault B, chain 1301, the new
  receiver). Its sender was `0x038e06667e42782e571eab20432b9237f9bd6b82`, and the tx went to `0x8888`. Block
  timestamps: Unichain freeze 1795690251, Lasna reaction 1795690250, Unichain relay 1795690253. The 1 s gap
  between the freeze and the reaction is clock skew between the two chains, since the reaction cannot come
  before the freeze.
- Relay tx: from `0xF9F61C1D3325e2d4aBb55dd9e0Db84F7A0D914B0` to the callback proxy
  `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`. `FreezeRelayed` is emitted by the new receiver
  `0x846698c02b01Ea6126deb50705338D812878E5FD` with topics vault B `0x68d4571Fb9720d26353F643d0B4Bc56E044F442A`,
  origin chain `1301` (`0x515`), pool A `0x159454e0f739d43fa36a9bc9ffd1a7018a6847f00d579a80566111f83cc1ceff`.
- Read back afterwards: `tierOf(A) == 2` (FROZEN), vault B `relayFrozen() == true`.
- Freeze RC on Lasna:
  [`0xD54357c1aB69b660c7211A0Dba69198F8e9cC93F`](https://lasna.reactscan.net/address/0xD54357c1aB69b660c7211A0Dba69198F8e9cC93F)
  (reaction tx: step 6 above). Settler RC:
  [`0xfB5F3B736A5A0b5F244d629D36d876333B3FB646`](https://lasna.reactscan.net/address/0xfB5F3B736A5A0b5F244d629D36d876333B3FB646).
- New Unichain receivers: `TenureFreezeReceiver` `0x846698c02b01Ea6126deb50705338D812878E5FD`,
  `TenureReactiveReceiver` `0xb326BE901cc39ac314b176a96176dAE0C6D0c7f0`. The legacy RCs and receivers listed in
  this document are stranded and no longer used.

### Settler: what is proven live, and what only by tests (checked 2026-11-26, read-only)

The settler RC is live and reacting, but it has **not yet delivered a settlement callback** on testnet.

- **Settler RC reacted to pool A's events on Lasna.** It reacted to `RebalanceScored` and `MarkoutSettled` (all
  four txs succeeded, all from `0x038e06667e42782e571eab20432b9237f9bd6b82` to `0x8888`):

  | Event | Lasna block | Tx |
  |---|---:|---|
  | `Queued(6, due 9,291,147)` | 9,291,087 | `0x8e18e43beddd3b7ae4166c4caefbc8d9c3b680bd6592f7c625ab0f790f2a571b` |
  | `Dropped(6)` | 9,291,191 | `0x2212783ef81933cc8ed623d56612bb05e5e9a35176c2e4e203f4f962a4279144` |
  | `Queued(7, due 9,291,251)` | 9,291,191 | `0x7a2498e39771f0a752b8dff5ad4bb877bfa8c278f440d5fa02b049f24e714afa` |
  | `Dropped(7)` | 9,291,302 | `0x0c2caa5a5d379f561895bbeff11eeb9ea3d22f25363051e672fde38d0d946d65` |

- **No settlement callback yet.** The RC emitted no `SettleRequested` between its deploy (Lasna 9,289,404) and
  9,300,482. `TenureReactiveReceiver` `0xb326...c7f0` emitted no `ReactiveSettle`, or any other log, between its
  deploy (Unichain 68,835,437) and 68,847,901. Both ranges were scanned in 1,000-block chunks.
- **Why no callback.** Each record was settled on Unichain before the RC's next Cron1000 tick (Lasna 9,292,000):
  - record 6 by `afterSwap` auto-settlement in the attack tick;
  - record 7 by the manual `settleMany`.

  So the RC dropped both records before either was sent. Ticks 100-210 ran with A FROZEN, which means no
  rebalances and no new records.
- **Cron reactions: indirect evidence only.** The RC's reserves at `0x8888` fell from the deposited 0.8 to
  0.6094 lREACT, its debt is 0 and `subscribed()` is true. The 0.19 lREACT spent is consistent with about 11
  Cron1000 ticks (one per 1,000 of the ~11,078 blocks) plus the 4 event reactions. A cron tick with nothing due
  emits no log, so these reactions cannot be identified by log queries on the public RPC. Their txs may be
  visible on the settler's reactscan page linked above.
- **Covered only by tests: the callback path** (cron tick, then `SettleRequested`, then
  `TenureReactiveReceiver.settleMany`, then `ReactiveSettle`). Tests:
  - `test/reactive/ReactiveSettlement.t.sol`;
  - `test/reactive/ReactiveConformance.t.sol`, on `ReactiveNetworkSim`, which bills and injects the RC like the
    live network.
- **To prove it live:** let a scored record sit for 60+ Lasna blocks with no swap and no manual settle, then watch
  for `ReactiveSettle` on the receiver.

## Summary

Both Lasna reactive contracts (RCs) were blacklisted the first time the network delivered an event to them:

- `TenureSettlerRC` `0x19bFfFD599291bE1FfC98B45C6C8F11Ad2BCef10`: on its first Cron100 tick.
- `TenureFreezeRC` `0x3f04BD2701541Fb3f0B6E924095435715A9F7150`: on the demo vault's `TierChanged -> FROZEN`.

So the FROZEN on vault A was never relayed to vault B.

The first diagnosis ("the script funded the RC's balance instead of its reserves") is true, but it is not the root
cause. Funding the reserves would not have saved these contracts. They were built on the **legacy Reactive library**
(`reactive-lib` f6990ce, April 2025), which the live network no longer serves correctly:

1. **`react()` reverts "VM only".** The legacy library guards `react()` with `vmOnly`. Its `vm` flag is
   `extcodesize(0x...fffFfF) == 0`, set in the constructor. On Lasna, `0x...fffFfF` has code (22,151 bytes), so
   `vm == false`. Today the system contract `0x8888...8888` calls `react()` directly on the deployed contract
   (docs: "the system contract calls `react()`"), and every reaction reverts.
2. **`pay()` rejects the real system contract.** The legacy `pay()` only accepts `0x...fffFfF`. When the failed
   reaction was billed and the reserves were empty, `0x8888` called `pay()`, got "Authorized sender only", logged
   `PaymentFailure`, and blacklisted the contract. `coverDebt()` cannot help either: it pays whatever debt
   `0x...fffFfF` reports, and that ledger shows 0.
3. **The receivers trust the wrong sender.** The current callback proxy injects the **requesting reactive
   contract's address** as the first callback argument (docs: "Reactive Network replaces the first 160 bits of the
   payload with the address of the reactive contract that requested the callback"). The legacy `AbstractCallback`
   compares that argument to its **deployer** (`rvm_id = msg.sender`). So even a working RC would have had every
   callback rejected by `TenureFreezeReceiver` and `TenureReactiveReceiver`.
4. **Latent settler bug.** `TenureSettlerRC` set each record's due block as `log.block_number` (a Unichain
   Sepolia block, about 68.8M) plus `delayBlocks`, then compared it with Lasna cron block numbers (about 9.2M). No
   record would ever have been due.

Why the tests stayed green: `reactive-test-lib` models the retired flow. It pranks `react()` from `0x...fffFfF`,
forces "VM mode" (`enableVmMode`), injects the deployer as the RVM id, and its `debt()` is a no-op that never
bills. None of the four failures above could show up in it.

## Evidence (all read-only; reproduce with the commands shown)

| Claim | Command / source | Result |
|---|---|---|
| RC balances | `cast balance <rc> --ether --rpc-url https://lasna-rpc.rnk.dev/` | freeze 2.0, settler 5.0 lREACT |
| Debt lives at 0x8888 | `cast call 0x8888888888888888888888888888888888888888 "debt(address)(uint256)" <rc>` | freeze 12323500000000000, settler 12276500000000000 |
| Reserves are 0 | same contract, `"reserves(address)(uint256)"` | 0 and 0 |
| The legacy ledger reads 0 | `cast call 0x0000000000000000000000000000000000fffFfF "debt(address)(uint256)" <rc>` | 0 (this is the ledger the RC's `coverDebt()` reads) |
| `0x...fffFfF` has code on Lasna | `cast codesize 0x0000000000000000000000000000000000fffFfF` | 22151 |
| `react()` reverted "VM only" | `0x8888` log `0xe2ec8138...` in tx `0x40840f4f1ccb8cb9820485aa130b91c62bc7e9dd1a5e44ec07ae2e83f7fda0e6` (block 9229757, freeze RC, the `TierChanged` of pool A with chain 1301 and hook `0xBe78...8A40`) and in tx `0x66c3793410c26b7e7f44279aee39a5a19074a9381e5dd7954e54c9b0d7440c28` (block 9221001, settler RC, a Cron100 log) | revert data `0x08c379a0...07 564d206f6e6c79` = `Error("VM only")` |
| Payment failed, then blacklisted | the same two txs | `PaymentFailure(address,uint256)` (topic `0xade42888...`), amount = the debt above, then `BlacklistContract(address)` (topic `0x93013657...`) |
| `pay()` rejects 0x8888 | `cast call <rc> "pay(uint256)" 1 --from 0x8888888888888888888888888888888888888888` | `Authorized sender only` |
| The RC's ACL and vendor | `cast storage <rc> 0`; `cast storage <rc> $(cast index address <addr> 1)` | vendor = `0xffffff`; `senders[0xfffFfF]` = 1, `senders[0x8888]` = 0 |
| Subscriptions were made via the legacy address | logs of deploy txs `0x3a49d497...` and `0x182ac81a...` | 5 subscription events emitted by `0x...ffffff` (2 for freeze, 3 for settler) |
| Unichain receivers never called | `cast call 0x775c9B990ADe401060B78D0e98684eEf8d2466C1 "debt(address)(uint256)" <recv>` / `reserves` | both 0 / 0; balances 0.002 ETH each |
| Current library | github.com/Reactive-Network/reactive-lib-omni @ `3ade0dcf` (2026-05-21) | `SYSTEM = 0x8888`, `react` guarded by `onlySystem`, `pay` accepts only `_SERVICE_PROVIDER`, `AbstractCallback(proxy, callbackSender)` with `onlyCallbackSender` |
| Fee model | `_gasPriceCoeffPer1000()` = 1000, `_extraGas()` = 100000, `_maxChargeGas()` = 50000 on 0x8888; `cast basefee` = 100 gwei | fee = 100 gwei * (gas + 100k). The failed reactions cost ~23k gas: 0.0123 lREACT each |
| Lasna block time | timestamps of blocks 9220917 and 9236404 | 1.085 s/block |

Docs read on 2026-11-25: dev.reactive.network/economy (balances, reserves, debt, `depositTo`, `pay`,
blacklisting, `debt`/`reserves` views), /reactive-contracts (current base contract, cron topics,
`requestCallbackV_1_0`), /callback-contracts (proxy billing, `InDebt`), /origins-and-destinations (Unichain
Sepolia proxy `0x775c9B990ADe401060B78D0e98684eEf8d2466C1`), /legacy/reactive-library (the old `vmOnly`/`rvmIdOnly`
model). Not documented: whether subscriptions survive a blacklist/whitelist cycle. The docs say "Subscriptions live
in the node" and that service resumes when the debt reaches 0. Our simulator models resumption without
re-subscribing. For our redeploy this does not matter.

## Can the legacy contracts be revived?

No. Do not spend lREACT on them:

- `depositTo(<legacy rc>)` would clear the debt and whitelist them. Every later reaction still reverts "VM only"
  and is billed (`test_legacyPattern_isBlacklistedOnFirstEvent_andItsBalanceIsStranded` shows this).
- Their 2 + 5 lREACT balances are stranded. `pay()` only answers `0x...fffFfF`, and `coverDebt()` pays the 0 that
  `0x...fffFfF` reports. Nothing else can move funds out.
- The old Unichain receivers (0.002 ETH each, stranded the same way) reject every current callback (point 3).

## Code fix (this commit)

- `lib/reactive-lib-omni` pinned at `3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8` (the official current base,
  remapped `reactive-lib-omni/`). The legacy `reactive-lib` stays in `lib/`, used only by the regression test.
- `TenureFreezeRC` / `TenureSettlerRC`:
  - `onlySystem` `react()`;
  - subscribe through `SYSTEM` (`0x8888`; cron filter on the legacy emitter, as the docs show);
  - callbacks via `SYSTEM.requestCallbackV_1_0` (the `Callback` event is marked deprecated in the library);
  - public `coverDebt()`;
  - `subscribed()` view.
  
  The settler's deadlines now run on the Reactive chain's own `block.number`.
- `TenureFreezeReceiver` / `TenureReactiveReceiver`: `AbstractCallback(proxy, <their RC>)`, `onlyServiceProvider` +
  `onlyCallbackSender`, public `coverDebt()`. The SAFETY INVARIANT (the relay can only freeze) is unchanged.
- Funding: reserves through `depositTo` at the system contract (RCs, lREACT) and at the callback proxy
  (receivers, ETH), checked after the deposit (`script/base/ReactiveWiring.sol`). Cron100 becomes Cron1000 (about
  10 lREACT/day becomes about 1 lREACT/day).
- Address wiring: the receivers are built for the RC addresses that the deployer's next Lasna CREATEs produce
  (`LASNA_NONCE`). `DeployLasna` refuses to broadcast if those addresses would differ.
- Tests: `test/reactive/utils/ReactiveNetworkSim.sol` replaces `reactive-test-lib`. It is a system contract at
  `0x8888` that calls `react()`, bills `100 gwei * (gas + 100k)`, spends reserves first, then `pay()`,
  `PaymentFailure`, blacklist and skip, with code at `0x...fffFfF` (as on Lasna). It also models a callback proxy
  that injects the requesting RC, refuses indebted recipients and bills them.
  `test/reactive/ReactiveConformance.t.sol` replays this incident with the legacy-library pattern (same revert,
  same events, same stranded balance) and checks each funding path of the fixed contracts.
- `script/CheckReactive.s.sol`: read-only post-deploy verification of both chains. Run against today's live
  contracts, it reports 14 failures.

## Fix the live deployment (human, `--account tenure-burner`; done 2026-11-26)

Hook, pools, vaults and their funds stay as they are. New: 2 receivers on Unichain and 2 RCs on Lasna. Vault B is
re-pointed to the new freeze receiver. Vault A is owned by the DemoDirector and keeps the old receiver: A can
SEND a freeze to B but cannot RECEIVE one, and that is the direction the demo shows.

Budget (dry runs, 2026-11-25): Unichain about 1.14M gas (< 0.00001 ETH) + 2 x 0.002 ETH reserves. Lasna about
2.53M gas (about 0.25 lREACT at the 100 gwei basefee) + 0.3 + 0.8 lREACT reserves = about 1.35 lREACT. The deployer
has 1.71 lREACT and 0.0358 ETH.

```bash
D=0xD9df64Cb859206eECF3761ec4eb5057B579438A2
LASNA=https://lasna-rpc.rnk.dev/
UNI=https://sepolia.unichain.org

# 0. Lasna nonce N: send NO other Lasna tx until step 2 is done (expected today: 2)
export LASNA_NONCE=$(cast nonce $D --rpc-url $LASNA); echo $LASNA_NONCE

# 1. Unichain: 2 receivers bound to the RCs at Lasna nonces N and N+1, reserves at the proxy, vault B re-pointed.
#    Rewrites deployments/1301.json (old receivers kept as *Legacy, plus expectedFreezeRC/expectedSettlerRC).
FOUNDRY_PROFILE=deploy forge script script/DeployReceivers.s.sol --rpc-url $UNI \
  --account tenure-burner --sender $D --broadcast --slow

# 2. Lasna: freezeRC (nonce N), settlerRC (N+1), then depositTo reserves; refuses if any address differs.
#    Rewrites deployments/5318007.json.
FOUNDRY_PROFILE=deploy forge script script/DeployLasna.s.sol --rpc-url $LASNA \
  --account tenure-burner --sender $D --broadcast --slow

# 3. Read-only: both chains must print ALL CHECKS PASSED
forge script script/CheckReactive.s.sol
```

Read-only spot checks (the same things `CheckReactive` verifies; `$FRC`/`$SRC` from deployments/5318007.json,
`$FR`/`$SR` from deployments/1301.json):

```bash
S=0x8888888888888888888888888888888888888888; P=0x775c9B990ADe401060B78D0e98684eEf8d2466C1
for rc in $FRC $SRC; do
  cast call $S "debt(address)(uint256)" $rc --rpc-url $LASNA       # 0  => ACTIVE ("status follows debt")
  cast call $S "reserves(address)(uint256)" $rc --rpc-url $LASNA   # > 0
  cast call $rc "_SERVICE_PROVIDER()(address)" --rpc-url $LASNA    # 0x8888...8888 (reverts on a legacy RC)
  cast call $rc "subscribed()(bool)" --rpc-url $LASNA              # true
done
cast call $FR "_CALLBACK_SENDER()(address)" --rpc-url $UNI          # == $FRC
cast call $SR "_CALLBACK_SENDER()(address)" --rpc-url $UNI          # == $SRC
for r in $FR $SR; do cast call $P "debt(address)(uint256)" $r --rpc-url $UNI; cast call $P "reserves(address)(uint256)" $r --rpc-url $UNI; done
cast call 0x68d4571Fb9720d26353F643d0B4Bc56E044F442A "freezeReceiver()(address)" --rpc-url $UNI   # == $FR
```

Subscription status is not served over the public Lasna RPC (`rnk_getSubscribers`: "method does not exist").
Check it on https://lasna.reactscan.net (both RCs should show their subscriptions as ACTIVE).

### Keep the settler funded

The settler starts with 0.8 lREACT of reserves. It pays about 0.013 lREACT per Cron1000 tick (about 80 ticks a
day), plus one reaction per `RebalanceScored` / `MarkoutSettled` of pool A. That is roughly 1 lREACT a day, so
0.8 lREACT lasts under a day. Check it daily until the deadline.

Check the remaining reserves and debt (read-only):

```bash
S=0x8888888888888888888888888888888888888888; LASNA=https://lasna-rpc.rnk.dev/
SRC=$(python -c "import json;print(json.load(open('deployments/5318007.json'))['settlerRC'])")
cast call $S "reserves(address)(uint256)" $SRC --rpc-url $LASNA | cast from-wei   # lREACT left
cast call $S "debt(address)(uint256)" $SRC --rpc-url $LASNA                       # must be 0 (else INACTIVE)
cast balance $D --ether --rpc-url $LASNA                                          # what you can deposit
```

Top it up (`depositTo` pays off any debt first, then adds the rest to the reserves; never send lREACT straight
to the RC):

```bash
cast send $S "depositTo(address)" $SRC --value 1ether --rpc-url $LASNA --account tenure-burner
cast call $S "reserves(address)(uint256)" $SRC --rpc-url $LASNA | cast from-wei   # confirm it rose
```

- **If the debt was not 0:** the deposit reactivates the settler. Ticks missed while it was INACTIVE are not
  replayed, but nothing is lost: pending records go out on the next tick, and pool A's `afterSwap` auto-settlement
  keeps working throughout.
- **If your wallet is low:** the official faucet pays out on Lasna from Ethereum Sepolia (1 ETH = 100 lREACT;
  docs/DEPLOY.md step 4).

The freeze RC (0.3 lREACT) is billed only on `TierChanged` events of pools A and B, so it rarely needs a top-up.
Use the same two commands with its address (`freezeRC` in deployments/5318007.json).

Receivers, in ETH at the callback proxy: `cast send $P "depositTo(address)" <recv> --value 0.002ether --rpc-url
$UNI --account tenure-burner`.

## Known limitation: vault A cannot receive a relayed freeze

The demo vault A is owned by its `DemoDirector`, which can only enter safe mode, so `setFreezeReceiver` cannot be
called on it. After the repair, A keeps the old (dead) receiver:

| Direction | Works? | Why |
|---|---|---|
| FROZEN on A -> relayed to B | yes | A's `TierChanged` comes from the hook; B points at the new freeze receiver |
| FROZEN on B -> relayed to A | no | A's `freezeReceiver` is the legacy receiver, which rejects every current callback |

The demo shows the A-to-B direction, so this is accepted (human decision, 2026-11-26). Both directions are tested
(`test/reactive/FreezePropagation.t.sol`: `test_frozenOnA_blocksCuratorOnB_withdrawalsStayOpen`,
`test_frozenOnB_blocksCuratorOnA`). A fresh deployment with the fixed `DeployUnichainSepolia` wires both vaults
before ownership moves to the director, so it does not have this limitation.

## A fresh freeze to show the relay (5 Unichain txs, no hook change)

Vault A is FROZEN. The guardian (the deployer) restores it, then the existing demo machinery freezes it again. That
emits a new `TierChanged(A, RESTRICTED, FROZEN)`, which the new FreezeRC relays to vault B.

Simulated on an anvil fork of live Unichain Sepolia (block 68,780,274, impersonated guardian, nothing sent to the
chain):

- `restore` landed A in RESTRICTED;
- tick 1: "poisoned curator parks its range 1,500 ticks away";
- tick 2: "ATTACK round 3: push spot -400 ticks, curator follows";
- `settleMany([6,7])` after the window: A FROZEN at 14.4% budget.

Without step 5 (only ticks), it took 51 ticks.

Do this only AFTER step 3 above passes:

```bash
H=0xBe78c4327a48414e0C9701a3B5840da39D828A40
A=0x159454e0f739d43fa36a9bc9ffd1a7018a6847f00d579a80566111f83cc1ceff
DIR=0x4503973606187A6b0eE288Da074762ca51BE80f1
cast send $H "requestRestore(bytes32)" $A --rpc-url $UNI --account tenure-burner          # 1
# wait 600 blocks (~10 min): cast call $H "restoreEta(bytes32)(uint256)" $A ; cast block-number --rpc-url $UNI
cast send $H "restore(bytes32)" $A --rpc-url $UNI --account tenure-burner                 # 2  A -> RESTRICTED
cast send $DIR "tick()" --gas-limit 3000000 --rpc-url $UNI --account tenure-burner        # 3  curator parks
# wait ~25 blocks (RESTRICTED cooldown = 2 x 10)
cast send $DIR "tick()" --gas-limit 3000000 --rpc-url $UNI --account tenure-burner        # 4  attack round
cast call $DIR "note()(string)" --rpc-url $UNI     # must say "ATTACK round ..."; if not, wait 25 blocks, repeat 4
# wait 60 blocks (window W = 50), then settle the pending records (ids settlePointer .. recordCount-1)
cast call $H "settlePointer(bytes32)(uint256)" $A --rpc-url $UNI; cast call $H "recordCount(bytes32)(uint256)" $A --rpc-url $UNI
cast send $H "settleMany(bytes32,uint256[])" $A "[6,7]" --gas-limit 3000000 --rpc-url $UNI --account tenure-burner  # 5
cast call $H "tierOf(bytes32)(uint8)" $A --rpc-url $UNI          # 2 = FROZEN
```

Then watch the relay arrive (it takes about a minute: Unichain event, Lasna reaction, Unichain callback):

```bash
cast call 0x68d4571Fb9720d26353F643d0B4Bc56E044F442A "relayFrozen()(bool)" --rpc-url $UNI   # true = B frozen
# All three FreezeRelayed parameters are indexed: the signature must say so, or cast cannot decode the log.
# The public Unichain RPC serves at most 1,000 blocks per log query, so scan the last 3,000 blocks in chunks.
SIG="FreezeRelayed(address indexed,uint256 indexed,bytes32 indexed)"
TO=$(cast block-number --rpc-url $UNI)
for FROM in $(seq $((TO - 2999)) 1000 $TO); do
  END=$((FROM + 999)); [ $END -gt $TO ] && END=$TO
  cast logs --address $FR "$SIG" --from-block $FROM --to-block $END --rpc-url $UNI
done
```

Live example (one chunk around the 2026-11-26 relay; decodes `param0` = vault B, `param1` = 1301,
`param2` = pool A):

```bash
cast logs --address 0x846698c02b01Ea6126deb50705338D812878E5FD \
  "FreezeRelayed(address indexed,uint256 indexed,bytes32 indexed)" \
  --from-block 68837000 --to-block 68837999 --rpc-url https://sepolia.unichain.org
```

Afterwards, vault B's curator stays blocked until the guardian lifts it:
`cast send 0x68d4571Fb9720d26353F643d0B4Bc56E044F442A "clearRelayFreeze()" --rpc-url $UNI --account tenure-burner`.

The record ids `[6,7]` are the fork's values. Use whatever `settlePointer .. recordCount-1` shows at that time. If
step 5 leaves A RESTRICTED, run steps 4 and 5 once more. The fork needed one attack round from 35% budget.

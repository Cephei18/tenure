# Incident: the Lasna reactive contracts went INACTIVE on their first event (2026-11-25)

**Status:** root cause found and fixed in code (tests and dry runs pass against the live chains). The live
contracts still need the human steps in "Fix the live deployment".

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

## Fix the live deployment (human, `--account tenure-burner`; nothing here was broadcast)

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

Top-ups later (debt is settled first, then reserves): `cast send $S "depositTo(address)" <rc> --value 0.5ether
--rpc-url $LASNA --account tenure-burner`. For a receiver: `cast send $P "depositTo(address)" <recv> --value
0.002ether --rpc-url $UNI --account tenure-burner`.

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
cast logs --address $FR "FreezeRelayed(address,uint256,bytes32)" \
  --from-block $(( $(cast block-number --rpc-url $UNI) - 2000 )) --rpc-url $UNI
```

Afterwards, vault B's curator stays blocked until the guardian lifts it:
`cast send 0x68d4571Fb9720d26353F643d0B4Bc56E044F442A "clearRelayFreeze()" --rpc-url $UNI --account tenure-burner`.

The record ids `[6,7]` are the fork's values. Use whatever `settlePointer .. recordCount-1` shows at that time. If
step 5 leaves A RESTRICTED, run steps 4 and 5 once more. The fork needed one attack round from 35% budget.

# Deploying Tenure to Unichain Sepolia + Reactive Lasna

Nothing here has been broadcast yet. The scripts were dry-run against the live chains and run end to end on
anvil (see "Verification done"). Every external address comes from `deployments/config.json`, which cites an
official source per value.

## Human checklist (only what YOU must do, in order)

Burner wallet: `0xD9df64Cb859206eECF3761ec4eb5057B579438A2`, Foundry keystore `tenure-burner`. Testnet only.
Run everything from the repo root in Git Bash. `SEPOLIA_RPC` is any Ethereum Sepolia RPC you trust (no official
doc names one).

1. **Check the keystore** (no password needed):
   ```bash
   cast wallet address --account tenure-burner   # must print 0xD9df64Cb859206eECF3761ec4eb5057B579438A2
   ```
2. **Get about 0.25 Sepolia ETH** on Ethereum Sepolia (11155111) from a faucet you trust. No official Unichain or
   Reactive doc recommends one. Optional shortcut for the Unichain part only: the Superchain faucet
   (https://console.optimism.io/faucet) or QuickNode (https://faucet.quicknode.com/unichain/sepolia), both listed
   in the Unichain docs, pay out directly on Unichain Sepolia; then skip step 3.
3. **Bridge 0.03 ETH to Unichain Sepolia** (official L1StandardBridge; arrives in a few minutes):
   ```bash
   cast send 0xea58fcA6849d79EAd1f26608855c2D6407d54Ce2 --value 0.03ether \
     --rpc-url "$SEPOLIA_RPC" --account tenure-burner
   ```
   Or use https://superbridge.app/unichain-sepolia.
4. **Get 15 lREACT on Lasna** (official faucet; 1 ETH = 100 lREACT; never send more than 5 ETH per tx):
   ```bash
   cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 "request(address)" 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 \
     --value 0.15ether --rpc-url "$SEPOLIA_RPC" --account tenure-burner
   ```
5. **Check balances** (read-only):
   ```bash
   cast balance 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --ether --rpc-url https://sepolia.unichain.org   # >= 0.02
   cast balance 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --ether --rpc-url https://lasna-rpc.rnk.dev/      # >= 10
   ```
6. **Deploy on Unichain Sepolia.** Type the keystore password when prompted:
   ```bash
   FOUNDRY_PROFILE=deploy forge script script/DeployUnichainSepolia.s.sol \
     --rpc-url https://sepolia.unichain.org --account tenure-burner \
     --sender 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --broadcast --slow
   ```
   This writes `deployments/1301.json`.
7. **Deploy on Lasna** with the SAME account (the Unichain receivers only accept callbacks from RCs deployed by
   their own deployer):
   ```bash
   FOUNDRY_PROFILE=deploy forge script script/DeployLasna.s.sol \
     --rpc-url https://lasna-rpc.rnk.dev/ --account tenure-burner \
     --sender 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --broadcast --slow
   ```
   This writes `deployments/5318007.json`.
8. **Run the demo:** `bash script/demo_testnet.sh` (110 transactions; see "Run the demo" for `PASSWORD_FILE`, which avoids 111 password
   prompts, and for `RPC`, to switch endpoints if the public one times out).
9. **Record the addresses** from `deployments/1301.json` and `deployments/5318007.json` in the README.

## Funding estimate

Gas from the dry runs (2026-11-25). Unichain Sepolia: 41.5M gas, max fee 0.001 gwei. Lasna: 2.76M gas, max fee
200 gwei (base 100).

| Chain | Need | What for | Ask for (with margin) |
|---|---:|---|---:|
| Unichain Sepolia | ~0.00004 ETH | deployment (41.5M gas) | |
| | 0.004 ETH | pre-funding of the two callback receivers (`receiverFundingWei` x 2) | |
| | <= 0.0004 ETH | demo: 111 txs at the 3M `GAS_LIMIT` (upper bound; measured use is at most 1.43M per tick) | |
| | **~0.0045 ETH** | | **0.03 ETH** (absorbs a 10x gas spike) |
| Lasna | 0.55 lREACT | deployment (2.76M gas at 200 gwei) | |
| | 7 lREACT | pre-funding of the RCs (settler 5, freeze 2: `tenure.reactive.*FundingWei`) | |
| | **~7.6 lREACT** | | **15 lREACT = 0.15 Sepolia ETH** to the faucet |
| Ethereum Sepolia | ~0.18 ETH | 0.15 (lREACT faucet) + 0.03 (bridge) + gas for those 2 txs | **0.25 ETH** |

Balances at the read-only check (2026-11-25): **0 on all three chains** (Unichain Sepolia, Ethereum Sepolia,
Lasna). The RC funding pays reactive transactions and callbacks over time, and the CRON subscription is billed
every 100 Lasna blocks. The official pages read here give no per-transaction price, so watch the RC balances on
reactscan and top up if they run low (see Open items).

## What gets deployed

On Unichain Sepolia (`script/DeployUnichainSepolia.s.sol`, all inputs from `deployments/config.json`):

| Contract | Purpose |
|---|---|
| `TenureScorer` | External math library, deployed and linked by forge |
| `TenureHook` | CREATE2 at a mined address whose low bits carry its permissions (the CREATE2 deployer `0x4e59…956C` exists on 1301) |
| Pool A "demo": TDA/TDB mock tokens, `MockReferencePrice`, `CuratedVault`, scenario actors, `DemoDirector` | Replays the headline scenario, one `tick()` per tx. The mock oracle is required: the scenario's market moves the fair price |
| Pool B "chainlink": tWETH (18 dec) / tUSDC (6 dec) mock tokens, `ChainlinkReferencePrice` on the live ETH/USD and USDC/USD feeds, `CuratedVault` | Live Chainlink fair price. Same curator contract as pool A, so a FROZEN on A is relayed to B |
| `TenureReactiveReceiver`, `TenureFreezeReceiver` | Callback targets behind the official Reactive callback proxy `0x775c…66C1`, pre-funded for callbacks |

On Lasna (`script/DeployLasna.s.sol`): `TenureSettlerRC` (keeper-free settlement for pool A: `RebalanceScored`,
`MarkoutSettled`, and CRON every 100 Lasna blocks) and `TenureFreezeRC` (TierChanged on pools A and B), both
pre-funded with lREACT.

**Settings that differ from the local demo:**
- Pool B's `maxOracleAge` is 90,000 s, because the Chainlink testnet feeds have a 24 h heartbeat (86,400 s).
  At the read-only check (2026-11-25) ETH/USD was 1 h old and USDC/USD 21 h old. A pool with a 1 h maximum age
  would be stale most of the day.
- Pool A keeps 1 h and is refreshed by the demo itself (the market step updates the mock oracle).

## Deploy order and why

1. Unichain Sepolia first: the Lasna RCs subscribe to the hook's address and pool ids, and call the receivers.
2. Lasna second, from the same account: `rvm_id` (the RC deployer) must equal the receivers' deployer.
3. The demo last. Every tick emits `RebalanceScored`/`MarkoutSettled`/`TierChanged`; the RCs react to them.

## Verify on the explorer

The Unichain docs say Etherscan API V2 keys work for Unichain Sepolia
(https://developers.uniswap.org/docs/unichain/guides/deploy-a-smart-contract). With your own key:

```bash
FOUNDRY_PROFILE=deploy forge script script/DeployUnichainSepolia.s.sol --rpc-url https://sepolia.unichain.org \
  --account tenure-burner --sender 0xD9df64Cb859206eECF3761ec4eb5057B579438A2 --broadcast --slow \
  --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
```

Or verify one contract after the fact: `forge verify-contract <address> src/TenureHook.sol:TenureHook --chain 1301
--etherscan-api-key "$ETHERSCAN_API_KEY" --libraries src/libraries/TenureScorer.sol:TenureScorer:<scorer>`
(built with `FOUNDRY_PROFILE=deploy`). The verifier URL is not in the official docs (TODO in config.json); if
`--chain 1301` is not recognized, pass `--verifier-url` from Etherscan's API V2 docs. Lasna contracts:
https://lasna.reactscan.net (no verification flow is documented).

## Run the demo

```bash
bash script/demo_testnet.sh          # asks for confirmation, then sends 110 tick() txs + 1 withdraw
```

Without extra settings, `cast send --account tenure-burner` asks for the keystore password on every transaction.
To avoid 111 prompts, create a password file yourself and pass it as `PASSWORD_FILE`. Delete it afterwards:

```bash
read -rs -p "keystore password: " P; printf '%s' "$P" > /tmp/kp; unset P; chmod 600 /tmp/kp
PASSWORD_FILE=/tmp/kp bash script/demo_testnet.sh; rm -f /tmp/kp
```

With `PASSWORD_FILE` set, the script passes `--keystore ~/.foundry/keystores/tenure-burner --password-file
"$PASSWORD_FILE"` to `cast send` only, because Foundry's `--password-file` requires `--keystore`, not `--account`.
Read-only `cast call`s never get key or password flags. Do not export `ETH_PASSWORD`: it makes every `cast`
command, including read-only `cast call`, fail with "--keystore <PATH> required". The script unsets it, and it
exits with a clear message if the keystore file is missing.

**RPC.** The script uses `RPC`, which defaults to `https://sepolia.unichain.org`. That is the only keyless Unichain
Sepolia endpoint in the official docs
(https://developers.uniswap.org/docs/unichain/technical-information/network-information, marked "Not for
production use"). It is rate-limited and sometimes times out. The official Node Providers page
(https://developers.uniswap.org/docs/unichain/tools/node-providers) lists providers with Unichain Sepolia
support: Alchemy, Blockdaemon, Chainstack, dRPC, Dwellir, Infura, QuickNode and OnFinality. It gives no endpoint
URLs, and most of these need a free account or API key. To use one, set its Unichain Sepolia URL:

```bash
RPC="https://<your-provider-unichain-sepolia-url>" PASSWORD_FILE=/tmp/kp bash script/demo_testnet.sh
```

The script refuses any RPC whose chain id is not 1301.

**Gas limit.** Every transaction is sent with a fixed `GAS_LIMIT`, default 3,000,000; `eth_estimateGas` is
unreliable because `tick()` catches a failed curator call. Unichain Sepolia enforces the EIP-7825 per-transaction
gas cap of 16,777,216 (2^24). Anything above it is rejected with "error code -32003: gas limit too high", and the
script refuses to start with `GAS_LIMIT` above the cap. The default is about 2x the maximum measured on a local
fork over a full 110-tick run plus the withdraw (2026-11-25): 1,430,548 gas for the heaviest tick (an attack
round just before FROZEN) and 118,752 for the withdraw. The 2x margin matters because `tick()` swallows a failed
inner call: a limit that is too tight could starve the curator's rebalance (63/64 rule) without reverting the
tick, which would change the story. The script warns if any transaction uses more than half of `GAS_LIMIT`, and
prints the maximum gas used at the end. To override it: `GAS_LIMIT=4000000 PASSWORD_FILE=/tmp/kp bash
script/demo_testnet.sh`.

**If a transaction fails.** The script prints cast's error and exits non-zero; nothing fails silently. On a
timeout or connection error it does not resend blindly. It waits (3, 6, then 9 s), re-reads `ticks()` and the
sender's nonce, and then does one of three things:
- the tick landed: it carries on;
- the transaction is still pending: it waits;
- the transaction neither landed nor is pending: it resends, up to 3 retries.

Any other error (for example insufficient funds) or a reverted receipt stops the script at once. Re-running is
safe: the director continues from its current `ticks()`. The nonce check uses the deployer address from
`deployments/1301.json`. If your keystore holds a different address, set `SENDER=<that address>`.

**Stale fair price.** The demo pool's mock oracle is only updated by `tick()`, so after any pause longer than 1 h
it is stale. This does not block the demo: `tick()` publishes a fresh price (`Market.step` → `setPrice`, stamped
with the current block time) before any swap, settlement or rebalance reads it. Only the read-only `status()`
view reverts with `Tenure__StalePrice` until then. The script shows that as "status unavailable: the demo fair
price is stale", and also prints the price's age before the first tick.

On a live chain the ticks land a few 1-second blocks apart, so the 50-block markout window spans fewer ticks than
on anvil. The tick numbers differ from `docs/DEMO.md`, but the story is the same: poisoned at tick 20, then
RESTRICTED, then FROZEN with safe mode, and the depositor still withdraws.
What to watch for:
- **Unichain (Uniscan):** `RebalanceScored`, `MarkoutSettled`, `TierChanged` on the hook; `SafeMode` on vault A.
- **Lasna (reactscan):** the RCs' reactive transactions. Soon after FROZEN, vault B's `relayFrozen()` becomes
  true (`cast call <chainlinkVault> "relayFrozen()(bool)" --rpc-url https://sepolia.unichain.org`).
  `TenureReactiveReceiver` emits `ReactiveSettle` whenever the RC settles before a swap does.

## Open items (TODO: confirm before or while broadcasting)

- **Etherscan verifier URL for 1301.** The docs say an Etherscan API V2 key works but give no `--verifier-url`
  (config `unichainSepolia.verifierUrl` = TODO).
- **Ethereum Sepolia faucet and RPC.** No official Unichain or Reactive doc recommends one (config TODO). Use any
  you trust; it only affects step 2.
- **Reactive billing.** The cost per reactive transaction and per CRON event, and how to top up a deployed RC, were
  not in the pages read. The 5 / 2 lREACT RC funding is an estimate (config `tenure.reactive`).
- **Unichain Sepolia with Lasna.** The docs list Unichain Sepolia as an origin and a destination on testnet, and
  the callback proxy `0x775c…66C1`, but do not spell out the Unichain Sepolia / Lasna pairing in words. The
  Lasna fork rehearsal accepted the subscriptions, but a fork cannot show callbacks being delivered: watch the
  first `ReactiveSettle` / `relayFrozen` after broadcast.
- **Chainlink L2 sequencer-uptime feed for 1301.** Not found (config TODO). It is not used by Tenure today.
- **Chainlink feed freshness.** The testnet heartbeat is 24 h. If a feed misses an update, pool B's oracle goes
  stale past 25 h: deposits and rebalances there pause, and withdrawals still work.

## Verification done (no broadcast)

All on 2026-11-25, without broadcasting to any public chain:
- **Read-only checks:** every configured address has code on its chain: PoolManager (24,009 B), callback proxy,
  both Chainlink feeds (live: ETH/USD updated 1 h earlier, USDC/USD 21 h earlier), Permit2, the CREATE2 deployer,
  the L1 bridge and the lREACT faucet on Sepolia, and both Lasna system addresses. All 12 config addresses pass
  EIP-55 checksum checks.
- **Live dry run, Unichain Sepolia** (`forge script` with `--sender`, no `--broadcast`): SIMULATION COMPLETE,
  41,524,085 gas. Output: `deployments/1301.dryrun.json` (git-ignored). Because the burner's nonce is still 0,
  these addresses preview the real ones.
- **Live dry run, Lasna:** reaches the first RC and stops with `OutOfFunds`, because the burner has 0 lREACT for
  the RC funding. This is expected until step 4 of the checklist.
- **Rehearsal on anvil forks** (anvil test key, broadcast to the local fork only):
  - Unichain Sepolia fork (chain id 1301, real PoolManager, live Chainlink feeds): the full deployment succeeded,
    and 26 demo ticks (through the poisoning at tick 20) ran with 0 failed transactions.
  - Lasna fork: both RCs deployed, and Lasna's live system contract accepted their subscriptions (3 for the
    settler, 2 for the freeze RC).
- **Plain local anvil (31337):** both scripts' local branches deploy (own PoolManager, mock Chainlink feeds; the RCs
  run in ReactVM mode without subscriptions). `script/demo.sh` still runs end to end: FROZEN after 3 rounds.
- **Bug found and fixed:** forge 1.8.5 does not route `new TenureHook{salt}` through the CREATE2 factory when the
  script runs against a forked live chain. The hook landed at a script-derived address and reverted
  `HookAddressNotValid`. That would have broken a real broadcast, and the pre-existing `DeployTenureHook.s.sol`
  had the same bug. `script/base/TenureHookDeployer.sol` now calls the factory explicitly.

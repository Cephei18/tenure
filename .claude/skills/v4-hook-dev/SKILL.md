---
name: v4-hook-dev
description: Rules, pitfalls and test patterns for Uniswap v4 hook development in this repo. Use this skill before writing or changing ANY code that touches hooks, the PoolManager, pools, PoolKey/PoolId, liquidity modification, swaps, unlock callbacks, currency deltas, hook permissions or address mining, or any Foundry test that deploys a pool — even small edits. Also use it when a v4 test fails mysteriously (callbacks not firing, CurrencyNotSettled, HookAddressNotValid, wrong balances).
---

# Uniswap v4 hook development — Tenure rules

## Golden rule
Read the actual source in `lib/` before calling anything. v4-core, v4-periphery and the template's hook base
(OpenZeppelin uniswap-hooks or v4-periphery BaseHook) change signatures between versions. Grep first:
`grep -rn "function getSlot0\|function getPositionInfo\|function currencyDelta" lib/`.
Record any surprise in CLAUDE.md `## Learnings`.

## Permissions live in the address
- v4 reads hook permissions from the low bits of the hook ADDRESS, not from code. Wrong address = callbacks
  silently never fire (no revert).
- In tests, deploy to an address with the right flag bits (template pattern: compute flags from `Hooks.*_FLAG`
  constants and use `deployCodeTo` to that address), or mine a CREATE2 salt with HookMiner for scripts.
- Write a permissions test FIRST in the hook test file: assert `getHookPermissions()` matches the address bits, and
  that each enabled callback actually fires (e.g. counter/event).
- If you change permissions, you must change the deployment address/flags in tests and scripts too.
- Return-delta permissions (`*ReturnDelta`) are dangerous; Tenure does not need them. Don't enable them.

## Who is msg.sender / sender
- Inside a callback, `msg.sender` is the PoolManager (enforced by the base's onlyPoolManager).
- The `sender` argument is the contract that called `modifyLiquidity`/`swap` on the PoolManager — for Tenure that is
  the CuratedVault (for vault positions) or a router/other LP. It is never the off-chain curator.
- Identify vault actions by `sender == registeredVault[poolId]`. Pass extra context via `hookData` only if needed;
  never trust hookData for authorization.

## Flash accounting and mid-unlock state
- Inside `unlock`, token transfers are not settled yet; balances are tracked as currency deltas.
  A contract's real holdings mid-unlock = `token.balanceOf(contract)` + outstanding delta owed to it
  (see `TransientStateLibrary.currencyDelta` in v4-core). Snapshot holdings OUTSIDE the unlock when possible —
  Tenure's design does exactly this: `beginRebalance` before unlock, `endRebalance` after unlock.
- All deltas must net to zero before unlock returns, or the tx reverts with `CurrencyNotSettled`.
  Settle pattern: for negative delta (you owe) `sync` + transfer + `settle`; for positive delta (owed to you) `take`.
  Use the template/periphery `CurrencySettler` helper if present.
- v4 does not run hook callbacks when `msg.sender` is the hook itself. Don't make the hook modify liquidity on its own
  pool to "trigger" itself.

## Reading pool state
- Use `StateLibrary` (v4-core) via `using StateLibrary for IPoolManager`: `getSlot0(poolId)` for sqrtPriceX96/tick,
  `getPositionInfo` / `getPositionLiquidity` for a position's liquidity. Position key = owner + ticks + salt.
- Ticks must be multiples of `tickSpacing` and within `TickMath.MIN_TICK..MAX_TICK`. Bound fuzz inputs accordingly,
  and use `TickMath.minUsableTick/maxUsableTick(tickSpacing)` for full range.

## Transient storage (session flag)
- Use transient storage (tstore/tload) for the rebalance session flag so it can never leak across transactions.
  If the compiler/template supports `transient` state variables, either style is fine; be consistent.
- Slot constants: `uint256(keccak256("tenure.session")) - 1` pattern.

## Testing patterns
- Use the template's test base (e.g. `Deployers` or its fixtures) to deploy a real PoolManager, currencies, routers.
  Never fork mainnet.
- Every hook test file: (1) permissions/address test, (2) happy path, (3) each revert path with the exact custom
  error, (4) fuzz with `bound()`ed inputs, (5) events with `vm.expectEmit`.
- For multi-block behavior use `vm.roll(block.number + n)` and `vm.warp`.
- Gas: `forge snapshot` or `vm.snapshotGas*` if available; keep afterSwap loops bounded.
- Console tables: `console.log` / `console2.log` with fixed-width strings; write CSV with `vm.writeFile`
  (requires `fs_permissions` in foundry.toml for the docs/results path).

## Security checklist for hook code
- onlyPoolManager on all callbacks (base contract provides it — don't remove).
- No unbounded loops in callbacks. No external calls to untrusted contracts from callbacks.
- Reentrancy: `beginRebalance`/`endRebalance` must be callable only by the registered vault and must pair correctly.
- Oracle: check staleness and sanity vs spot; revert with clear custom errors.

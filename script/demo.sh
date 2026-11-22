#!/usr/bin/env bash
# Tenure local demo, part 2: replay scenario C (poisoned curator + Tenure) on anvil, one block per transaction.
#
#   anvil                                  # terminal 1 (fresh chain)
#   bash script/demo.sh                    # terminal 2
#
# Env: RPC (default http://127.0.0.1:8545), PK (default: anvil's PUBLIC test account #0 - never a real key),
#      TICKS (default 110), POISON_AT (default 20), EVERY (print a routine status line every N ticks, default 10).
# LOCAL ONLY. See docs/DEMO.md.
set -euo pipefail

RPC="${RPC:-http://127.0.0.1:8545}"
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}" # anvil test account #0
TICKS="${TICKS:-110}"
POISON_AT="${POISON_AT:-20}"
EVERY="${EVERY:-10}"
export POISON_AT

cd "$(dirname "$0")/.."

[ "$(cast chain-id --rpc-url "$RPC")" = "31337" ] || { echo "not a local anvil chain - refusing"; exit 1; }

echo "== 1/3 deploy (FOUNDRY_PROFILE=deploy: via-IR hook + linked TenureScorer library)"
out=$(FOUNDRY_PROFILE=deploy forge script script/Demo.s.sol --rpc-url "$RPC" --private-key "$PK" --broadcast 2>&1) || {
  echo "$out"; exit 1;
}
echo "$out" | grep -E "^  (PoolManager|TenureHook|CuratedVault|Curator|DemoDirector) +:|poison at" || true
DIRECTOR=$(echo "$out" | awk '/DemoDirector :/ {print $3}')
VAULT=$(echo "$out" | awk '/CuratedVault :/ {print $3}')
[ -n "$DIRECTOR" ] && [ -n "$VAULT" ] || { echo "could not parse addresses"; echo "$out"; exit 1; }
ME=$(cast wallet address --private-key "$PK")

status() { cast call "$DIRECTOR" "status()(string)" --rpc-url "$RPC" | sed 's/^"//; s/"$//'; }
num() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
# Fixed gas limit: the curator's try/catch makes eth_estimateGas unreliable (an estimate can starve the inner call).
# Every receipt is checked: a failed tick aborts the demo instead of silently skipping a block.
send() {
  local r
  r=$(cast send "$@" --rpc-url "$RPC" --private-key "$PK" --gas-limit 25000000 --json)
  echo "$r" | grep -q '"status":"0x1"' || { echo "transaction failed: $*"; echo "$r"; exit 1; }
}

echo
echo "== 2/3 replay: $TICKS blocks, curator poisoned at tick $POISON_AT"
echo "   $(status)"
for ((i = 1; i <= TICKS; i++)); do
  send "$DIRECTOR" "tick()"
  note=$(cast call "$DIRECTOR" "note()(string)" --rpc-url "$RPC" | sed 's/^"//; s/"$//')
  if [ -n "$note" ]; then
    echo ">> $note"
    echo "   $(status)"
  elif (( i % EVERY == 0 )); then
    echo "   $(status)"
  fi
done

echo
echo "== 3/3 withdrawals are never blocked, even when FROZEN"
T0=$(num "$VAULT" "currency0()(address)")
T1=$(num "$VAULT" "currency1()(address)")
shares=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME")
b0=$(num "$T0" "balanceOf(address)(uint256)" "$ME"); b1=$(num "$T1" "balanceOf(address)(uint256)" "$ME")
send "$VAULT" "withdraw(uint256,uint256,uint256,address)" "$shares" 0 0 "$ME"
a0=$(num "$T0" "balanceOf(address)(uint256)" "$ME"); a1=$(num "$T1" "balanceOf(address)(uint256)" "$ME")
python - "$b0" "$a0" "$b1" "$a1" <<'PY' || echo "   (install python to print the amounts)"
import sys
b0, a0, b1, a1 = map(int, sys.argv[1:])
print(f"   depositor redeemed ALL shares while FROZEN: received {(a0 - b0) / 1e18:,.2f} token0 + {(a1 - b1) / 1e18:,.2f} token1")
PY

ran=$(num "$DIRECTOR" "ticks()(uint256)")
[ "$ran" = "$TICKS" ] || { echo "expected $TICKS ticks, chain shows $ran"; exit 1; }
frozen=$(num "$DIRECTOR" "frozenAt()(uint256)")
restricted=$(num "$DIRECTOR" "restrictedAt()(uint256)")
rounds=$(num "$DIRECTOR" "rounds()(uint256)")
[ "$restricted" = "0" ] && restricted="(not sampled: FULL -> FROZEN within one block)"
echo
echo "summary: poisoned at tick $POISON_AT | RESTRICTED at tick $restricted | FROZEN + safe mode at tick $frozen"
echo "         attack rounds before the freeze: $rounds (static caps alone allowed 25 in the 600-block test)"

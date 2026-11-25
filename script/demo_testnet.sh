#!/usr/bin/env bash
# Tenure demo on Unichain Sepolia: replay the headline scenario against the DEPLOYED pool A, one tick() per tx.
# Requires a real `DeployUnichainSepolia` broadcast (deployments/1301.json). See docs/DEPLOY.md, "Run the demo".
#
#   bash script/demo_testnet.sh
#
# Env: RPC (default https://sepolia.unichain.org), ACCOUNT (Foundry keystore, default tenure-burner),
#      TICKS (default 110), EVERY (status line every N ticks, default 10).
#      Each tick is a transaction signed with the keystore: cast asks for the password every time, unless YOU set
#      ETH_PASSWORD to a password FILE for this shell (see docs/DEPLOY.md). This script never reads keys.
# Note: on a live chain ticks land a few blocks apart (1 s blocks), so the 50-block markout window spans fewer
# ticks than on anvil and the tick numbers differ from docs/DEMO.md; the sequence of events is the same.
set -euo pipefail

RPC="${RPC:-https://sepolia.unichain.org}"
ACCOUNT="${ACCOUNT:-tenure-burner}"
TICKS="${TICKS:-110}"
EVERY="${EVERY:-10}"
DEP="deployments/1301.json"

cd "$(dirname "$0")/.."
[ "$(cast chain-id --rpc-url "$RPC")" = "1301" ] || { echo "not Unichain Sepolia (1301) - refusing"; exit 1; }
[ -f "$DEP" ] || { echo "$DEP missing: run the DeployUnichainSepolia broadcast first"; exit 1; }

field() { python -c "import json,sys; print(json.load(open('$DEP'))[sys.argv[1]])" "$1"; }
DIRECTOR=$(field demoDirector)
VAULT=$(field demoVault)
ME=$(field deployer)

status() { cast call "$DIRECTOR" "status()(string)" --rpc-url "$RPC" | sed 's/^"//; s/"$//'; }
num() { cast call "$@" --rpc-url "$RPC" | awk '{print $1}'; }
# Fixed gas limit: the curator's try/catch makes eth_estimateGas unreliable. Every receipt is checked.
send() {
  local r
  r=$(cast send "$@" --rpc-url "$RPC" --account "$ACCOUNT" --gas-limit 25000000 --json)
  echo "$r" | grep -q '"status":"0x1"' || { echo "transaction failed: $*"; echo "$r"; exit 1; }
}

done_ticks=$(num "$DIRECTOR" "ticks()(uint256)")
echo "director $DIRECTOR | vault $VAULT | ticks already run: $done_ticks"
echo "about to send $TICKS tick() transactions from $ME (account '$ACCOUNT') on Unichain Sepolia."
read -r -p "continue? [y/N] " ok
[ "$ok" = "y" ] || exit 0

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
echo "withdrawals are never blocked, even when FROZEN:"
shares=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME")
send "$VAULT" "withdraw(uint256,uint256,uint256,address)" "$shares" 0 0 "$ME"
echo "   redeemed all $shares shares (see the Withdraw event on the explorer)"
echo
echo "summary: poisoned at tick $(num "$DIRECTOR" "poisonAt()(uint256)") | FROZEN at tick $(num "$DIRECTOR" "frozenAt()(uint256)") | attack rounds: $(num "$DIRECTOR" "rounds()(uint256)")"
echo "Explorer: https://sepolia.uniscan.xyz/address/$DIRECTOR"

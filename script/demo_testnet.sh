#!/usr/bin/env bash
# Tenure demo on Unichain Sepolia: replay the headline scenario against the DEPLOYED pool A, one tick() per tx.
# Requires a real `DeployUnichainSepolia` broadcast (deployments/1301.json). See docs/DEPLOY.md, "Run the demo".
#
#   bash script/demo_testnet.sh
#
# Env: RPC (default https://sepolia.unichain.org, the only keyless Sepolia RPC in the official Unichain docs),
#      ACCOUNT (Foundry keystore name, default tenure-burner), TICKS (default 110),
#      EVERY (status line every N ticks, default 10),
#      SENDER (address of that keystore, default the deployer from deployments/1301.json; used for nonce checks),
#      PASSWORD_FILE (optional: a file holding the keystore password, created by YOU; see docs/DEPLOY.md).
#      Each tick is a transaction signed with the keystore. Without PASSWORD_FILE, `cast send --account` asks for
#      the password on every transaction. With it, ONLY `cast send` gets `--keystore <path> --password-file <file>`
#      (Foundry's --password-file needs --keystore, not --account). Read-only `cast call`s never get key or password
#      flags. This script never reads keys or the password itself.
# Stale fair price: the demo pool's mock oracle is only refreshed by tick() (Market.step publishes a new price
# with the current timestamp FIRST, before any swap, settlement or rebalance reads it), so a stale oracle after a
# pause never blocks tick(). Only the read-only status() view reverts (Tenure__StalePrice) until the next tick.
# RPC errors: a failed `cast send` prints cast's error and exits non-zero. On a timeout/connection error it does
# NOT resend blindly: it re-reads ticks() and the sender's nonce, and resends only if the tx did not land and is
# not pending (up to 3 retries, backoff 3/6/9 s).
# Note: on a live chain ticks land a few blocks apart (1 s blocks), so the 50-block markout window spans fewer
# ticks than on anvil and the tick numbers differ from docs/DEMO.md; the sequence of events is the same.
set -euo pipefail

RPC="${RPC:-https://sepolia.unichain.org}"
ACCOUNT="${ACCOUNT:-tenure-burner}"
TICKS="${TICKS:-110}"
EVERY="${EVERY:-10}"
DEP="deployments/1301.json"
KEYSTORE="$HOME/.foundry/keystores/$ACCOUNT"
RETRIES=3

# An inherited ETH_PASSWORD makes every cast command (even read-only `cast call`) demand --keystore. Ignore it.
unset ETH_PASSWORD

cd "$(dirname "$0")/.."
[ -f "$KEYSTORE" ] || { echo "keystore not found: $KEYSTORE (create it with: cast wallet import $ACCOUNT --interactive)"; exit 1; }
if [ -n "${PASSWORD_FILE:-}" ]; then
  [ -f "$PASSWORD_FILE" ] || { echo "PASSWORD_FILE is set but not a file: $PASSWORD_FILE"; exit 1; }
  SIGNER=(--keystore "$KEYSTORE" --password-file "$PASSWORD_FILE")
else
  SIGNER=(--account "$ACCOUNT") # cast prompts for the password on each transaction
fi

die() { echo "ERROR: $*" >&2; exit 1; }
# Read-only call with retries (public RPCs time out now and then). No key or password flags, ever.
ro() {
  local out i
  for i in 1 2 3; do
    if out=$(cast "$@" --rpc-url "$RPC" 2>&1); then printf '%s\n' "$out"; return 0; fi
    sleep $((2 * i))
  done
  echo "read-only RPC call failed after 3 tries: cast $*" >&2
  printf '%s\n' "$out" | sed 's/^/   cast: /' >&2
  return 1
}
num() { ro call "$@" | awk '{print $1}'; }

chain=$(ro chain-id) || die "cannot reach RPC $RPC (set RPC=...; see docs/DEPLOY.md)"
[ "$chain" = "1301" ] || die "RPC $RPC is chain $chain, not Unichain Sepolia (1301) - refusing"
[ -f "$DEP" ] || die "$DEP missing: run the DeployUnichainSepolia broadcast first"

field() { python -c "import json,sys; print(json.load(open('$DEP'))[sys.argv[1]])" "$1"; }
DIRECTOR=$(field demoDirector)
VAULT=$(field demoVault)
ORACLE=$(field demoOracle)
POOL=$(field demoPoolId)
ME=$(field deployer)
FROM="${SENDER:-$ME}"

# status() reverts with Tenure__StalePrice (selector 0x75556672) while the demo fair price is stale: show that
# plainly instead of a raw revert. Never fails the script.
status() {
  local out
  if out=$(cast call "$DIRECTOR" "status()(string)" --rpc-url "$RPC" 2>&1); then
    printf '%s\n' "$out" | sed 's/^"//; s/"$//'
  elif grep -qE 'Tenure__StalePrice|0x75556672' <<<"$out"; then
    echo "tick $(num "$DIRECTOR" "ticks()(uint256)" || echo '?') | status unavailable: the demo fair price is stale; the next tick() refreshes it"
  else
    echo "status unavailable: $(grep -m1 -iE 'error|revert' <<<"$out" || echo "$out" | head -1)"
  fi
}

is_transient() { grep -qiE 'timed out|timeout|error sending request|connection (reset|refused|closed)|connect error|50[234]' <<<"$1"; }
nonce_at() { ro nonce "$FROM" --block "$1" || die "cannot read the nonce of $FROM; NOT resending. Check the explorer, then re-run."; }

# send LANDED_CHECK TARGET SIG [ARGS...]: one transaction, receipt checked. LANDED_CHECK is a command that succeeds
# iff the transaction's effect is visible on-chain; it decides, after an RPC timeout, whether to resend.
send() {
  local landed=$1 out rc n0 latest pending tries=0 resend=1
  shift
  n0=$(nonce_at latest)
  while :; do
    if [ "$resend" = 1 ]; then
      rc=0
      out=$(cast send "$@" --rpc-url "$RPC" "${SIGNER[@]}" --gas-limit 25000000 --json 2>&1) || rc=$?
      if [ "$rc" = 0 ]; then
        grep -q '"status":"0x1"' <<<"$out" && return 0
        echo "ERROR: transaction mined but REVERTED: cast send $*" >&2
        printf '%s\n' "$out" >&2
        exit 1
      fi
      echo "cast send failed (exit $rc): cast send $*" >&2
      printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sed 's/^/   cast: /' >&2
      is_transient "$out" || die "not a timeout/connection error: stopping (nothing is resent)."
    fi
    tries=$((tries + 1))
    [ "$tries" -le "$RETRIES" ] || die "gave up after $RETRIES retries. Check $FROM on https://sepolia.uniscan.xyz, then re-run."
    sleep $((3 * tries))
    if $landed; then
      echo "   (the RPC errored, but the transaction landed: not resending)" >&2
      return 0
    fi
    latest=$(nonce_at latest)
    pending=$(nonce_at pending)
    if [ "$latest" -gt "$n0" ]; then
      die "a transaction from $FROM was mined (nonce $n0 -> $latest) but its effect is not visible (reverted, or another tx?). Not resending; check the explorer."
    elif [ "$pending" -gt "$n0" ]; then
      echo "   transaction still pending (nonce $n0); waiting, NOT resending (check $tries/$RETRIES)" >&2
      resend=0
    else
      echo "   transaction did not land and is not pending: resending (retry $tries/$RETRIES)" >&2
      resend=1
    fi
  done
}

TICK_BEFORE=0
tick_landed() { local t; t=$(num "$DIRECTOR" "ticks()(uint256)") && [ "$t" -gt "$TICK_BEFORE" ]; }
withdraw_landed() { local s; s=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME") && [ "$s" = 0 ]; }

done_ticks=$(num "$DIRECTOR" "ticks()(uint256)") || die "cannot read the director"
echo "director $DIRECTOR | vault $VAULT | ticks already run: $done_ticks | RPC $RPC"
if upd=$(ro call "$ORACLE" "getSqrtPriceX96(bytes32)(uint160,uint256)" "$POOL" | sed -n 2p | awk '{print $1}') &&
  now=$(ro block latest --field timestamp); then
  echo "demo fair price last published $((now - upd)) s ago (pool A max age 3600 s); every tick() republishes it first"
fi
echo "about to send $TICKS tick() transactions from $FROM (keystore '$ACCOUNT') on Unichain Sepolia."
[ -n "${PASSWORD_FILE:-}" ] && echo "signing with the password file (no prompts)" || echo "cast will ask for the keystore password on every transaction"
read -r -p "continue? [y/N] " ok
[ "$ok" = "y" ] || exit 0

echo "   $(status)"
for ((i = 1; i <= TICKS; i++)); do
  TICK_BEFORE=$(num "$DIRECTOR" "ticks()(uint256)") || die "cannot read ticks()"
  send tick_landed "$DIRECTOR" "tick()"
  note=$(ro call "$DIRECTOR" "note()(string)" | sed 's/^"//; s/"$//') || note=""
  if [ -n "$note" ]; then
    echo ">> $note"
    echo "   $(status)"
  elif ((i % EVERY == 0)); then
    echo "   $(status)"
  fi
done

echo
echo "withdrawals are never blocked, even when FROZEN:"
shares=$(num "$VAULT" "balanceOf(address)(uint256)" "$ME") || die "cannot read shares"
send withdraw_landed "$VAULT" "withdraw(uint256,uint256,uint256,address)" "$shares" 0 0 "$ME"
echo "   redeemed all $shares shares (see the Withdraw event on the explorer)"
echo
echo "summary: poisoned at tick $(num "$DIRECTOR" "poisonAt()(uint256)") | FROZEN at tick $(num "$DIRECTOR" "frozenAt()(uint256)") | attack rounds: $(num "$DIRECTOR" "rounds()(uint256)")"
echo "Explorer: https://sepolia.uniscan.xyz/address/$DIRECTOR"

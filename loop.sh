#!/usr/bin/env bash
# Overnight loop for Tenure. Each iteration = fresh Claude Code session doing ONE PLAN.md task.
# Stop it any time:  touch STOP   (it exits after the current iteration)
# Tune with env vars: MAX_ITERS=40 MAX_TURNS=120 ./loop.sh
set -uo pipefail

MAX_ITERS="${MAX_ITERS:-40}"        # hard cap on iterations for the night
MAX_TURNS="${MAX_TURNS:-120}"       # cap on agent turns within one iteration
COOLDOWN_FAIL="${COOLDOWN_FAIL:-600}" # seconds to wait after a failed/limited run (usage limits, network)
LOG_DIR=".loop-logs"
mkdir -p "$LOG_DIR"
touch PROGRESS.md BLOCKERS.md

command -v claude >/dev/null || { echo "claude CLI not found"; exit 1; }
command -v forge  >/dev/null || { echo "forge not found (install Foundry)"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "run inside the git repo"; exit 1; }

fails=0
for i in $(seq 1 "$MAX_ITERS"); do
  [ -f STOP ] && { echo "STOP file found, exiting."; break; }
  [ -f DONE ] && { echo "DONE file found, all tasks complete."; break; }

  ts="$(date +%Y%m%d-%H%M%S)"
  log="$LOG_DIR/iter-$(printf '%03d' "$i")-$ts.log"
  echo "=== iteration $i  ($ts)  next task: $(grep -m1 -E '^- \[ \]' PLAN.md | cut -c1-90) ==="

  claude -p "$(cat PROMPT.md)" \
    --permission-mode bypassPermissions \
    --max-turns "$MAX_TURNS" \
    --output-format text > "$log" 2>&1
  status=$?

  grep -E '^STATUS:' "$log" | tail -1 || tail -n 3 "$log"

  # Safety-net commit so nothing is ever lost (the agent normally commits itself).
  if [ -n "$(git status --porcelain)" ]; then
    git add -A && git commit -qm "loop: safety commit after iteration $i" || true
  fi

  if [ $status -ne 0 ] || ! grep -qE '^STATUS:' "$log"; then
    fails=$((fails+1))
    echo "iteration $i did not finish cleanly (exit $status, fails in a row: $fails). Cooling down ${COOLDOWN_FAIL}s."
    [ $fails -ge 6 ] && { echo "6 failures in a row, stopping. Check $log"; break; }
    sleep "$COOLDOWN_FAIL"
  else
    fails=0
    sleep 5
  fi
done

echo "Loop finished. Morning checklist: git log --oneline -30 | PROGRESS.md | BLOCKERS.md | forge test"

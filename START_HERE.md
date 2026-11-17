# Tenure starter kit — setup in ~10 minutes, then sleep

## What's in this kit
- `CLAUDE.md` — project context Claude Code loads automatically every session.
- `PLAN.md` — ordered tasks with acceptance criteria. The measurement engine (most novel part) comes first.
- `PROMPT.md` — the master prompt each loop iteration runs.
- `loop.sh` — runs Claude Code headlessly, one task per iteration, commits after each.
- `.claude/skills/` — three project skills Claude loads on demand: `v4-hook-dev`, `tenure-math`, `self-review`.
- `PROGRESS.md`, `BLOCKERS.md` — the loop's memory and its "I'm stuck" log.

## One-time setup (do this before bed)
1. Install Foundry (`foundryup`), Python 3 with pytest + matplotlib, and Claude Code (logged in).
2. Create the repo from Uniswap's v4 template and confirm it builds:
   ```
   git clone https://github.com/uniswapfoundation/v4-template tenure
   cd tenure
   forge install        # if the template's README says so
   forge build && forge test
   ```
   Follow the template README if its steps differ. Fix any setup issue NOW; the loop shouldn't fight installs.
3. Copy everything from this kit into the repo root (including the hidden `.claude/` folder):
   ```
   cp -r /path/to/tenure-kit/. .
   chmod +x loop.sh
   echo ".loop-logs/" >> .gitignore
   ```
   If the template already has a CLAUDE.md, merge it into ours.
4. Allow tests to write result CSVs: in `foundry.toml` under `[profile.default]` add
   `fs_permissions = [{ access = "read-write", path = "./docs/results" }, { access = "read", path = "./test/vectors" }]`
5. Commit: `git add -A && git commit -m "Tenure kit + template"`.
6. Do ONE supervised iteration to catch setup problems:
   `MAX_ITERS=1 ./loop.sh` and read the log in `.loop-logs/`. If M0.1 completed cleanly, you're good.
7. Start the night run inside tmux or screen so closing the terminal doesn't kill it:
   ```
   tmux new -s tenure
   MAX_ITERS=40 ./loop.sh
   # detach: Ctrl-b then d
   ```

## Safety (read this)
`loop.sh` runs Claude Code with permission prompts bypassed so it can work unattended. That means it can run any
command in this folder. Run it on a machine (or container/VM) with NO wallet keys, NO .env secrets, and nothing you'd
mind it touching. Everything is local: anvil and tests only. To stop it gracefully: `touch STOP`.
Overnight loops use a lot of your Claude usage; if you hit a limit, the script cools down and retries, and stops after
6 failures in a row.

## Morning check-in (10 minutes)
```
git log --oneline -30        # what got done
tail -80 PROGRESS.md         # what it did + "Notes for human"
cat BLOCKERS.md              # anything stuck — fix these with Claude interactively
forge test                   # trust, but verify
ls docs/results              # CSVs / charts once M1.6+ is done
```
Then: unblock `[!]` tasks interactively, read the code of anything math-related until you can explain it yourself
(judges WILL ask), and restart the loop.

## Your human tasks (marked [H] in PLAN.md)
Confirm hookathon rules; pitch the idea at office hours and log feedback in docs/FEEDBACK.md; testnet deploy with a
burner key; record the demo video. Also: understand every formula in `.claude/skills/tenure-math/SKILL.md`.

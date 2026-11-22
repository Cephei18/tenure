---
name: self-review
description: Mandatory verification checklist to run before marking any PLAN.md task as done or committing finished work in the Tenure repo. Use this skill every time you are about to write "[x]", append a DONE entry to PROGRESS.md, or commit — and whenever you suspect a test passes for the wrong reason.
---

# Self-review before "done"

Work through every item. If any fails, the task is not done.

## Build and tests
- [ ] `forge build` has zero errors and no new warnings you introduced.
- [ ] `forge test` FULL suite passes (not just the new tests). Paste the summary line into PROGRESS.md.
- [ ] If sim/ changed: `python -m pytest sim -q` passes; vectors regenerated and committed if the model changed.
- [ ] `forge fmt --check` passes (run `forge fmt` if not).

## Tests actually test something
- [ ] Each new behavior has a test that would FAIL if the behavior were removed. Mentally delete the key line of the
      implementation: would a test catch it? If not, add one.
- [ ] Revert paths assert the exact custom error (`vm.expectRevert(Tenure__X.selector)`), not a bare expectRevert.
- [ ] Fuzz tests use `bound()` with realistic ranges, and at least one test covers each edge (range boundaries,
      zero values, max values).
- [ ] No test was skipped, weakened, or had its tolerance widened to pass.
- [ ] Numeric assertions check rounding DIRECTION where the math spec defines one.

## Acceptance criteria
- [ ] Re-read the task's `_Accept:_` line in PLAN.md. Every clause is satisfied, literally.

## Code quality
- [ ] NatSpec on new external/public functions. Math has "why" comments referencing tenure-math sections.
- [ ] Custom errors `Tenure__*`, events for state changes.
- [ ] No leftover TODOs that hide missing behavior (TODOs for stretch items are fine if labeled `STRETCH:`).
- [ ] No console.log in `src/` contracts (tests and scripts are fine).
- [ ] No changes under `lib/`. No new dependencies unless the task required it (recorded in Learnings).

## Hook-specific (if hook code changed)
- [ ] Permissions/address test still passes and runs first.
- [ ] Loops in callbacks are bounded; gas checked for afterSwap if touched.
- [ ] Authorization uses `sender`/registered vault, never hookData alone.

## Bookkeeping
- [ ] PROGRESS.md entry written in the required format, with "Notes for human".
- [ ] Learnings added to CLAUDE.md if anything was surprising.
- [ ] Task marked `[x]` in PLAN.md. Committed with message `<task id>: <description>`.

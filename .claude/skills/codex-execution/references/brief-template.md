# Codex execution brief — template

The brief is the whole contract: codex sees the worktree and this text, nothing
else. Ground every claim (file paths, script names, prior fixes) against the
tree before writing it — a brief that asserts stale facts sends codex chasing
ghosts. Mark anything uncertain as "verify first".

```markdown
You are implementing GitHub issue(s) #<N> for <owner>/<repo>: <one-line frame>.
You are already on branch <branch> in a dedicated worktree.
SCOPE: modify ONLY files under <dir>/. Commit locally with conventional
commits; do NOT push, do NOT open a PR, do NOT touch GitHub issues — the
orchestrator reviews your diff and ships it.

## Issue #<N> — <title>
<Symptom, where it lives, reproduction command, named suspects with file
paths, what was already shipped (so codex doesn't redo it).>
Reproduce FIRST (record how many runs it took), understand the actual cause,
then fix by <the standard the fix must meet — e.g. event-driven waits, not
timing assumptions>. Do NOT just bump timeouts; that hides the race.

## Verification (all from <dir>/, using <package> scripts — never ad-hoc
rm -rf; `<clean command>` exists for build/test state; run every gate BARE,
never piped through tail/rg — exit codes must survive)
1. <install/setup>
2. Reproduce each defect before fixing.
3. After fixing: <exact gate commands> green, plus <stability loop, e.g.
   --repeat-each 10>. Use your assigned port block (<E2E_PORT=..>,
   <EVIDENCE_PORT=..>, <PERF_PORT=..>) — all three collide across parallel
   workers, not just e2e.
4. Mutation check: re-introduce each defect briefly, confirm the failure mode
   returns, then restore. Record what you did.

## Deliverable
Local commits on this branch (conventional messages, e.g. `fix(<area>): …
(#<N>)`), ending with a final summary written to CODEX_REPORT.md at the
worktree root, left UNTRACKED (do not `git add` it), containing: root cause
of each defect, the fix, reproduction counts before/after, gate results,
mutation-check results, any deviations.
```

## Field notes (2026-07-08 trial, #901/#932)

- gpt-5.5 xhigh followed the scope fence, the no-push contract, and the
  untracked-report convention exactly; it also generalized house style
  unprompted (replaced a raw `rm -f` with the sanctioned clean script and
  extended that script's target map with tests).
- Named suspects with file paths pay off — codex went straight to the seam
  files rather than surveying.
- The one gap the orchestrator review caught was a *lifecycle* hole (stale
  lock file after a killed run) — review codex diffs for teardown/staleness
  paths specifically; its happy-path and mutation coverage were already strong.
- Token/time envelope for a two-issue diagnostic+fix brief: ~208k tokens,
  single pass, no retries.

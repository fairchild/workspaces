---
name: subagent-delegation
description: >
  Brief and gate implementation subagents so their PRs pass review first-try.
  Use when orchestrating parallel implementation work across subagents/worktrees:
  writing task briefs, choosing model tiers, and running the quality gate before
  a PR leaves draft. Triggers on: "delegate this", "spin up agents", "orchestrate
  the milestone", "brief a subagent", "gate this PR".
---

# subagent-delegation: Briefs and gates for implementation subagents

Distilled from the 2026-07-02 web cycle (PRs #723–#732: six PRs, six first-try
gate passes, zero fabricated evidence, zero redos). Two artifacts matter: the
**brief** an implementing agent receives, and the **gate** its PR must pass
before leaving draft.

## The brief

A subagent starts cold — the brief is its entire world. Include, in order:

1. **Worktree bootstrap.** `git fetch origin main && git checkout -B <branch> origin/main`.
   Name the branch in the brief. Base on the fresh tip, not the orchestrator's branch.
2. **Reading list with a reason per item** — the issue, the plan section, the
   target source files. Ordered; 3–5 items.
3. **Grounded facts with file:line, marked as re-verifiable.** State what you
   already know ("middleware gates only on cookie presence, `middleware.ts:43-50`")
   and instruct: *re-verify, don't trust; if reality differs from the brief,
   stop and report the discrepancy instead of guessing.* This clause caught a
   wrong dependency-graph claim in #725 before it became a wrong deletion.
4. **Constraints as hard rules**, not vibes: what must be preserved verbatim,
   fail-open vs fail-closed semantics, styling-system boundaries, "follow the
   code, not the sketch, and note the delta in the PR body."
5. **Verification commands, exact.** Which suites, which projects, which env
   caveats (see `docs/development/remote-sessions.md`). For test-adding work,
   require a **mutation check**: re-break the covered bug, prove the new test
   fails, revert, report which mutation ran.
6. **Honest-evidence rules.** Never fabricate links; blocked evidence is an
   explicit PR state with the reason; a green CI run link is the remote-session
   hosted-evidence convention.
7. **Ship protocol.** Draft PR only (never mark ready), PR-template sections
   filled honestly, `Closes #N` in the body, commit trailers, and — for
   `agent`+`task` labeled issues — do not touch claim labels (that lane belongs
   to `sync-execution-state.py`; see `backlog/CLAUDE.md`).
8. **Return format.** What the orchestrator needs back: choices made + why,
   deltas from the brief, exact pass/fail counts, PR URL, residual risks.

## Model tiering

Match tier to failure cost, not task size: security-sensitive or
design-judgment work → high tier; well-specified mechanical or verification
work → mid tier. Evidence so far: mid-tier output on well-specified briefs has
matched high-tier quality — when unsure, the brief's specificity buys more than
the model tier. Revisit per #733.

## The gate (before a PR leaves draft)

Calibrate depth to change class (#733 tracks formalizing this):

- **Always:** read the full diff; independently re-run the verification suites
  on the branch (don't trust reported numbers); confirm CI green and cite the
  hosted run in the Evidence section; check `Closes #N` is present.
- **Security-touching:** adversarial pass — enumerate bypass paths, confirm
  every failure path is no worse than the pre-change behavior, check secret /
  config parity between the components that sign and the components that verify.
- **UI-touching:** view the screenshots yourself; verify the suites CI doesn't
  run (`full` project) with your own second run; deliver screenshots to the
  owner when hosted upload is blocked.
- **Test-adding:** confirm the mutation check actually ran and failed the
  right test.
- **Merge mechanics:** pre-check conflicts with `git merge-tree --write-tree`
  (legacy `merge-tree` false-negatives); after resolving any conflict, re-run
  the full suite on the merged tree — and capture output to a file before
  filtering, so a one-off failure keeps its name.
- **Record the gate** as a gate-note in the PR body (what was re-run, on which
  commit, what the adversarial pass covered), then flip to ready.

## Sequencing

Serialize PRs that touch `package.json`/lockfile; everything else can run in
parallel worktrees. `web/tests/LEDGER.md` conflicts are expected and additive —
keep both blocks. One watch (cron or background poll) owns merge-event
follow-through, since merge/CI-success events don't push to sessions.

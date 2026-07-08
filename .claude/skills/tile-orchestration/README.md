# tile-orchestration

A coordinator outside the WorkSpaces app dispatches codex workers *into*
WorkSpaces terminal tiles it creates via the Automation API's operator scope
— one tile per issue, visible in the owner's sidebar the whole time — then
monitors, re-tasks, and ships through the normal gate/merge flow. The
mechanics (Preflight, Spawn, Monitor, Gate and ship, Teardown) live in
[SKILL.md](SKILL.md); this file is the narrative version — what the skill is
for, what it's actually like to run, and what it wants next.

## When to reach for this

You want the WorkSpaces app itself to be the visible fleet surface for
multi-worker milestone execution — the owner can see workers running,
snapshot their tiles, and the coordinator's expensive tokens go to briefs,
review, and merges rather than typing into terminals. If you just need one
worker in one plain worktree with no app involved, that's `codex-execution`
without this layer on top.

## Provenance

Two dogfood arcs so far, both 2026-07-08:

- **W5 (first drive)**: five codex workers, six issues shipped in ~9 hours
  wall clock. Findings recorded in
  `docs/retros/2026-07-08-automation-dogfood-w5.md` and filed as issues
  #973, #838, #889, #989, #990, #991, #992, #995.
- **This arc**: closed out that wishlist. #989 (`workspace.create` options),
  #990 (`surface/read`), and #991+#992 (`workspace.archive` + richer
  `automation health`) shipped as reviewed, merged PRs. #973 turned out to be
  non-reproducible on live re-test (see SKILL.md's Gotchas) — shipped
  diagnostics and regression coverage instead of a behavior fix. #995 was
  already fixed on `main` before this arc started — closed with evidence,
  no PR needed (the tracker had simply lagged the code). #838 stays
  deferred: it's an explicit design sketch, and the issue that motivated it
  (`startCommand` proving too narrow) hadn't happened yet — implementing the
  general form before that signal exists would be building ahead of a real
  need. This arc also ran *while a second, independent coordinator session*
  was active on the same machine, which is where the concurrency notes in
  SKILL.md come from — not a synthetic test, just what happened.

## The shape of running it

Spawning a worker is fast and cheap — one `workspace.create` call, a brief
and a `tile-start` file dropped into `.agents/inbox/`, and codex is running
within about five seconds, visible in the sidebar. The coordinator's real
work is everything *around* that: writing a brief grounded in an actual read
of the code (not the issue text's assumptions — issue text can be stale, see
below), watching for the precise finished-marker rather than a loose string
match, and then the gating pass — rebase onto current `main`, full test
suite (not just the filtered subset the brief asked for), lint, review,
evidence, merge. For four workers touching a shared Automation API surface,
that gating pass was the majority of the wall-clock time, not the workers'
own runs.

Ground every brief against the tree before writing it. One worker's brief
this arc reframed a "the entire tile-scoped API is unreachable" bug as
"diagnostics for a bug I couldn't reproduce live" because a few minutes of
reading the actual env-injection code first turned up that the bug's own
theory (a libghostty per-surface config bug) didn't match what the Swift
code was actually doing. That reframing turned a speculative native-bug fix
into a much safer, much more honest diagnostics-and-tests PR — worth the
extra investigation time before dispatching, every time an issue's
narrative and the current tree might have drifted apart.

## Top gotchas (full list in SKILL.md)

1. **`origin/main` moves during your session, not just before it.** Rebase
   at review time, every time — three unrelated commits landed on `main`
   during one ~40-minute run.
2. **Fresh worktrees each pay their own GhosttyKit rebuild** (10–20 min,
   zig, native) unless you pre-seed the xcframework. Four parallel workers,
   four redundant rebuilds, today.
3. **The codex CLI usage quota is shared account-wide**, across every
   concurrent invocation on the machine, not per-session. It ran out mid-run
   today with another coordinator active. When it does, document the block
   in the PR instead of faking a review that didn't happen.
4. **The tracker lags the code.** One issue in this arc was already fixed on
   `main` before work started; verify live before planning a fix.
5. **Merge overlapping workers sequentially.** Workers touching the same
   API surface will conflict on merge — that's normal, resolve it like any
   rebase, don't try to land them all at once.

## Concurrency, answered

The question this arc was explicitly run to answer: multiple coordinator
sessions *can* safely share one running WorkSpaces app instance — verbs
interleave cleanly, the audit log is a trustworthy serialized record, nothing
corrupts. The real friction is resource contention, not data corruption:
selection gets stolen on every `workspace.create` (now avoidable with
`select:false`), the machine's CPU and the shared GhosttyKit source cache get
contended, and the codex usage quota is a shared, invisible-until-you-hit-it
budget. Nothing today *prevents* two coordinators from colliding — safety is
convention (distinct names, checking `ps aux` and the audit log first,
budgeting shared resources), not enforcement. Full writeup in SKILL.md.

## What would make this better next

See SKILL.md's Suggestions section for the full list — the headline item is
auto-seeding new worktrees' GhosttyKit build artifact at spawn time, which
would have saved most of this arc's redundant wall-clock time outright
rather than just documenting it as a thing to watch for.

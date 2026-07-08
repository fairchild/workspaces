# Report: first real drive of the Automation API (W5 dogfood)

| | |
|---|---|
| **Model** | Claude Fable 5 (`claude-fable-5`), coordinator seat |
| **Harness/client** | Conductor (Mac app); workers: codex `gpt-5.5` (xhigh/high/medium) in WorkSpaces tiles; research: sonnet subagents |
| **Date** | 2026-07-08 (~01:45 → ~09:30 PDT, two session interruptions) |
| **App build** | WorkSpaces.app from codex worktree 8444, launched 01:35 PDT with Automation API + Operator Scope + Input Write experiments on |
| **Work shipped through it** | W5 milestone (#18): PRs #974, #975, #977, #978, #979 merged; #980 in flight — issues #971, #967, #910, #871 closed, #972 decided-and-parked |

The [A1]/[A2] arcs built the machinery; this was the first session that *bet
real work on it* — a coordinator outside the app dispatching codex workers
into tiles it created, monitoring them, re-tasking them, and shipping the
results. The bet paid: five workers, six W5 items, roughly nine hours wall
clock with the coordinator's expensive tokens spent only on briefs, review,
gates, and merges. This report records what the machinery got right, where it
bent, and what it wants next.

## What the operator scope got right

- **`workspace.create` is a complete spawn primitive.** One call returned a
  worktree, a branch, and a live terminal tile visible in the sidebar. The
  verbs=clicks contract meant everything the UI believes (selection,
  attachment, focus) stayed true — no ghost state, ever.
- **`window.snapshot` is the monitoring surface it promised to be.** Full
  composited fidelity (sidebar chrome + Ghostty Metal surface), captured with
  the app backgrounded, zero focus steal, zero TCC friction. It served two
  distinct jobs: coarse liveness checks on workers, and an *aesthetics
  sign-off* (the #871 masthead placement was approved from a snapshot).
- **The audit log told the truth.** Every operator call I made appeared in
  `automation-audit.jsonl` with the `operatorHandle` flag — the trust model
  is inspectable after the fact.

## The bootstrap that emerged (and why)

Tiles cannot be typed into from outside (by design), and the tile-scoped API
turned out to be unreachable anyway (finding 1 below). What worked instead —
and ended up *better* than the input-write plan — is a cooperating-tile
pattern, ~12 lines of zsh in `~/.zshrc.local`:

- Interactive shells inside WorkSpaces tiles watch for
  `.agents/inbox/tile-start`; the file is moved away before sourcing, so it
  runs exactly once; a `TMOUT=5` + `TRAPALRM` watcher re-checks while idle.
- The coordinator spawns a workspace, writes a brief plus a `tile-start`
  that runs `codex exec … | tee .agents/inbox/worker.log`, and the tile picks
  it up within ~5 s.
- **Re-tasking falls out for free**: when codex exits, the shell returns to
  its prompt and the watcher resumes — dropping a new `tile-start` into an
  idle tile hands it the next task. This was proven in anger when worker
  968's first pass was built on a stale base: a rebase brief dropped into the
  same tile fixed it without human hands.
- The `tee` log gives the coordinator **text** ground truth from outside;
  snapshots give pixels. Text for state, pixels for aesthetics — the
  token-efficient split.

Guards that proved necessary: `[[ -o interactive ]]` (codex's own `zsh -lc`
subshells source the same rc files and would have eaten a re-task file
mid-run), and consume-before-source (no double execution).

## Findings — where it bent

1. **Tiles receive no automation env at all** ([#973]). Fresh tiles had
   neither `WORKSPACES_AUTOMATION_SOCKET` nor `_HANDLE`, so the *entire*
   tile-scoped API — context, focus/split/close, and `input.write`, the
   keystone [A2] shipped — is unreachable from real tiles on this build.
   Likely the #889 per-surface-config delivery family. The cwd-fallback hook
   is the workaround; it must not become the permanent design.
2. **`workspace.create` branches from the base repo's stale local HEAD.**
   The app clone at `~/code/workspaces` doesn't pull before branching, so
   worker 968 was cut from a pre-#967 main and needed a full extra codex
   pass to rebase. Coordinator discipline (fast-forward the base clone
   before spawning) is the workaround; the verb wants a `fromRef` option or
   an app-side fetch.
3. **Spawn steals the owner's selection.** `workspace.create`/`select` drive
   the real sidebar gesture, so every spawn yanked the human's selection and
   in-app focus (never OS focus). Concurrent human use works *between* spawn
   moments only. Wants `select: false`.
4. **No archive/close verb.** The stale `codex-967-repo-threading` workspace
   (inert tile from before the hook existed) is still sitting in the
   sidebar; cleanup requires the human.
5. **Paper cuts.** `window/snapshot` requires `windowID` as a *string* and
   returns the PNG under `data` (neither obvious from the reference);
   the Homebrew `workspaces` CLI is envelope-incompatible with this app
   build (use the bundled `Contents/Helpers/workspaces`); `automation
   health` doesn't name the serving PID/launch-time, which let a stale
   duplicate app instance masquerade as the live one for half an hour.
6. **Coordinator interruptions are survivable but lossy in attention.** Two
   session drops killed the CI watchers; nothing durable was lost (worker
   logs, git state, PR state all survived — the file-based design working),
   but each recovery cost a manual "where was I" sweep.

## Answers to the owner's questions

**"Can I use the app while you do?"** Yes, except at spawn moments (finding
3) — snapshots and running workers never disturb you; each
`workspace.create` currently flips your selection. `select: false` closes
the gap. A worker's tile is single-owner in practice: typing into it would
interleave with the worker's PTY.

**"What's missing for efficiency?"** In leverage order:

1. **Fix tile env injection (#973)** — restores the whole tile-scoped API
   and lets workers self-report through `workspaces automation context`
   instead of inferring identity from cwd.
2. **`workspace.create` options: `select`, `fromRef`, `startCommand`** — no
   selection steal, no stale-base class, and creation-time seeding that
   retires the rc-hook bootstrap entirely (authority flows from creation;
   the narrow alternative to #838's child handles; `startCommand` blocked
   today by the #889 family).
3. **Bounded text read-back of own-created tiles** (operator scope,
   creation-authority-scoped like the above): pixels are for aesthetics;
   state wants text. Today's `tee`-to-log workaround requires the tile's
   cooperation and repo-side gitignore hygiene.
4. **`workspace.archive` verb** — the spawn loop needs its teardown half.
5. **Health metadata** — serving PID, launch time, experiment set in
   `automation health`; kills the duplicate-instance confusion class.
6. **Child-handle authority (#838)** — the general form of item 2, if
   `startCommand` proves too narrow for interactive worker steering.

## What this session proves about the direction

The two-arc thesis — one spine, veneers on top, verbs = clicks — held under
real load. The costs it predicted (UI nondeterminism, verbs dearer than RPC)
showed up as exactly two workarounds (cwd hook, base-repo ff), both cheap,
neither compromising the trust model. The missing pieces are all *additive*
(options on existing verbs, one bug fix, one read capability) rather than
architectural. The next encoding step is a skill — dispatch/monitor/re-task
conventions from this session, written for future coordinator sessions —
once the wishlist above stabilizes the surface it would document.

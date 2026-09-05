# Wrapup — janitor session (2026-08-29 → 2026-09-04)

Sidebar cleanup for the WorkSpaces app, plus the machine-state cleanup that turned
out to be sitting behind it. Written at stand-down; state re-checked 2026-09-04.

## What the session was for

The `workspaces` group in the app sidebar held 12 tiles. The ask was to find out
what was running in them and shut down what wasn't needed, with a stated worry
that the `codex-*` ones were live codex sessions that should not be closed.

They weren't. All 11 non-`wsclean` tiles were relics of 2026-07-08 — directories
gone, local and remote branches gone, issues (#871, #910, #967, #969, #989, #990,
#991, #992) all closed the same day, no terminal session, no tmux session, no
process. Verified four independent ways before anything was touched.

## What landed

**Repo (`fairchild/workspaces`).** Worktrees 26 → 11, local branches 50 → 14, every
deletion proved landed via merged-PR metadata rather than `git branch --merged`,
which under-reports in a squash-merge repo. No commits, no pushes, no merges; `main`
untouched throughout.

**App state.** `wsclean` archived through the app's own gesture. Eight live worktrees
adopted into the sidebar (`design-refresh`, `revision-loop`, `steward-v4`,
`voicechat-research`, `wikiskill`, `folio-cell`, `runners-finish`, `duplex-design`),
which was the actual goal — real work visible instead of July's ghosts. Four finished
agent sessions closed, with their unsent input-box drafts preserved first.

**Disk.** 27 GiB reclaimed from `LumeQuarantine` (three set-asides from 2026-03-10/11
that the recreate runbook creates deliberately and never cleans up). `du` reported
96 GB; the difference is APFS clone blocks shared with the live validated base, so
27 GiB is the honest number. Live base and both manifests verified intact after.
156 orphaned `wsparity-test-*` tmux sockets swept, gated on proving no live server
owned any.

**Terminal.** tmux styling made dark and persisted to `~/.tmux.conf` using
`bg=default`, so the status bar inherits the terminal background and follows theme
changes instead of pinning one palette. The Ghostty theme turned out to be stranded
rather than broken: the selection was saved in prefs but never written to the
app-owned config, and a restart wrote it.

**Issues.** #1440 with four subtasks, #1441–#1444. Two shipped within 48 hours:
[#1452](https://github.com/fairchild/workspaces/pull/1452) (archive a workspace whose
directory is already gone) and
[#1451](https://github.com/fairchild/workspaces/pull/1451) (a way back to a dismissed
leftover banner).

## What is left

| Item | State |
|---|---|
| 11 ghost workspace records | Unchanged. Trivial once a build carrying #1452 is installed — one automation-API pass, no clicking. Installed app is still 0.26.0 b34 (binary 2026-08-29), which predates both fixes. |
| #1443 socket leak | Open and measured: 354 sockets, ~69/day from a clean 2026-08-29 baseline. Comment posted 2026-09-04. |
| #1444 stale repo records | Open. 23 records with missing paths, 16 of them `workspaces-lume-smoke-*`. Still one right-click each. |
| Dangling Lume manifest | `LumeValidatedBases/` claims a `26-3-1` base that is not in `validated-bases/`. Left deliberately: deleting metadata that records an expectation would erase the discrepancy rather than resolve it. |
| Two worktree removals | `~/.worktrees/workspaces/release/v0.26.0` and `~/.codex/worktrees/1084/workspaces` — refused by the permission classifier, never retried. |

## Lessons worth keeping

**The cleanup gesture could not clean the state that needed cleaning.** Archiving a
workspace moves its directory into `.archived/`; a record whose directory is already
gone failed the move and returned `unsupported`. The recovery path and the broken
state were mutually exclusive. That is #1441/#1452.

**A dismissed banner had no way back.** The orphan reconciliation scan ran only at
launch and after a completed cleanup or adopt, and dismissal lived in per-window
`@State`. Once quieted, the only recovery was relaunching the app — which tears down
every tile. That is #1442/#1451.

**Verify the right path, not a path.** A probe showed new tmux panes were clean of an
inherited `CLAUDE_CODE_CHILD_SESSION` marker, which read as exoneration. It wasn't:
tiles also spawn on a direct-PTY path as children of the app process, and that path
was poisoned. The process tree settled it — `claude → zsh → login → WorkspaceManager`.
A probe of the wrong mechanism is more dangerous than no probe, because it retires
the question.

**Launching an app from inside an agent session leaks that session's environment into
it.** `open -a` passes the caller's environment through. The remedy is a prefix scrub
rather than an allowlist — the dangerous variables are the ones a child only ever
reads and never re-mints, so naming them goes stale — and the scrub must assert it
removed something, since one that silently removes nothing reads as working. Three
live examples were found on this machine across three apps.

**Check capabilities before spending attempts on them.** Three restarts were spent
trying to drive the cleanup banner through computer-use before noticing it reports
`dialogs: false`, while the flow puts a confirmation in front of every item. The
limitation was published and readable the whole time.

**A bulk action over a mixed list needs the list read first.** The banner offered 29
items as one set: 20 stale records safe to delete, and 9 worktrees that all had live
agent sessions, where cleanup prunes the worktree and its branch. Cleaning that set
wholesale would have taken out two open PRs. Reading it before acting was the whole
difference.

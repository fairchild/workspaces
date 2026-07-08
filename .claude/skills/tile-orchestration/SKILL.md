---
name: tile-orchestration
description: Coordinate implementation workers (codex CLI or similar) inside WorkSpaces terminal tiles via the Automation API operator scope — spawn workspaces, bootstrap workers hands-free, monitor via surface/read + window snapshots, re-task idle tiles, and ship through the normal gate/merge flow. Use when dispatching multi-worker milestone execution with the WorkSpaces app as the visible fleet surface ("run workers in tiles", "tile orchestration", "dogfood the automation API"). Complements codex-execution (the per-worker contract); this skill is the fleet layer around it.
---

# Tile Orchestration

Workers run *inside* WorkSpaces tiles — visible in the owner's sidebar, one
tile per issue — while the coordinator stays *outside* (operator scope was
designed for exactly this; a coordinator inside a tile dies with every app
restart). Proven on the W5 arc (2026-07-08): five codex workers, six issues
shipped (`docs/retros/2026-07-08-automation-dogfood-w5.md`). Proven again the
same day on a second arc that shipped four of the W5 wishlist items themselves
(#973, #989, #990, #991/#992) — including running *concurrently* with another
live coordinator session, which is where the concurrency notes below come
from. Division of labor: this skill spawns/monitors/re-tasks; the brief
contract, gating, and merge flow are `codex-execution` unchanged.

## Preflight (once per session)

1. **App + experiments.** The app must run with Automation API + Operator
   Scope on (Settings → Experimental Features, then restart — experiments
   are read at launch). Verify with the **bundled** CLI — the Homebrew one
   is version-skewed against dev builds:
   `"<app>/Contents/Helpers/workspaces" automation health --json`. The
   response's `server` block (`pid`, `launchedAt`, `experiments`,
   `protocolVersion`) tells you who is actually serving and whether your CLI
   matches the app's protocol — a stale duplicate instance or a version-skewed
   CLI now says so directly instead of leaving you to `ps aux` and guess.
2. **Operator credential.** An opt-in launch writes
   `automation-operator.json` (0600) next to `automation.sock` under
   `~/Library/Application Support/com.cloudcompute.workspaces/`. Its absence
   means operator scope is off → toggle + restart.
3. **Bootstrap hook present.** Tile shells self-identify via
   `WORKSPACES_AUTOMATION_HANDLE`/`_SOCKET` when the app's automation wiring
   has finished starting; a narrow startup race can still leave an
   early-created tile without it (see Gotchas). `~/.zshrc.local` needs the
   hook in [references/bootstrap-hook.zsh](references/bootstrap-hook.zsh) —
   interactive-only guard, consume-before-source, `TMOUT=5` idle watcher. It
   remains the mechanism for hands-free bootstrap and re-tasking regardless
   of the env-var race, since it doesn't depend on that env being present.
4. **Check who else is here.** Before spawning, skim the tail of
   `~/Library/Application Support/com.cloudcompute.workspaces/automation-audit.jsonl`
   and `GET /v1/workspaces` for recent activity and unfamiliar workspace
   names. Nothing enforces single-coordinator use — a concurrent session may
   already be spawning workers against the same app instance. See
   Concurrency below.

## Spawn a worker

Use [scripts/ws-op.py](scripts/ws-op.py) (single-file uv script) for operator calls:

```bash
uv run --script scripts/ws-op.py POST /v1/workspace/create \
  '{"repoID":"<from GET /v1/workspaces>","name":"<coordinator>-<issue>-<slug>","providerID":"local","select":false,"fromRef":"origin/main"}'
```

Returns `workspacePath` + attached tile. `select:false` creates and attaches
the tile without flipping the owner's (or another coordinator's) sidebar
selection — pass it whenever anyone else might be using the app concurrently,
which today means essentially always. `fromRef:"origin/main"` fetches and
branches from that ref instead of the base clone's possibly-stale local HEAD
— prefer it over manually fast-forwarding the base repo. Name workspaces with
a coordinator-distinguishing prefix (`claude-`, `codex-`, whatever identifies
*this* session) so concurrent spawns from different coordinators never
collide on a name.

Then stage the work (paths relative to `workspacePath`; `.agents/inbox/` is
gitignored):

1. Write the brief per `codex-execution`'s template to
   `.agents/inbox/brief-<issue>.md`. Name the branch the app created
   (`workspace/<workspace-name>`) in the brief's "you are on branch" line.
2. Write `.agents/inbox/tile-start`:
   ```bash
   echo "[worker-<issue>] started $(date)" | tee .agents/inbox/worker.log
   codex exec --cd . -c model='"gpt-5.5"' -c model_reasoning_effort='"high"' \
     --dangerously-bypass-approvals-and-sandbox \
     "$(cat .agents/inbox/brief-<issue>.md)" </dev/null 2>&1 | tee -a .agents/inbox/worker.log
   echo "[worker-<issue>] finished $(date)" | tee -a .agents/inbox/worker.log
   ```
   `</dev/null` is load-bearing (codex hangs on open stdin). The idle
   watcher picks the file up within ~5 s; confirm via
   `head -1 <workspacePath>/.agents/inbox/worker.log`. Use `high` effort for
   most issues; reserve `xhigh` for genuinely hard, open-ended investigation
   (native/system-level bugs, ambiguous root causes) — see Gotchas on the
   shared codex usage quota before fanning out many `xhigh` workers at once.

## Monitor

- **`surface/read` is the first-class text read-back** (landed via #990):
  `POST /v1/surface/read` `{"surfaceID":"<attachedSurfaceID from create>","lines":200}`
  returns bounded plain text (clamped to 500 lines / 256 KiB, never errors on
  an over-cap request) for a surface *your operator handle created this
  launch* — creation-scoped, not a blanket read of arbitrary tiles. This
  replaces the old `tee`-to-`worker.log` workaround for the common case; the
  `tee` pattern is still fine if you want the log to also live in the repo's
  `.agents/inbox/` for the worker's own reference, but you no longer need it
  purely to read from outside.
- **Anchor your finished-marker check precisely.** `rg "finished"` will
  false-match codex's own narration (e.g. "the build finished") long before
  the worker actually exits. Anchor on the literal marker line:
  `rg -q "^\[worker-<issue>\] finished" <log>`.
- **Pixels are for aesthetics and coarse liveness**: `GET /v1/windows` →
  `POST /v1/window/snapshot` `{"windowID":"<id-as-STRING>"}` → PNG base64
  in the response's `data` field. Full composited fidelity, backgrounded,
  no focus steal — good enough to sign off UI placement from.
- Durable state (logs, git, PR state) survives coordinator interruptions;
  after a session drop, sweep worker logs + `gh pr list` before resuming.

## Re-task an idle tile

When codex exits, the tile shell returns to its prompt and the watcher
resumes: drop a new `tile-start` (+ brief) into the same inbox. This is how
follow-up passes (rebases, review reactions) run without new tiles. Never
drop a `tile-start` while the worker is mid-run — the interactive guard
protects against codex's own subshells eating it, but the *timing* guard is
you (check for the finished marker first, precisely — see Monitor).

## Gate and ship

Exactly `codex-execution` from here, with two additions learned from running
four workers through it in one session:

- **Rebase onto `origin/main` at review time, not just at spawn time.**
  `origin/main` keeps moving for as long as your workers run — three
  unrelated commits landed on `main` during one ~40-minute, four-worker
  session. `fromRef` at spawn time fixes staleness *then*; it does not
  protect the review/merge step later. Always `git fetch origin main && git
  rebase origin/main` in each worker's worktree immediately before your own
  gate re-run, not just once up front.
- **Merge multiple workers sequentially, not in parallel, when their issues
  touch overlapping files.** Workers dispatched from the same milestone
  often touch the same seam files (`AutomationAPI.swift`,
  `AutomationHTTPRouter.swift`, shared test files). Merge one, then rebase
  the next onto the new `main` — expect and resolve ordinary merge
  conflicts there rather than trying to land everything at once.
- Read `CODEX_REPORT.md` + full diff, react with attributed commits,
  clean stale build state, re-run every gate with visible pass/fail output
  (don't trust `cmd | tail` exit codes — pipes swallow failures). Run the
  **full** test suite, not just the brief's filtered subset, when a worker
  touched shared protocol-level files — a filtered pass can miss ripple
  effects in unrelated suites.
- Evidence, PR labeled `author:codex` (or your own agent label), merge per
  the arc's authority contract.
- If the codex directed-review pass (`codex-review-loop`) hits the shared
  usage-quota wall (see Gotchas), don't fake it — do the reflect pass
  yourself, document the block plainly in the PR's Review loop section with
  the exact error and retry time, and rely on your own manual read.

## Teardown

`POST /v1/workspace/archive` `{"workspaceID":"<from workspace.read>"}`
(landed via #991) drives the same real archive gesture the sidebar offers —
call it at lane close for any workspace you spawned and no longer need. It
returns `confirmation_required` rather than hanging if the UI gesture would
normally prompt. No more "tell the owner to clean up manually."

## Gotchas

- **A narrow tile-env-injection race may still exist.** #973 found the
  original "tiles get no automation env at all" symptom was **not**
  reproducible in a live re-test — likely an artifact of a stale duplicate
  app instance (see Preflight step 1's health check, which now catches
  this), not a persistent bug. The fix landed was diagnostics + regression
  tests, not a behavior change: if a tile ever again starts with neither
  `WORKSPACES_AUTOMATION_SOCKET` nor `_HANDLE` set while the app is healthy,
  check Console/stdout for a `[TileTreeStore] automation environment
  unavailable for session …` log — it now names exactly which of
  `handleRegistry`/`socketPath` was nil.
- **`startCommand` does not exist and won't until #889 resolves.** #889
  (libghostty drops per-surface `command`/`initial_input` for the second and
  later surfaces created in a launch) is still open and still hard — a prior
  investigation timeboxed a from-scratch native/zig repro without finding
  the loss point. The `tile-start` file-drop bootstrap in this skill is the
  durable workaround, not a stopgap; keep using it.
- **Fresh worktrees trigger redundant native rebuilds.** A worktree without
  a pre-built `Frameworks/GhosttyKit.xcframework` fails `swift build` until
  one exists, and each independently-dispatched codex worker discovers this
  on its own and pays its own 10–20 minute `./scripts/build-ghosttykit.sh`
  zig rebuild. Running four parallel workers cost four redundant rebuilds
  today. Rsync a known-good `Frameworks/GhosttyKit.xcframework` from the main
  checkout into each new worktree *before* dispatching the worker to avoid
  this — see Suggestions below for making this automatic.
- **The GhosttyKit build reads a shared source cache.**
  `~/.cache/workspacemanager/ghostty` is one checkout shared by every
  worktree's build on the machine, including other coordinators' builds.
  Safe when everyone builds against the same pinned commit (read-mostly);
  a real collision risk if two concurrent sessions ever build against
  *different* pins — the build script's `ensure_pinned_commit` step will
  `git checkout` the shared clone out from under a concurrent reader.
- **The codex CLI usage quota is shared account-wide across every
  concurrent invocation**, not per-worktree or per-session. Four
  implementation workers plus two `codex-review-loop` review passes,
  running while another live coordinator session was *also* running its own
  `xhigh` codex processes for unrelated work, exhausted the quota mid-review
  today (`ERROR: You've hit your usage limit ... try again at <time>`).
  There is no visible remaining-quota check before you hit the wall. Budget
  for this: stagger heavy (`xhigh`) calls, don't reflexively re-fire a
  timed-out review, and treat a quota error as a real, document-worthy
  finding rather than a transient glitch to retry through.
- **A flaky-under-load test is not necessarily your regression.** A test
  entirely unrelated to one PR's diff failed once during a full-suite run
  under heavy concurrent build/test load, then passed clean on an isolated
  retry. Before treating a full-suite failure as a regression, check that
  the failing test's file is actually touched by your diff, and retry in
  isolation if it isn't.

## Concurrency

What actually happens when two coordinator sessions use this machine at
once, observed directly today (one session running this skill, another
running an entirely separate raw-`~/.worktrees/` + scheduled-`codex exec`
pattern for unrelated web-next issues, at the same time):

- **The running app instance, its automation socket/credential, and its
  audit log are singleton, shared, per-login-session resources.** Every
  coordinator targeting "the dev app" is talking to the exact same process.
  Read and create verbs from multiple coordinators interleave safely — nothing
  corrupted, the audit log is a clean serialized append log with every call
  attributable after the fact. **Never launch a second dev instance while
  another coordinator might be using the existing one** — check
  `ps aux | rg WorkspaceManager` first, always.
- **`workspace.create` without `select:false` steals whoever's selection is
  currently active** — a human's, or another coordinator's. This is the one
  visible, non-cosmetic collision, and it's now avoidable (see Spawn above).
- **The base git clone the app branches from is a single shared working
  tree.** Concurrent fetches/branches from multiple coordinators are
  generally safe (git's own locking), and `fromRef` sidesteps most of the
  staleness problem at spawn time — but `origin/main` itself keeps moving
  for the duration of a long session; rebase at review time regardless (see
  Gate and ship).
- **Nothing enforces one-coordinator-at-a-time.** Safety today rests on
  convention — distinctive workspace/branch names, checking `ps aux` and the
  audit log before spawning, not exhausting the shared codex quota — not on
  any built-in mutual exclusion. If your workers' issues touch files another
  concurrent effort might also touch, expect ordinary merge conflicts at
  review time and resolve them like any other rebase.

## Suggestions for making this better

- **Auto-seed new worktrees' GhosttyKit build artifact.** Fold an rsync of
  `Frameworks/GhosttyKit.xcframework` from a known-good main checkout into
  the spawn step (a small wrapper around `workspace.create`, or a
  post-create hook) so N parallel workers don't each pay their own 10–20
  minute native rebuild.
- **A remaining-codex-quota check before a big fan-out.** If codex exposes
  a usage-remaining signal, check it before dispatching several `xhigh`
  workers at once, especially when you know or suspect another session is
  concurrently active.
- **A reusable, precisely-anchored monitor helper.** The `rg -q
  "^\[worker-N\] finished"` pattern is easy to get wrong ad hoc (a looser
  substring match cost real time this session); a small shared script
  (`scripts/ws-wait-for-worker.sh <log>`) would make the correct pattern the
  path of least resistance instead of something to remember.
- **A lightweight "who's active" check as a Preflight one-liner.** Tailing
  the audit log for recent timestamps and unfamiliar workspace names worked
  well as an ad hoc concurrency check today; worth promoting to a documented
  one-liner (or a `ws-op.py` subcommand) so a new coordinator session
  reaches for it automatically.
- **Namespace workspace names by coordinator, not just by issue**, once this
  skill sees regular concurrent use — `<coordinator>-<issue>-<slug>` avoids
  a name collision if two sessions ever pick up the same issue number by
  mistake.

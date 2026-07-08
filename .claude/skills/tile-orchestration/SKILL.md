---
name: tile-orchestration
description: Coordinate implementation workers (codex CLI or similar) inside WorkSpaces terminal tiles via the Automation API operator scope — spawn workspaces, bootstrap workers hands-free, monitor via logs + window snapshots, re-task idle tiles, and ship through the normal gate/merge flow. Use when dispatching multi-worker milestone execution with the WorkSpaces app as the visible fleet surface ("run workers in tiles", "tile orchestration", "dogfood the automation API"). Complements codex-execution (the per-worker contract); this skill is the fleet layer around it.
---

# Tile Orchestration

Workers run *inside* WorkSpaces tiles — visible in the owner's sidebar, one
tile per issue — while the coordinator stays *outside* (operator scope was
designed for exactly this; a coordinator inside a tile dies with every app
restart). Proven on the W5 arc (2026-07-08): five codex workers, six issues
shipped; findings in `docs/retros/2026-07-08-automation-dogfood-w5.md`.
Division of labor: this skill spawns/monitors/re-tasks; the brief contract,
gating, and merge flow are `codex-execution` unchanged.

## Preflight (once per session)

1. **App + experiments.** The app must run with Automation API + Operator
   Scope on (Settings → Experimental Features, then restart — experiments
   are read at launch). Verify with the **bundled** CLI — the Homebrew one
   is version-skewed against dev builds:
   `"<app>/Contents/Helpers/workspaces" automation health --json`.
   Confirm exactly one app instance (`ps aux | rg WorkspaceManager`) — a
   stale twin answers convincingly (see retro finding 5; #992 fixes this).
2. **Operator credential.** An opt-in launch writes
   `automation-operator.json` (0600) next to `automation.sock` under
   `~/Library/Application Support/com.cloudcompute.workspaces/`. Its absence
   means operator scope is off → toggle + restart.
3. **Fast-forward the base repo.** `workspace.create` branches from the base
   clone's LOCAL HEAD. Skip this and workers start in the past (cost a full
   rebase pass in W5): `git -C <repo.path> fetch origin main && git -C
   <repo.path> merge --ff-only origin/main`. Repo paths come from
   `GET /v1/workspaces`. (#989's `fromRef` retires this step.)
4. **Bootstrap hook present.** Tiles currently get NO automation env (#973),
   so identification is by cwd. `~/.zshrc.local` needs the hook in
   [references/bootstrap-hook.zsh](references/bootstrap-hook.zsh) —
   interactive-only guard, consume-before-source, `TMOUT=5` idle watcher.

## Spawn a worker

Use [scripts/ws-op.py](scripts/ws-op.py) (single-file uv script) for operator calls:

```bash
uv run --script scripts/ws-op.py POST /v1/workspace/create \
  '{"repoID":"<from GET /v1/workspaces>","name":"codex-<issue>-<slug>","providerID":"local"}'
```

Returns `workspacePath` + attached tile. **Warning:** each spawn currently
flips the owner's sidebar selection (verbs=clicks; #989's `select:false`
fixes it) — batch spawns and tell the owner, or spawn while they're away.

Then stage the work (paths relative to `workspacePath`; `.agents/inbox/` is
gitignored):

1. Write the brief per `codex-execution`'s template to
   `.agents/inbox/brief-<issue>.md`. Name the branch the app created
   (`workspace/<workspace-name>`) in the brief's "you are on branch" line.
2. Write `.agents/inbox/tile-start`:
   ```bash
   echo "[worker-<issue>] started $(date)" | tee .agents/inbox/worker.log
   codex exec --cd . -c model='"gpt-5.5"' -c model_reasoning_effort='"xhigh"' \
     --dangerously-bypass-approvals-and-sandbox \
     "$(cat .agents/inbox/brief-<issue>.md)" </dev/null 2>&1 | tee -a .agents/inbox/worker.log
   echo "[worker-<issue>] finished $(date)" | tee -a .agents/inbox/worker.log
   ```
   `</dev/null` is load-bearing (codex hangs on open stdin). The idle
   watcher picks the file up within ~5 s; confirm via
   `head -1 <workspacePath>/.agents/inbox/worker.log`.

## Monitor

- **Text is ground truth**: the `tee`'d `worker.log` plus a background
  watcher on the finished marker —
  `until rg -q "\[worker-<issue>\] finished" <log>; do sleep 45; done`.
  (#990 makes read-back first-class.)
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
you (check for the finished marker first).

## Gate and ship

Exactly `codex-execution` from here: read `CODEX_REPORT.md` + full diff,
react with attributed commits, rebase onto `origin/main`, clean stale build
state, re-run every gate with visible pass/fail output (don't trust
`cmd | tail` exit codes — pipes swallow failures), evidence, PR labeled
`author:codex`, merge per the arc's authority contract. Serialize merges
within a lane; re-verify a worker's branch base (`git log origin/main..`)
before review — stale bases look like huge diffs.

## Teardown

No archive verb yet (#991): stale workspaces accumulate in the owner's
sidebar; tell them what to archive, or leave live worker tiles as the
fleet view.

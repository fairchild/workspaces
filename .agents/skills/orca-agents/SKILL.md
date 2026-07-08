---
name: orca-agents
description: >
  Repo-specific conventions for fanning out sub-agent sessions (codex, claude)
  through the Orca desktop app in fairchild/workspaces, so Michael can watch
  them work live in the Orca UI and take over/type into any session himself.
  Layers on top of the global orca-cli and orchestration skills, which own the
  full CLI mechanics — this skill only adds what's specific to this repo.
disable-model-invocation: true
---

# orca-agents: Orca fan-out conventions for this repo

The global `orca-cli` and `orchestration` skills already document every flag —
read those for mechanics. This file only covers what's specific to
`fairchild/workspaces` and to Michael's stated preference: Orca is opt-in,
never the silent default.

## The gate

Default fan-out in this repo is the `Agent` tool (`subagent-delegation`
skill). Only route through Orca when Michael says so in-turn. If unsure
whether he meant "parallel Claude subagents" or "parallel Orca worktrees",
ask — don't guess toward Orca.

## Why Orca here, when it applies

Each Orca worktree runs the agent in a real PTY inside its own git worktree,
visible as a tab in the Orca app the moment it's created — Michael can watch
it stream and click in to type without any handoff protocol. That's the
whole point: visibility + takeover that a backgrounded `Agent` tool call
can't give him. It's real, billable, on-disk state (a new worktree + branch
under `~/orca/workspaces/workspaces/<name>`, a live agent process) — confirm
scope (how many agents, doing what) before creating more than one or two.

## Repo facts

- Selector: `--repo name:workspaces` (canonical remote
  `github.com/fairchild/workspaces`; confirm with `orca repo list --json` if
  it ever stops resolving — repos can be re-registered under a new id).
- Base branch: `origin/main`.
- Verified working `--agent` ids on this machine: `codex`, `claude`. The full
  registry Orca supports is in
  [references/verified-agent-ids.md](references/verified-agent-ids.md) — most
  of those ids won't have a binary installed here and will fail fast
  (`invalid_argument`) before any worktree is created.
- Fresh worktrees lack `Frameworks/GhosttyKit.xcframework` — a Swift build in
  a new Orca worktree needs it rsynced from the main checkout first (see
  `docs/development/libghostty-integration.md`). Put that step in the prompt
  if the fanned-out agent will run `swift build`/`swift test`.
- `--setup skip` skips the repo's setup hook (`bash ./scripts/setup --fast`)
  — fine for a short-lived probe, not for an agent that needs a working dev
  environment. Use `--setup run` (or the default `inherit`) when the agent
  needs to actually build/test.

## Fan out

```bash
orca worktree create --repo name:workspaces --name <slug> \
  --agent codex --prompt "<task brief>" \
  --base-branch origin/main --setup run --activate --json
```

The brief must carry the same contract every execution agent gets in this
repo (see `subagent-delegation` and `codex-execution`): issue claim protocol
from `CLAUDE.md`, draft-PR-only (never self-merge), evidence before PR,
`codex-review-loop` before opening a substantive PR. Orca doesn't know any of
this — it's just the terminal, the brief is what teaches the agent the repo's
rules.

## Watch and take over

```bash
orca worktree ps --limit 20
orca terminal list --worktree name:<slug> --json
orca terminal read --terminal <handle> --json
orca terminal switch --terminal <handle>     # foregrounds it in the Orca app for Michael to type into directly
orca terminal send --terminal <handle> --text "..." --enter   # or type into it headlessly
```

`terminal switch` is the "take over" move Michael asked for — it's a real
terminal, so once it's foregrounded he just types like normal. No CLI needed
after that unless he wants to hand control back to an automated flow.

## Clean up

```bash
orca worktree rm --worktree name:<slug> --force --json
```

Skips the repo's archive hook by default (a `warning` field on the response
says so); pass `--run-hooks` to run it. Confirm the work already shipped or
Michael's actually done with it before removing — this deletes the checkout
and its branch.

---
status: decided
date: 2026-06-06
decision: tilde-relative-unquoted-stable-dir
related:
  - docs/development/claude-code-integration.md
---

# Hook / Status-Line Forwarder Command Shape

## Decision

**Any hook or `statusLine` command the WorkSpaces app writes into `~/.claude/settings.json` must be machine-agnostic: a tilde-relative, unquoted path, extracted to a stable, space-free directory.** The canonical dir is `~/.local/share/workspaces/hook-forwarders/` (honoring `XDG_DATA_HOME`), deliberately outside `~/.claude` so an extracted script never dirties the dotclaude git tree.

Concretely, both channels emit:

```text
~/.local/share/workspaces/hook-forwarders/event-forwarder.sh
~/.local/share/workspaces/hook-forwarders/statusline.sh
```

— no leading `/Users/...`, no surrounding quotes, identical bytes on every machine.

## The problem it solves

The app writes machine-specific absolute paths into a globally-synced file and rewrites them at every launch, so the committed config in the `dotclaude` repo can never match the runtime config. That permanent mismatch keeps `~/.claude` dirty, which makes the `SessionStart` auto-deploy fast-forward silently skip. Two drift axes existed, both rooted in machine-specific absolute paths:

1. **Hooks** — `event-forwarder.sh` extracted under `~/Library/Application Support/.../HookForwarders/`. The space in `Application Support` forced single-quoting, so committed-unquoted ≠ runtime-quoted.
2. **Status line** — `statusLine.command` pointed straight at the build bundle path, a dev-worktree `.build` artifact that does not exist on a fresh machine and changes with every build location.

## Why tilde-relative + unquoted

- `~/...` is identical bytes for every user, so it is committable and never drifts.
- Tilde expansion is **not** subject to field splitting, so the path expands cleanly even when the home directory contains a space. That removes the very quoting need that caused the original bug — a space-free dir under `~` never has to be quoted.
- The cheap `exit 0` no-op stays bash; these hooks fire on every tool call in every Claude session machine-wide, so a CLI subcommand or per-call AppKit cold-start would tax every session. Zero PATH dependency.

## Why not the alternatives

- **Quote the absolute path** (the original symptom fix): keeps the machine-specific prefix, so the committed/runtime forms still differ — drift continues.
- **A CLI subcommand** (`workspaces hook forward`): adds a PATH dependency and a heavier per-tool-call no-op for a path that runs on every event in every session.
- **A daemon**: off-target. The in-app `NWListener` is already a daemon-while-running; the command string is just how Claude reaches it.

## Implementation notes

- `shellEscapedCommand` keeps a clean tilde path verbatim — `~` is in the safe-scalar set — and still quotes anything carrying a space or other unsafe scalar. A tilde path with a space would still be quoted (and would break expansion), but that cannot occur for the controlled, space-free extraction dir; the guard holds regardless.
- The installer migrates opted-in users by scrubbing any prior machine-specific event-forwarder command (an `Application Support` path or a `.build` bundle path, quoted or unquoted, ending in `HookForwarders/event-forwarder.sh`) and overwriting any prior `statusLine.command`, so everyone converges to the generic command on next launch.
- Idempotency is the property that actually keeps the tree clean: installing twice produces byte-identical `settings.json`, and a file already carrying the generic command reports `isInstalled() == true` with no write.

---
name: release-screenshot
description: Capture deterministic screenshots of the WorkSpaces macOS app in a known UI state. Use when the user asks to "capture a release screenshot", "screenshot the app", "show the Phase 1 state", or wants evidence for a PR / release notes / design brief. Wraps the fixture-mode env vars (WORKSPACES_UI_FIXTURE + WORKSPACES_UI_FIXTURE_AGENT_STATES) and the existing scripts/sidebar-capture.sh capture pipeline. Triggers on "release screenshot", "screenshot the app", "capture the app", "fixture screenshot", "ui evidence", "/release-screenshot".
---

# release-screenshot

Project skill for producing deterministic, reproducible screenshots of the WorkSpaces macOS app in a named UI state.

## Overview

The skill orchestrates `WORKSPACES_UI_FIXTURE=1` plus `WORKSPACES_UI_FIXTURE_AGENT_STATES=<scenario value>` and the existing `scripts/lib/ui-test-common.sh` helpers to launch the debug build, drive the sidebar into a chosen run-state configuration, capture the window, and quit. The bundled script `scripts/capture.sh` is the single entry point.

Default output: `output/release-screenshots/<scenario>-<iso8601>.png`. Override with `--output`.

## Quick start

```bash
.claude/skills/release-screenshot/scripts/capture.sh phase-1-release
```

Flags:

- `--scenario <id>` — named scenario from `references/scenarios.md`, or `inline:<env-var-value>` for one-offs.
- `--output <path>` — copy the captured PNG to `<path>` after capture.
- `--no-build` — skip `swift build` (assumes a current binary).
- `--keep-running` — leave the app open after capture; useful for iteration.

## Available scenarios

| Scenario | Visible |
|----------|---------|
| `phase-1-release` | Bertram-chat repo expanded with `feature-auth` selected (blue thinking), `bugfix-422` yellow (awaiting input), `refactor-state` idle; `bread-builder` collapsed with red bubbled errored dot; toolbar pill reads "2 need you". Matches `.context/ux-review/release-screenshot.png`. |
| `attention-only` | A single workspace (`bugfix-422`) in `awaitingInput` — useful when only the toolbar pill matters. |
| `clean` | No agent states applied — baseline sidebar, no dots. |

Full table with exact env-var values: see `references/scenarios.md`.

For a one-off shape that doesn't deserve a named scenario:

```bash
.claude/skills/release-screenshot/scripts/capture.sh \
  --scenario "inline:feature-auth:awaitingInput" \
  --output /tmp/one-off.png
```

The string after `inline:` becomes the literal value of `WORKSPACES_UI_FIXTURE_AGENT_STATES`.

## Adding a scenario

See `references/extending.md`. Two-step: add a `case` arm to `scripts/capture.sh`, document it in `references/scenarios.md`. Two extra lines, plus a verification run.

## Troubleshooting

- **Build fails / GhosttyKit out of date:** `./scripts/build-ghosttykit.sh` once, then retry.
- **Permission prompts (`cliclick`, `screencapture`):** open System Settings → Privacy & Security and grant Accessibility + Screen Recording to the terminal you're running from.
- **App launches but no fixture data:** verify the env var made it through with `ps aux | rg WORKSPACES_UI_FIXTURE`. If absent, you launched the installed `/Applications/WorkSpaces.app` by accident — `pkill -f WorkspaceManager` first.
- **Status dots don't match what you expected:** scenarios drive the agent registry via synthetic events; check the env-var value in `references/scenarios.md` matches your mental model.

## Known limits

- **One tab per agent-state entry.** Driving a workspace into a non-idle state requires a `HostTerminalSession`, and every session shows in the tab bar. A scenario with three entries produces three tabs. The first entry is re-activated last so its workspace is the foreground tab (matches the mockup's "selected workspace" intent).
- **All repos show expanded.** Fixture mode (`SidebarExpansionStateController.initializeRepoExpansionIfNeeded`) force-expands every repo on boot, so the design mockup's "collapsed repo with bubbled status dot" storytelling isn't achievable without modifying the controller. Repos without workspaces look identical whether expanded or collapsed; only multi-repo scenarios with workspaces under several repos see the visual difference.
- **Terminal scrollback not seeded.** PTYs spawn into the workspace path or `$HOME` if it doesn't exist; the shell prompt is whatever your default produces. The skill is for *sidebar / chrome* visual states, not terminal content.
- **Repo-overview content not seeded.** Recent commits, PR list, etc. require a real git repo at the workspace path. Fixture paths are in-memory only.
- **Selection follows `lastAccessedAt`.** The auto-selected workspace is the most-recently-accessed one. The seeder bumps `feature-auth` to win this; if you need a different default selection, add a similar bump in `UIFixtureSeeder.seedDataIfNeeded(in:)`.

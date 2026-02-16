# Scripts Guide

This directory contains build/release helpers plus UI test utilities.

## Primary UI Test Entry Points

Use these scripts for day-to-day UI verification:

1. `./scripts/launch-dev.sh`
- Canonical local launch for active development.
- Always launches latest debug binary (`.build/.../WorkspaceManager`) to avoid stale app bundle confusion.
- Uses explicit runtime data-root isolation by default:
  - `WORKSPACES_DATA_DIR=./.dev-data/workspacemanager`
- Includes inline educational notes about isolation boundaries and dogfooding strategy.
- See `backlog/isolation-strategies.md` for long-form architecture context.

2. `./scripts/ui-smoke.sh`
- Fast interaction smoke test.
- Validates launch, focus, typing, and Enter behavior.
- Writes artifacts to `/tmp/workspaces-ui-smoke-<timestamp>/`.

3. `./scripts/ui-capture.sh`
- Screenshot-focused flow capture.
- Same core interaction path plus screenshot artifacts.
- Writes artifacts to `/tmp/workspaces-ui-capture-<timestamp>/`.

4. `./scripts/sidebar-capture.sh`
- Fast deterministic sidebar-only capture loop for visual polish work.
- Launches app in `WORKSPACES_UI_FIXTURE=1` mode (in-memory sample data).
- Captures the WorkspaceManager window and writes:
  - latest: `./output/sidebar/latest.png`
  - timestamped snapshots: `./output/sidebar/sidebar-<timestamp>.png`
- Also preserves raw run artifacts under `/tmp/workspaces-sidebar-capture-<timestamp>/`.

UI automation scripts (`ui-smoke.sh`, `ui-capture.sh`, `sidebar-capture.sh`):
- fail fast on missing permissions
- print artifact directory path at the end
- use explicit app target launch (`swift run WorkspaceManager`)
- run with `WORKSPACES_DATA_DIR` pointed at a workspace-local writable folder

## Shortcut Verification Loop (dev contract)

For keyboard/split/sidebar changes, always verify with the debug launcher:

1. `./scripts/build-ghosttykit.sh`
2. `swift build`
3. `./scripts/launch-dev.sh --no-build`
4. Confirm debug process path:
   - `ps aux | rg '/Users/fairchild/code/workspaces/.build/arm64-apple-macosx/debug/WorkspaceManager'`
5. Manually verify:
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates a visible right split

Full contract and troubleshooting details:
- `docs/development/libghostty-integration.md`

## Legacy UI Scripts

Older exploratory UI scripts are archived under:

- `./scripts/legacy-ui/`

Use those only for targeted debugging or historical reference.
For normal UI validation, prefer `ui-smoke.sh` and `ui-capture.sh`.

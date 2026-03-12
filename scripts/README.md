# Scripts Guide

This directory contains build/release helpers plus UI test utilities.

## Ops Reporting

- `uv run --script ./scripts/ops-report.py`
  - Builds an operational snapshot from live GitHub history plus checked-in perf artifacts.
  - Writes `timeline.csv`, `latest-summary.json`, and `dashboard.md` to a temp directory by default.
- `uv run --script ./scripts/ops-report.py --fixtures-dir fixtures/ops-report/perf-breach --dry-run --open-idea-on-breach`
  - Replays a checked-in fixture pack without touching GitHub or `docs/ops/`.
  - Use this to observe breach selection, dedupe, and cooldown behavior on demand.
- Fixture packs live under `./fixtures/ops-report/`.
  - `docs/ops/` remains reserved for real checked-in snapshots from live data.

## Release Helpers

- `./scripts/release-version.sh`
  - Reads, sets, and validates app release version metadata from `Sources/WorkspaceManager/Resources/Info.plist`.
  - Use this instead of editing `Info.plist` by hand before tagging or notarizing a release.

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

5. `./scripts/preview-open-capture.sh`
- Deterministic preview-open capture for `Open` header polish.
- Launches with fixture bootstrap variables so a repo and target file open automatically:
  - `WORKSPACES_UI_FIXTURE_OPEN_PREVIEW=1`
  - `WORKSPACES_UI_FIXTURE_PREVIEW_REPO` (default: `skills`)
  - `WORKSPACES_UI_FIXTURE_PREVIEW_PATH` (default: `README.md`)
- Uses `capture-window.sh` first (window-id capture), then full-screen fallback.
- Rejects effectively black captures and exits with guidance when Screen Recording permission is missing.
- Captures the WorkspaceManager window and writes:
  - latest: `./output/preview-open/latest.png`
  - timestamped snapshots: `./output/preview-open/preview-open-<timestamp>.png`

6. `./scripts/capture-window.sh`
- One-shot window-only capture for shared-desktop workflows.
- Captures by window id (`screencapture -l`) and **does not activate the app by default**.
- Default output:
  - timestamped: `./output/window/window-<timestamp>.png`
  - latest copy: `./output/window/latest.png`

7. `./scripts/open-in-editor-shortcut-smoke.sh`
- End-to-end regression smoke for `Cmd+Shift+O` editor launch.
- Covers both target paths:
  - repo selected, no file preview -> open project root only
  - file preview selected -> open project root + active file
- Uses fixture mode and a fake Zed CLI shim to verify launched arguments.
- Verifies `[Perf] metric=open_in_editor_launch ... outcome=success` log evidence.

8. `./scripts/tart-webview-demo.sh`
- Runs the repo/webview transition flow inside an isolated Tart VM.
- Clones a prepared base VM, boots it with this repo mounted, drives the guest
  UI over SSH + VNC, and outputs capture artifacts under:
  - `./output/tart-webview-demo/live/<timestamp>/frames/`
  - `./output/tart-webview-demo/live/<timestamp>/webview-demo.mp4`
- This is the recommended path when shared-desktop focus contention makes local
  UI automation unreliable.

### Tart VM Setup (One-Time)

Before using `tart-webview-demo.sh`, prepare a base VM:

1. Create/pull a macOS VM image.
2. Ensure the guest has Remote Login enabled.
3. Install required guest tools:
   - `swift`
   - `cliclick`
4. In guest macOS privacy settings, grant:
   - Accessibility
5. Set base VM default:
   - `export WORKSPACES_TART_BASE_VM=<your-base-vm-name>`

Run example:

```bash
./scripts/tart-webview-demo.sh --base-vm "$WORKSPACES_TART_BASE_VM"
```

Optional flags:
- `--ssh-host <ip>` bypasses SSH auto-discovery if your bridged network is noisy.
- `--build-in-guest` builds inside the VM before launch.
- `--keep-vm` keeps the cloned run VM after completion.
- `--keep-running` leaves the run VM powered on after completion.
- `--open-vnc` opens a live VNC viewer on the host while recording.
  - default is headless (`--no-open-vnc`).

9. `./scripts/tart-webview-memory-benchmark.sh`
- Runs a repeatable memory benchmark inside an isolated Tart VM.
- For each run, it launches the app twice and samples memory in two states:
  - fixture idle launch (no web bootstrap)
  - fixture web launch (`WORKSPACES_UI_FIXTURE_SELECT_WEB_SOURCE=1`)
- Emits JSON artifacts under:
  - `./output/tart-webview-benchmark/live/<timestamp>/benchmark.json`
- Headless by default. Add `--open-vnc` only when you want to observe.
- Typical usage:
  1. `swift build -c release`
  2. `./scripts/tart-webview-memory-benchmark.sh --base-vm sequoia-base --runs 5 --binary release`

UI automation scripts (`ui-smoke.sh`, `ui-capture.sh`, `sidebar-capture.sh`, `preview-open-capture.sh`):
- fail fast on missing permissions
- print artifact directory path at the end
- use explicit app target launch (`swift run WorkspaceManager`)
- run with `WORKSPACES_DATA_DIR` pointed at a workspace-local writable folder

## Shortcut Verification Loop (dev contract)

For keyboard/split/sidebar changes, always verify with the debug launcher:

1. `./scripts/build-ghosttykit.sh`
2. `swift build`
3. `./scripts/launch-dev.sh --no-build`
   - shared-desktop safe mode: `./scripts/launch-dev.sh --no-build --no-activate`
4. Confirm debug process path:
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
5. Manually verify:
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates a visible right split
6. Capture evidence without focus steal:
   - `./scripts/capture-window.sh`

Full contract and troubleshooting details:
- `docs/development/libghostty-integration.md`

## Legacy UI Scripts

Older exploratory UI scripts are archived under:

- `./scripts/legacy-ui/`

Use those only for targeted debugging or historical reference.
For normal UI validation, prefer `ui-smoke.sh` and `ui-capture.sh`.

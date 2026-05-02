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

## Codespaces Claude Worker

- `uv run --script ./scripts/codespaces-claude-launch.py --help`
  - Shows the runner-side CLI that creates a Codespace, uploads a request file, and launches the repo's in-Codespace Claude worker.
- `uv run --script ./scripts/test_codespaces_claude_launch.py`
  - Runs stdlib tests for the launcher path.
- `./scripts/codespaces-claude-worker.sh --help`
  - Shows the Codespace-side Claude runner contract.
- Full operator documentation:
  - `./docs/development/codespaces-claude-worker.md`

## Release Helpers

- `./scripts/release-version.sh`
  - Reads, sets, and validates app release version metadata from `Sources/WorkspaceManager/Resources/Info.plist`.
  - Use this instead of editing `Info.plist` by hand before tagging or notarizing a release.
- `./scripts/verify-installed-perf.sh`
  - Verifies packaged-app Ghostty resource presence plus a clean-shell installed-build perf capture.
  - Fails if `terminal_first_output` / `first_prompt_ready` are missing or if known Ghostty resource warnings appear.
  - Requires an interactive display-capable macOS session; it is not valid in headless AppKit environments.
  - `--allow-skip-noninteractive` converts only the known display-session limitation into a recorded skip for release automation.

## Performance Contract

- `./scripts/perf-runner.sh --scenario <id>`
  - Runs one canonical scenario and writes a canonical summary artifact.
- `./scripts/perf-compare.py before.json after.json`
  - Compares two canonical summaries and prints metric deltas plus gate status.
- `./scripts/pr-evidence.sh --pr <N> --profile performance`
  - Runs the PR evidence wrapper around canonical performance comparison.
  - Writes before/after artifacts under `./output/evidence/pr-<number>/.../performance/`.
  - Uploads an SVG delta summary through `./scripts/evidence.sh`.
  - Use `--before-summary`, `--after-summary`, `--skip-before`, and `--skip-after` when comparing summaries captured on separate commits.
- Contract source of truth:
  - `./config/performance/contract.json`

## Installed Diagnostics

- `./scripts/launch-installed-diagnostics.sh`
  - Launches the installed `/Applications` app with diagnostics-oriented env vars.
  - Enables:
    - `WORKSPACES_FOCUS_DIAGNOSTICS=1`
    - `WORKSPACES_TERMINAL_DIAGNOSTICS=1`
  - Leaves `WORKSPACES_INPUT_DIAGNOSTICS` off by default because per-key logging can perturb typing measurements.
  - Disables repo auto-import by default to reduce startup noise.
  - Optional flags:
    - `--clean-shell` to bypass shell profile loading in embedded terminals
    - `--with-input-diagnostics` for short active-typing captures
    - `--no-activate` to avoid app activation on launch
    - `--capture-seconds <n>` for unattended installed-build captures
    - `--log-file <path>` to choose the capture log path

## Primary UI Test Entry Points

Use these scripts for day-to-day UI verification:

0. `./scripts/pr-evidence.sh`
- Profile-driven evidence capture for PRs.
- Creates a local evidence bundle under `./output/evidence/pr-<number>/`.
- Uploads artifacts through `./scripts/evidence.sh` and prints Markdown links.
- Initial profiles:
  - `swift-unit`: focused Swift tests, full Swift tests, and `git diff --check`.
  - `ghostty-shortcuts`: GhosttyKit build, app build, watched debug launch, foreground `Cmd+D` / `Cmd+[` / `Cmd+]` shortcut smoke, runtime log summary, and window capture.
  - `performance`: canonical before/after performance comparison rendered as uploadable PR evidence.
- Examples:
  - `./scripts/pr-evidence.sh --pr 387 --profile swift-unit --filter GhosttyRuntimeConfigFactory`
  - `./scripts/pr-evidence.sh --pr 387 --profile ghostty-shortcuts`
  - `./scripts/pr-evidence.sh --pr 387 --profile performance --scenario debug_no_activate`
  - `./scripts/pr-evidence.sh --pr 387 --profile performance --scenario debug_no_activate --before-summary /tmp/before/summary.json --after-summary /tmp/after/summary.json --skip-before --skip-after`

1. `./scripts/launch-dev.sh`
- Canonical local launch for active development.
- Always launches latest debug binary (`.build/.../WorkspaceManager`) to avoid stale app bundle confusion.
- Uses explicit runtime data-root isolation by default:
  - `WORKSPACES_DATA_DIR=./.dev-data/workspacemanager`
- Includes inline educational notes about isolation boundaries and dogfooding strategy.
- Requires a visible app window before reporting success.
- `--no-activate` keeps launch verification in shared-desktop-safe mode and does not assume the app becomes frontmost.
- In shared-desktop mode, pair the launch with `./scripts/capture-window.sh` and pause your own input during capture.
- On startup failure, writes a diagnostics bundle under `.dev-data/logs/launch-diagnostics-<timestamp>/`.
- Use `./scripts/launch-dev.sh --watch` to keep tailing the launch log until interrupted.
- See `backlog/isolation-strategies.md` for long-form architecture context.

2. `./scripts/dev-smoke.sh`
- Fast debug-app startup smoke for local development.
- Launches the debug build through `launch-dev.sh`, requires a visible window, and captures a window-only screenshot.
- `--no-activate` keeps the run shared-desktop-safe and requires window-id capture to succeed; there is no fullscreen fallback in that mode.
- Writes artifacts to:
  - `./output/dev-smoke/dev-smoke-<timestamp>.png`
  - latest launch log under `./.dev-data/logs/`

3. `./scripts/ui-smoke.sh`
- Fast interaction smoke test.
- Validates launch, focus, typing, and Enter behavior.
- Writes artifacts to `/tmp/workspaces-ui-smoke-<timestamp>/`.

4. `./scripts/ui-capture.sh`
- Screenshot-focused flow capture.
- Same core interaction path plus screenshot artifacts.
- Writes artifacts to `/tmp/workspaces-ui-capture-<timestamp>/`.

5. `./scripts/sidebar-capture.sh`
- Fast deterministic sidebar-only capture loop for visual polish work.
- Launches app in `WORKSPACES_UI_FIXTURE=1` mode (in-memory sample data).
- Captures the WorkspaceManager window and writes:
  - latest: `./output/sidebar/latest.png`
  - timestamped snapshots: `./output/sidebar/sidebar-<timestamp>.png`
- Also preserves raw run artifacts under `/tmp/workspaces-sidebar-capture-<timestamp>/`.

6. `./scripts/preview-open-capture.sh`
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

7. `./scripts/capture-window.sh`
- One-shot window-only capture for shared-desktop workflows.
- Captures by window id (`screencapture -l`) and **does not activate the app by default**.
- Makes no frontmost-app assumption; pause your own keyboard/mouse input while the capture runs, then resume.
- Default output:
  - timestamped: `./output/window/window-<timestamp>.png`
  - latest copy: `./output/window/latest.png`

8. `./scripts/open-in-editor-shortcut-smoke.sh`
- End-to-end regression smoke for `Cmd+Shift+O` editor launch.
- Covers both target paths:
  - repo selected, no file preview -> open project root only
  - file preview selected -> open project root + active file
- Uses fixture mode and a fake Zed CLI shim to verify launched arguments.
- Verifies `[Perf] metric=open_in_editor_launch ... outcome=success` log evidence.

9. `./scripts/tart-webview-demo.sh`
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

10. `./scripts/lume-e2e-capture.sh`
- Deterministic evidence capture for the Lume first-use setup flow.
- Launches in dedicated Lume fixture mode and captures the app window by
  CoreGraphics window id.
- Generates a unique workspace name per run to avoid conflicts.
- Writes artifacts under:
  - `./output/lume-e2e/latest/`
  - `./output/lume-e2e/<timestamp>/`
- Canonical runbook:
  - `docs/development/lume-validation.md`

11. `./scripts/tart-webview-memory-benchmark.sh`
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

Lume validation:
- `docs/development/lume-integration.md`
- `docs/development/lume-validation.md`
- use `./scripts/lume-e2e-capture.sh` for screenshot evidence
- use the real-host checklist in the runbook when validating actual Lume install and VM behavior

## Shortcut Verification Loop (dev contract)

For keyboard/split/sidebar changes, always verify with the debug launcher:

1. `./scripts/build-ghosttykit.sh`
2. `swift build`
3. `./scripts/dev-smoke.sh --no-build`
   - launcher-only path: `./scripts/launch-dev.sh --no-build`
   - shared-desktop safe mode: `./scripts/launch-dev.sh --no-build --no-activate`
4. Confirm debug process path:
   - `ps aux | rg '.build/arm64-apple-macosx/debug/WorkspaceManager'`
5. Manually verify:
   - `Cmd+B` toggles sidebar
   - `Cmd+D` creates a visible right split
6. Capture evidence without focus steal:
   - `./scripts/capture-window.sh`
   - in shared-desktop mode: pause input, capture, resume

Activation-driving shortcut smoke:
- `./scripts/shortcut-pass-through-smoke.sh`
- Requires Accessibility + Automation permissions.
- Requires `Terminal Multiplexing Mode = Ghostty Splits`; the script exits early in `tmux` mode.
- Intentionally not shared-desktop-safe. Use it only when foreground input is acceptable, or move to Tart/Lume / a separate user session.

If you use `mise`, equivalent convenience tasks are:
- `mise run build-ghosttykit`
- `mise run build`
- `mise run test`
- `mise run dev-launch`
- `mise run dev-watch`
- `mise run dev-smoke`
- `mise run dev-lume-preflight`
- `mise run dev-lume-standalone-preflight`
- `mise run dev-lume-standalone-prepare-base`
- `mise run dev-lume-standalone-verify-base`
- `mise run dev-lume-standalone-clone-smoke`
- `mise run dev-lume-standalone-validate`
- `mise run dev-lume-macos-smoke`

12. `./scripts/lume-host-preflight.sh`
- Fast readiness check for a real-host Lume macOS VM run.
- Verifies:
  - Apple Silicon host
  - free disk for Workspaces-managed Lume storage and `~/workspaces`
  - host macOS and Xcode detection
- direct restore-image discovery through `Virtualization`
- debug app launch through `launch-dev.sh`
- foregrounds the app by default for deterministic launch verification; use `--no-activate` only for shared-desktop-safe manual checks
- Use this before trying the full host-backed smoke.

13. `./scripts/lume-standalone-validate.sh`
- Standalone Lume-only validation gate.
- Uses the Lume CLI and daemon directly with no Swift app involvement.
- Owns the trusted validated base namespace:
  - `workspaces-validated-base-macos-<profileKey>`
- Uses isolated Workspaces-managed storage under:
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases`
  - `~/Library/Application Support/WorkspaceManager/LumeStorage/standalone-smoke`
- Writes the validated-base manifest under:
  - `~/Library/Application Support/WorkspaceManager/LumeValidatedBases/<vmName>.json`
- Writes artifacts under:
  - `./output/lume-standalone/latest/`
  - `./output/lume-standalone/<timestamp>/`
- Uses the newest Workspaces-owned Tahoe unattended profile or helper when present.
- Current default NAT Tahoe override:
  - `./config/lume/unattended/tahoe-workspaces-v26.yml`
- Bridged Tahoe diagnostics override:
  - `./config/lume/unattended/tahoe-workspaces-bridged-v27.yml`
- Current recreate-from-scratch helper:
  - `./config/lume/unattended/tahoe-workspaces-v18-official-run-bootstrap-ssh.yml`
- Stock base preparation uses `LUME_STANDALONE_PREPARE_NETWORK` and defaults it to the same value as `LUME_STANDALONE_RUN_NETWORK` (`nat` unless overridden).
- Captures:
  - `summary.md`
  - `status.json`
  - base/clone daemon snapshots
  - SSH probe transcripts
  - copied Lume daemon logs
  - `unattended-debug/` for stock base-prep failures
- For the exact manual recovery and troubleshooting path:
  - `./docs/development/lume-recreate-runbook.md`

14. `./scripts/lume-host-macos-smoke.sh`
- Long-running real-host smoke for the Lume macOS VM path.
- Runs `lume-standalone-validate.sh` first so Lume defects are caught before the Swift app path.
- Creates a disposable git repo under `~/code/`, launches the debug app with a dev-only automation mode, waits for a real Lume macOS workspace to become active, then validates `lume ssh`.
- launches the app with activation enabled so the automation window is reliably visible and the event stream starts deterministically
- Writes artifacts under:
  - `./output/lume-host-smoke/latest/`
  - `./output/lume-host-smoke/<timestamp>/`
- Captures:
  - `events.jsonl`
  - launch log
  - start/final screenshots
  - copied Lume daemon logs
  - SSH probe transcript
  - `summary.md`

Lume contract:
- the standalone validator is the only path allowed to mark a base VM `ready`
- the app/runtime may only clone from a base whose manifest is `state=ready` for the current host profile

Full contract and troubleshooting details:
- `docs/development/lume-integration.md`
- `docs/development/lume-validation.md`

15. `./scripts/lume-pr-validation.sh`
- Aggregate PR evidence chain for the Lume integration.
- Reuses an existing passing standalone bundle, then runs:
  - GhosttyKit build
  - `swift build`
  - targeted Swift tests
  - `dev-smoke`
  - `ui-smoke`
  - `lume-host-preflight`
  - `lume-host-macos-smoke`
- Writes a single summary plus per-step logs under:
  - `./output/lume-pr-validation/latest/`
  - `./output/lume-pr-validation/<timestamp>/`
- Current passing bundle:
  - `./output/lume-pr-validation/20260311-194047/`

16. `./scripts/lume-pr-evidence-prep.sh`
- Prepares a GitHub-ready evidence bundle from a passing host-smoke run.
- Verifies the host-smoke bundle has:
  - `workspace_active` in `events.jsonl`
  - `launchLogPath` in `events.jsonl`
  - the detached-launch marker in `launch.log`
  - a successful `WORKSPACES_LUME_SMOKE_OK` SSH probe
- Writes:
  - a ready-to-paste PR comment template
  - a zip containing the screenshots and supporting logs
  - a short upload README with the semi-manual GitHub steps
- Typical usage:
  - `./scripts/lume-pr-evidence-prep.sh --pr 123`
  - `./scripts/lume-pr-evidence-prep.sh --pr 123 --host-smoke-dir ./output/lume-host-smoke/20260317-200226`

## Legacy UI Scripts

Older exploratory UI scripts are archived under:

- `./scripts/legacy-ui/`

Use those only for targeted debugging or historical reference.
For normal UI validation, prefer `ui-smoke.sh` and `ui-capture.sh`.

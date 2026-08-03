# Scripts Guide

This directory contains build/release helpers plus UI test utilities.

## First-Run Setup

- `./scripts/setup --fast` is the Conductor workspace-creation path. It links local env files from a sibling worktree when needed, then validates and trusts only the reviewed root/web mise configs.
- `./scripts/setup` or `./scripts/setup --full` is the full bootstrap path. It runs fast setup, installs mise-managed tools from `mise.lock`, refreshes prek hooks, and installs dependencies when needed.
- `./scripts/setup --env-only` refreshes local env-file links without running dependency setup.
- `./scripts/setup --hooks-only` installs or refreshes the prek git hooks without running dependency setup.
- mise security rules live in [docs/development/mise-security.md](../docs/development/mise-security.md). Run `./scripts/verify-mise-security.sh` after touching mise config, lockfiles, setup/build scripts, or the sandbox mise installer. Keep secrets and global trust bypasses out of mise config.
- `web/.npmrc` enables pnpm's experimental global virtual store so repeated warm installs across Conductor workspaces reuse a shared virtual store.

## Root Mise Task Catalog

Use `./scripts/setup` for first-run bootstrap. After that, prefer the root `mise` tasks for common flows; they wrap the scripts and stable commands listed in this guide.

| Task | Backend | Purpose |
|------|---------|---------|
| `mise run setup` | `./scripts/setup` | Re-run full bootstrap setup after the checkout is trusted. |
| `mise run hooks-install` | `./scripts/setup --hooks-only` | Refresh prek hooks only. |
| `mise run build-ghosttykit` | `./scripts/build-ghosttykit.sh` | Build the pinned GhosttyKit framework. |
| `mise run lint` | `swift-format lint --strict --recursive Sources/ Tests/` | Check Swift formatting. |
| `mise run build` | `swift build` | Build the app and CLI targets. |
| `mise run test` | `swift test` | Run the Swift test suite. |
| `mise run check` | Swift format lint, build, and test | Run the local Swift validation gate. |
| `mise run dev-launch` | `./scripts/launch-dev.sh` | Launch the debug app with isolated data. |
| `mise run dev-watch` | `./scripts/launch-dev.sh --watch` | Launch and keep logs attached. |
| `mise run dev-smoke` | `./scripts/dev-smoke.sh` | Run the fast debug startup smoke. |
| `mise run claude-integration-smoke -- --pr <N>` | `./scripts/claude-integration-smoke.sh` | Run the Claude Code integration smoke evidence harness. |
| `mise run evidence -- --pr <N> --name <slug>` | `./scripts/evidence.sh` | Capture and upload PR evidence. |

Lume entry points:

| Task | Backend |
|------|---------|
| `mise run lume-status` | `uv run --script ./scripts/lume-status.py` |
| `mise run dev-lume-ensure` | `./scripts/lume-ensure-daemon.sh` |
| `mise run dev-lume-preflight` | `./scripts/lume-host-preflight.sh` |
| `mise run dev-lume-standalone-preflight` | `./scripts/lume-standalone-preflight.sh` |
| `mise run dev-lume-standalone-prepare-base` | `./scripts/lume-standalone-prepare-base.sh` |
| `mise run dev-lume-standalone-verify-base` | `./scripts/lume-standalone-verify-base.sh` |
| `mise run dev-lume-standalone-clone-smoke` | `./scripts/lume-standalone-clone-smoke.sh` |
| `mise run dev-lume-standalone-validate` | `./scripts/lume-standalone-validate.sh` |
| `mise run dev-lume-macos-smoke` | `./scripts/lume-host-macos-smoke.sh` |

Run `mise tasks` from the repo root for the current catalog. Web dashboard tasks live in `web/.mise.toml`; use `mise -C web run <task>` for those.

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
- `uv run --script ./scripts/tests/test_codespaces_claude_launch.py`
  - Runs stdlib tests for the launcher path.
- `./scripts/codespaces-claude-worker.sh --help`
  - Shows the Codespace-side Claude runner contract.
- No manual dispatch entrypoint: `.github/workflows/codespaces-claude-worker.yml` and its operator doc were retired 2026-08 (zero runs since it shipped). Run the launcher scripts above directly from a Codespace shell.

## Release Helpers

- `./scripts/release-version.sh`
  - Reads, sets, and validates app release version metadata from `Sources/WorkspaceManager/Resources/Info.plist`.
  - Use this instead of editing `Info.plist` by hand before tagging or notarizing a release.
- `./scripts/verify-installed-perf.sh`
  - Verifies packaged-app Ghostty resource presence plus a clean-shell installed-build perf capture.
  - Fails if `terminal_first_output` / `first_prompt_ready` are missing or if known Ghostty resource warnings appear.
  - Requires an interactive display-capable macOS session; it is not valid in headless AppKit environments.
  - `--allow-skip-noninteractive` converts only the known display-session limitation into a recorded skip for release automation.

## Script Test Harnesses

Standalone script tests live in `./scripts/tests/`. Keep those files executable
UV scripts with module docstrings that explain intent, not just mechanics. That
directory is for lightweight harnesses around scripts in `./scripts/`; tests for
repo-owned agent skills stay with the skill or under `.agents/scripts/`.

Common examples:

- `uv run --script ./scripts/tests/test_agent_triage.py`
  - Public GitHub mention triage and approval-gate policy tests.
- `uv run --script ./scripts/tests/test_run_contributor.py`
  - Contributor runner policy tests, including app-bot git identity selection.
- `uv run --script ./scripts/tests/test_security_hardening.py`
  - Workflow, setup, Lume, CODEOWNERS, and open-source automation hardening tests.

## Performance Contract

- `./scripts/perf-runner.sh --scenario <id>`
  - Runs one canonical scenario and writes a canonical summary artifact.
  - Installed scenarios accept either a `.app` bundle path or the bundled executable path.
- `./scripts/main-window-hotspots-baseline.py --scenario <id> --output-dir <path>`
  - Lower-level runner for canonical `main_window_*` hot-spot scenarios.
  - Prefer `perf-runner.sh`; call this directly only when debugging the hotspot runner itself.
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

0. `./scripts/evidence.sh`
- Canonical evidence capture + upload entry point (see `AGENTS.md` "Evidence-Driven Development").
- `--fixture <scenario>` launches a fixture state and snapshots the main window via operator scope — first choice for macOS-app UI evidence, no activation, no focus steal.
- `--name <slug>` captures test output, or `--file <path>` uploads an existing screenshot/log render.
- `./scripts/pr-evidence.sh` is a profile-driven wrapper built on top of it for specific PR evidence bundles:
  - Creates a local evidence bundle under `./output/evidence/pr-<number>/`.
  - Uploads artifacts through `evidence.sh` and prints Markdown links.
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

3. `./scripts/settings-window-smoke.sh`
- Activation-driving regression smoke for the app Settings entry points.
- Launches the debug app, triggers Settings via `Cmd+,` and the WorkSpaces app menu, then waits for the Settings scene accessibility identifier (`settings.root`).
- Screenshots are supporting evidence only; pass/fail comes from Accessibility finding the Settings scene.
- Requires Accessibility, Automation, and Screen Recording permissions for full evidence capture.
- Writes artifacts to:
  - `./output/settings-window-smoke/<timestamp>/`
- Run via mise:
  - `mise run dev-settings-smoke`

4. `./scripts/claude-integration-smoke.sh`
- Interactive evidence harness for the full Claude Code integration.
- Launches the debug app, discovers the live `hooks.sock` from the launch log, verifies `/healthz`, prompts through Settings install / real Claude prompt / OSC fallback / conversation log evidence steps, and writes a PR-ready comment.
- `--pr <N>` uploads each captured screenshot through `evidence.sh` when `EVIDENCE_UPLOAD_TOKEN` is available.
- `--fixture-home` launches with an isolated `HOME` containing a fixture `~/.claude/settings.json` for merge-preview evidence without touching the user's real Claude config.
- `--non-interactive` runs only the automated preflight and one launch screenshot.
- `--use-existing --deterministic-signal --host-session-id <uuid>` sends a deterministic Claude `SessionStart` and `Notification(permission_prompt)` through the installed `event-forwarder.sh`, then captures the native awaiting-input UI. Run it from an embedded terminal to use the exported `WORKSPACES_HOST_SESSION_ID`, or pass the UUID explicitly.
- Writes artifacts to `./output/claude-integration-smoke/<timestamp>/`.

5. `./scripts/ui-smoke.sh`
- Fast interaction smoke test.
- Validates launch, focus, typing, and Enter behavior.
- Writes artifacts to `/tmp/workspaces-ui-smoke-<timestamp>/`.

6. `./scripts/capture-window.sh`
- One-shot window-only capture for shared-desktop workflows.
- Captures by window id (`screencapture -l`) and **does not activate the app by default**.
- Use `--pid <pid>` when multiple WorkSpaces/WorkspaceManager debug windows are visible.
- Makes no frontmost-app assumption; pause your own keyboard/mouse input while the capture runs, then resume.
- Default output:
  - timestamped: `./output/window/window-<timestamp>.png`
  - latest copy: `./output/window/latest.png`

7. `./scripts/continuity-evidence.sh`
- App terminate/relaunch evidence for local repo/workspace terminal continuity.
- Launches the debug app with isolated data, forces `tmux_per_session` through a dev-only environment override, captures before/closed/after proof, and writes artifacts under:
  - `./output/continuity-evidence/<timestamp>/`
- Use for PRs that touch terminal continuity restore behavior:
  - `./scripts/continuity-evidence.sh --target "$HOME/code/workspaces" --no-build --trust-mise`

8. `./scripts/open-in-editor-shortcut-smoke.sh`
- End-to-end regression smoke for `Cmd+Shift+O` editor launch.
- Covers both target paths:
  - repo selected, no file preview -> open project root only
  - file preview selected -> open project root + active file
- Uses fixture mode and a fake Zed CLI shim to verify launched arguments.
- Verifies `[Perf] metric=open_in_editor_launch ... outcome=success` log evidence.

9. `./scripts/lume-e2e-capture.sh`
- Deterministic evidence capture for the Lume first-use setup flow.
- Launches in dedicated Lume fixture mode and captures the app window by
  CoreGraphics window id.
- Generates a unique workspace name per run to avoid conflicts.
- Writes artifacts under:
  - `./output/lume-e2e/latest/`
  - `./output/lume-e2e/<timestamp>/`
- Canonical runbook:
  - `docs/development/lume-validation.md`

UI automation scripts (`ui-smoke.sh`):
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

Root `mise` equivalents for this loop:
- `mise run build-ghosttykit`
- `mise run build`
- `mise run test`
- `mise run check`
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

10. `./scripts/lume-host-preflight.sh`
- Fast readiness check for a real-host Lume macOS VM run.
- Verifies:
  - Apple Silicon host
  - free disk for Workspaces-managed Lume storage and `~/workspaces`
  - host macOS and Xcode detection
- direct restore-image discovery through `Virtualization`
- debug app launch through `launch-dev.sh`
- foregrounds the app by default for deterministic launch verification; use `--no-activate` only for shared-desktop-safe manual checks
- Use this before trying the full host-backed smoke.

11. `./scripts/lume-standalone-validate.sh`
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

12. `./scripts/lume-host-macos-smoke.sh`
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

13. `./scripts/lume-pr-validation.sh`
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

14. `./scripts/lume-pr-evidence-prep.sh`
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

## Parked Scripts

Kept intentionally despite low current usage — owner decision 2026-08-02, revival intended. Do not re-flag these as dead code in future cleanup passes.

- `daytona-sandbox-manager.py` — Daytona remote-workspace surface; see `docs/daytona-vm.md` and `CONTRIBUTING.md`.
- `runner-*.sh`, `install-runner-*.sh` — self-hosted runner monitoring; see `CONTRIBUTING.md` § "Runner scripts reference".

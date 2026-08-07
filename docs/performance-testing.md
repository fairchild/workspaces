# Performance Testing and Benchmarking

This document defines how we validate performance behavior and capture benchmark baselines for Workspaces.

## What we measure

Current refinement-gate latency metrics:

1. `launch_to_first_prompt`
2. `repo_hydration`
3. `repo_click_to_focus`
4. `new_workspace_sheet_ready`
5. `main_window_session_switcher_snapshot_ms`

These are emitted from production code via `PerformanceSignposts`:
- `Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`

## Quick health checks (always run first)

From repo root:

```bash
swift test
swift build
```

This ensures perf changes are not hiding functional regressions.

## Release performance signoff

Release performance is validated against the packaged app, not the raw SwiftPM
debug binary. The installed verifier is the release gate because it confirms the
bundle contains the Ghostty runtime resources and emits the installed-only
terminal readiness metrics.

Local prerelease check:

```bash
./scripts/build-release.sh --no-sign
./scripts/verify-installed-perf.sh build/WorkSpaces.app /tmp/workspaces-installed-perf-verify-<date>
```

Signed release automation runs the same gate after `./scripts/verify-release-bundle.sh`:

```bash
./scripts/verify-installed-perf.sh --allow-skip-noninteractive build/WorkSpaces.app build/release-installed-perf
```

Use `--allow-skip-noninteractive` only on release runners that may lack an
interactive Aqua session. On a developer Mac with a real display session, a
missing installed perf result is a validation failure to diagnose before
signoff.

## PR evidence contract

Performance-sensitive PRs must carry canonical before/after evidence in the PR
body. Pick the scenario that matches the surface under review:

- Use `debug_no_activate` for debug-build UI/runtime branch deltas.
- Use `installed_clean_shell` or `installed_login_shell` for package, release,
  shell, Ghostty resource, or installed-app startup changes.

The expected debug-build workflow is:

```bash
./scripts/pr-evidence.sh --pr <N> --profile performance --scenario debug_no_activate
```

When the before/after summaries were captured on separate commits, reuse them through the same PR evidence wrapper:

```bash
./scripts/pr-evidence.sh --pr <N> --profile performance --scenario debug_no_activate \
  --before-summary /tmp/before/summary.json --after-summary /tmp/after/summary.json \
  --skip-before --skip-after
```

The lower-level helper remains available when you only need local Markdown fields without uploading an evidence artifact:

```bash
./scripts/prepare-perf-evidence.sh --scenario debug_no_activate
```

For release or packaging-sensitive PRs, include the installed verifier output
and the exact packaged-app scenario used:

```bash
./scripts/build-release.sh --no-sign
./scripts/verify-installed-perf.sh build/WorkSpaces.app /tmp/workspaces-installed-perf-verify-<slug>
./scripts/perf-runner.sh --scenario installed_login_shell --app build/WorkSpaces.app
```

The PR evidence wrapper runs the canonical scenario, captures `before` and `after` summaries, compares them with `./scripts/perf-compare.py`, writes local PR-ready Markdown, and uploads an SVG delta summary through `./scripts/evidence.sh`.

Required PR fields for `performance-sensitive` work:

- `Scenario ID`
- `Before Summary`
- `After Summary`
- `Delta Summary`

When the PR has the `performance-sensitive` label, `.github/workflows/pr-perf-evidence.yml` fails if those fields are missing. Use scenarios from `config/performance/contract.json` and keep the machine, launch mode, and workload comparable across captures.

## Debug benchmark workflow

Use the scripted baseline runner for branch-to-branch debug comparisons and
dashboard trend updates:

```bash
./scripts/perf-baseline.sh 5 8
./scripts/perf-baseline.sh 5 8 --launch-mode activate
./scripts/perf-runner.sh --scenario debug_no_activate --assert-budget
```

This is not the release signoff path. The raw debug binary may carry debug-build
overhead that the optimized packaged app does not. Budgeted debug runs resolve
the pinned Ghostty resources from `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SHARE_DIR`,
`GHOSTTY_DIR`, or the default `~/.cache/workspacemanager/ghostty/zig-out/share`
checkout; with `--assert-budget`, the script fails before launch if those
resources are unavailable. Compare debug captures only against debug captures
from the same machine, launch mode, and workload shape.

`debug_no_activate` is a startup and hydration trend scenario. It no longer
gates focus-restoration metrics such as `repo_click_to_focus` or
`workspace_click_to_focus`, because shared-desktop no-activation mode
intentionally skips foreground focus and can reuse a prompt-ready terminal
before selection focus timing can complete. Use `debug_activate` for
repo/workspace switch focus timing.

The `debug_no_activate` `launch_to_first_prompt` reference was refreshed on
2026-06-08 from a 10-run raw SwiftPM debug capture on Mac16,13 / macOS 26.4.1
after the script began enforcing clean-shell diagnostics and pinned Ghostty
resources:

- `launch_to_first_prompt`: median `591.72ms`, p95 `630.14ms`
- `repo_hydration`: median `1.32ms`, p95 `19.53ms`
- `repo_click_to_focus`: missing by scenario contract
- `workspace_click_to_focus`: missing by scenario contract

To persist results and generate a visual trend dashboard:

```bash
./scripts/perf-baseline.sh 5 8 --record
```

Arguments:

- arg1 = number of runs (default `5`)
- arg2 = seconds to keep app alive per run (default `8`)
- `--launch-mode no-activate|activate` controls whether the app launches in shared-desktop-safe no-activate mode or normal activation mode. Default is `no-activate`.

What it does:

1. Kills existing `WorkspaceManager` process.
2. Launches app with `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1`.
3. Collects `[Perf]` metric log lines from each run.
4. Produces canonical `summary.json` plus `summary.txt`.

Output location:

- `/tmp/workspaces-perf-baseline-<timestamp>/`
- key files:
  - `run-<n>.log`
  - `perf-lines.log`
  - `summary.txt`
  - `summary.json`

When `--record` is used, repo docs are updated:

- `docs/performance/metrics-history.csv`
- `docs/performance/latest-summary.json`
- `docs/performance/dashboard.md`
- `docs/performance/metrics-reference.md`

Recording cadence: the daily `perf-validation` cron runs
`./scripts/perf-baseline.sh 3 6 --record --assert-budget` whenever the tart-ui
lane is available, so the history CSV and dashboard advance automatically. When
the lane is down the workflow fails visibly instead of skipping green. To
append an ad-hoc canonical summary (a re-baseline output dir, an installed-lane
run) without re-measuring:

```bash
uv run --script scripts/perf-history-record.py --summary <output-dir>/summary.json
```

## Channel scenario workflow

The channel scenarios (hook-ingest and status-line bursts, sidebar churn,
long-session memory) run in-process Swift Testing workloads and are dispatched
through the same contract entrypoint:

```bash
./scripts/perf-runner.sh --scenario channel1_hook_ingest_burst --assert-budget
./scripts/perf-runner.sh --scenario channel2_statusline_burst --assert-budget
./scripts/perf-runner.sh --scenario channel1_sidebar_churn --assert-budget
./scripts/perf-runner.sh --scenario channel1_long_session_memory --assert-budget   # ~10 minutes
```

Each arm wraps the corresponding `scripts/perf/*/run.sh` driver via
`scripts/perf_channel_baseline.py`, canonicalizes the driver output into
`summary.json`/`summary.txt`, and asserts contract budgets. Metrics whose
contract reference is an absolute cap (long-session RSS delta, registry size
after close) gate directly against the cap. A contract-expected metric that the
driver fails to produce is a `missing` budget violation, not a pass.

## Automated CI perf workflow

The dedicated GitHub Actions workflow is `.github/workflows/perf-validation.yml`.

- Trigger it manually with `workflow_dispatch` when you want an on-demand baseline.
- It also runs on a nightly `schedule` so trend data keeps moving without blocking normal pushes.
- It runs on `[self-hosted, tart-ui]`, not in the main `CI` workflow, so app-launching perf checks stay off the interactive desktop.
- It rebuilds the app before capture, but leaves the full Swift test suite to the main `CI` workflow on GitHub-hosted macOS; this avoids headless keychain-specific failures on the Tart lane from blocking perf artifact generation.
- On `codex/**` branches, pushes that change the perf workflow, perf script, or app/test sources also trigger it so branch-local validation is possible before merge.
- A separate ubuntu-hosted runner-lane-health job classifies tart-ui availability so offline runners are treated as infra state, not product regressions.

## Installed-build parity workflow

Use the canonical installed-build wrapper when validating packaged or installed apps:

```bash
./scripts/perf-runner.sh --scenario installed_clean_shell --app build/WorkSpaces.app
./scripts/perf-runner.sh --scenario installed_login_shell --app build/WorkSpaces.app
./scripts/perf-runner.sh --scenario installed_input_short_capture --capture-seconds 15
./scripts/verify-installed-perf.sh build/WorkSpaces.app
```

These runs use the same summary schema as the debug baseline, so before/after comparisons can flow through `./scripts/perf-compare.py`.

Notes:

- `perf-runner.sh --app` accepts either a `.app` bundle or the
  `Contents/MacOS/WorkspaceManager` executable for installed scenarios.
- `installed_input_short_capture` is intentionally interactive. The app activates and you must type in the focused terminal during the capture window.
- `verify-installed-perf.sh --allow-skip-noninteractive` is reserved for release automation on runners that may lack an interactive Aqua session.

## Why `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1` is used

This env flag triggers one repo selection through the normal `handleRepoSelection` path so `repo_click_to_focus` can be measured consistently in automation.

- It is **off by default**.
- It does **not** change normal app behavior when unset.

For the deferred New Workspace path, pair it with:

- `WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE=1`

That second flag is also off by default. When both flags are set, automation opens the normal landing-path New Workspace flow once after launch so the sheet-open cost can be measured without changing behavior for normal runs.

## New Workspace sheet benchmark workflow

Use the dedicated runner when you need to quantify the deferred sheet-open path:

```bash
./scripts/new-workspace-perf.sh 5 12
./scripts/new-workspace-perf.sh 5 12 --launch-mode activate
```

Arguments:

- arg1 = number of runs (default `5`)
- arg2 = seconds to keep app alive per run (default `12`)
- `--launch-mode no-activate|activate` controls whether the app launches in shared-desktop-safe no-activate mode or normal activation mode. Default is `no-activate`.

What it does:

1. Kills any existing debug `WorkspaceManager` process.
2. Launches the app with:
   - `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1`
   - `WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE=1`
3. Collects `[Perf]` metric log lines for:
   - `new_workspace_sheet_ready`
   - `workspace_provider_availability_refresh`
   - `lume_runtime_snapshot_refresh`
   - the emitted Lume submetrics
4. Produces `summary.txt` and `summary.json` with min/median/mean/max.

Output location:

- `/tmp/workspaces-new-workspace-perf-<timestamp>/`
- key files:
  - `run-<n>.log`
  - `perf-lines.log`
  - `summary.txt`
  - `summary.json`

Recommended evidence loop for this startup-probing work:

1. Run `./scripts/perf-baseline.sh 5 8` on the pre-fix baseline commit.
2. Run `./scripts/perf-baseline.sh 5 8` on the current branch.
3. Run `./scripts/new-workspace-perf.sh 5 12` on the current branch.
4. Keep machine, run count, and data-root shape constant across local comparisons.
5. Capture median, mean, min, max, plus the launch delta percent in a dated report.

For PR submission, prefer `./scripts/prepare-perf-evidence.sh` over ad hoc notes so the evidence format stays consistent with the repo gate.

## Installed-build release validation workflow

Use the installed verifier as the primary quantitative source of truth for
release readiness:

```bash
./scripts/build-release.sh --no-sign
./scripts/verify-installed-perf.sh build/WorkSpaces.app /tmp/workspaces-installed-perf-verify-<date>
```

For a signed release artifact, the full release sequence is:

```bash
./scripts/build-release.sh
./scripts/verify-release-bundle.sh build/WorkSpaces.app
./scripts/verify-installed-perf.sh build/WorkSpaces.app build/release-installed-perf
```

When you need the login-shell view of the same packaged app, run:

```bash
./scripts/perf-runner.sh --scenario installed_login_shell --app build/WorkSpaces.app
```

Notes:

- `verify-installed-perf.sh` must produce `terminal_first_output` and
  `first_prompt_ready` in addition to `launch_to_first_prompt`.
- Release signoff uses the installed scenario budgets in
  `config/performance/contract.json`; do not apply debug `250ms` expectations to
  the packaged release app.
- If a debug run fails but the installed verifier passes, classify the debug
  result as branch-trend evidence or a debug-environment issue, not a release
  blocker.

## Manual benchmark workflow (optional)

If you want human-driven interactions:

1. Run app normally:
```bash
swift run WorkspaceManager
```
2. Perform:
   - cold launch to first usable prompt
   - repo click switching
   - workspace switches and return to host
3. Extract perf log lines from app output:
```bash
rg "\[Perf\]" <app-log-file>
```

## WebView memory benchmark (isolated VM, retired)

The isolated-Tart memory benchmark script (`tart-webview-memory-benchmark.sh`) has been removed; it was a one-time investigation, not a recurring gate. Results from the run it produced are archived in `docs/performance/webview-memory-impact-2026-02-28.md`.

## Instruments / xctrace workflow

Preferred templates:

1. `Time Profiler`
2. `SwiftUI`
3. `Hangs` (if available in your Xcode template list)

List available templates:

```bash
xcrun xctrace list templates
```

Example capture command:

```bash
xcrun xctrace record \
  --template "Time Profiler" \
  --time-limit 8s \
  --output /tmp/workspaces-time-profiler.trace \
  --launch -- /bin/zsh -lc 'cd "$(git rev-parse --show-toplevel)" && WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 swift run WorkspaceManager'
```

Notes:

- Some local environments can report ktrace start/stop errors; if that happens, treat signpost log metrics as source of truth and document the tooling limitation in your report.
- Template availability differs by Xcode/macOS version.

## Baseline reporting format

Each benchmark report should include:

1. Date and machine info (OS/build, arch, model)
2. Run configuration (`runs`, `sleep`, app launch mode)
3. Portfolio context (repo count discovered/imported)
4. Table per metric:
   - n
   - min
   - median
   - mean
   - max
5. Known caveats (permissions, xctrace errors, template gaps)

Reference example:
- `docs/performance/refinement-baseline-2026-02-15.md`
- `docs/performance/metrics-reference.md` (definitions + sequence diagrams)
- `docs/performance/webview-memory-impact-2026-02-28.md` (WebKit-specific memory/size impact)

## Suggested regression thresholds

Use these as current practical gates until updated:

1. `launch_to_first_prompt <= 250ms`
2. `repo_hydration <= 25ms` (for similar portfolio size)
3. `repo_click_to_focus <= 250ms`

If a metric exceeds threshold:

1. rerun to confirm it is persistent
2. attach logs and trace artifacts
3. document probable cause and scope before merging

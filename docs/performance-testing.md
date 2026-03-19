# Performance Testing and Benchmarking

This document defines how we validate performance behavior and capture benchmark baselines for Workspaces.

## What we measure

Current refinement-gate latency metrics:

1. `launch_to_first_prompt`
2. `repo_hydration`
3. `repo_click_to_focus`
4. `new_workspace_sheet_ready`

These are emitted from production code via `PerformanceSignposts`:
- `Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`

## Quick health checks (always run first)

From repo root:

```bash
swift test
swift build
```

This ensures perf changes are not hiding functional regressions.

## Standard benchmark workflow (recommended)

Use the scripted baseline runner:

```bash
./scripts/perf-baseline.sh 5 8
./scripts/perf-baseline.sh 5 8 --launch-mode activate
```

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
4. Produces `summary.txt` with min/median/mean/max.

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

## Automated CI perf workflow

The dedicated GitHub Actions workflow is `.github/workflows/perf-validation.yml`.

- Trigger it manually with `workflow_dispatch` when you want an on-demand baseline.
- It also runs on a nightly `schedule` so trend data keeps moving without blocking normal pushes.
- It runs on `[self-hosted, tart-ui]`, not in the main `CI` workflow, so app-launching perf checks stay off the interactive desktop.
- It rebuilds the app before capture, but leaves the full Swift test suite to the main `CI` workflow on GitHub-hosted macOS; this avoids headless keychain-specific failures on the Tart lane from blocking perf artifact generation.
- On `codex/**` branches, pushes that change the perf workflow, perf script, or app/test sources also trigger it so branch-local validation is possible before merge.

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

## Installed-build validation workflow

Use an installed app pass as validation evidence after the local repeated runs:

```bash
./scripts/install-local.sh --no-open
```

Then launch the installed app and capture local logs:

```bash
log stream --style compact --predicate 'eventMessage CONTAINS "[Perf]"'
```

Notes:

- Treat the installed run as a spot check, not the main statistical baseline.
- If local unsigned installs do not expose the expected `[Perf]` lines through unified logging, record that limitation explicitly in the report instead of fabricating timing data. The repeated local debug-run benchmarks remain the primary quantitative source of truth.

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

## WebView memory benchmark (isolated VM)

Use Tart when you need memory numbers without shared-desktop noise.

```bash
swift build -c release
./scripts/tart-webview-memory-benchmark.sh --base-vm sequoia-base --runs 5 --binary release
```

What it measures per run:

1. `idle` memory (repo/terminal view active)
2. `web_loaded` memory (after selecting the web entry and observing `metric=web_first_load`)

Artifact output:

- `output/tart-webview-benchmark/live/<timestamp>/benchmark.json`

Notes:

- Default mode is headless. Use `--open-vnc` only for live observation.
- The JSON includes both:
  - app process RSS only (`app_only`)
  - WebKit helper process RSS (`webkit_processes`)

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

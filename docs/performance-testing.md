# Performance Testing and Benchmarking

This document defines how we validate performance behavior and capture benchmark baselines for Workspaces.

## What we measure

Current refinement-gate latency metrics:

1. `launch_to_first_prompt`
2. `repo_hydration`
3. `repo_click_to_focus`

These are emitted from production code via `PerformanceSignposts`:
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`

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
```

To persist results and generate a visual trend dashboard:

```bash
./scripts/perf-baseline.sh 5 8 --record
```

Arguments:

- arg1 = number of runs (default `5`)
- arg2 = seconds to keep app alive per run (default `8`)

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

- `/Users/fairchild/code/workspaces/docs/performance/metrics-history.csv`
- `/Users/fairchild/code/workspaces/docs/performance/latest-summary.json`
- `/Users/fairchild/code/workspaces/docs/performance/dashboard.md`
- `/Users/fairchild/code/workspaces/docs/performance/metrics-reference.md`

## Why `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1` is used

This env flag triggers one repo selection through the normal `handleRepoSelection` path so `repo_click_to_focus` can be measured consistently in automation.

- It is **off by default**.
- It does **not** change normal app behavior when unset.

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
  --launch -- /bin/zsh -lc 'cd /Users/fairchild/code/workspaces && WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1 swift run WorkspaceManager'
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
- `/Users/fairchild/code/workspaces/docs/performance/refinement-baseline-2026-02-15.md`
- `/Users/fairchild/code/workspaces/docs/performance/metrics-reference.md` (definitions + sequence diagrams)

## Suggested regression thresholds

Use these as current practical gates until updated:

1. `launch_to_first_prompt <= 250ms`
2. `repo_hydration <= 25ms` (for similar portfolio size)
3. `repo_click_to_focus <= 250ms`

If a metric exceeds threshold:

1. rerun to confirm it is persistent
2. attach logs and trace artifacts
3. document probable cause and scope before merging

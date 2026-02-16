# Refinement Gate Performance Baseline (2026-02-15)

## Scope

Baseline latencies captured for refinement-gate metrics:
- launch -> first focused terminal prompt path
- repo hydration (`~/code` discovery + dedupe/import path)
- repo selection -> focused ready-to-type terminal

## Instrumentation

Production signposts and perf log metrics were added in:
- `/Users/fairchild/code/workspaces/Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`

Intervals:
- `LaunchToFirstPrompt`
- `RepoHydration`
- `RepoClickToFocusedInput`

## Environment

- Date: 2026-02-15
- OS: macOS 26.2 (25C56)
- Hardware: Apple Silicon (`arm64`), `Mac16,13`
- Build/run mode: `swift run WorkspaceManager` (debug)
- Portfolio scan context: `~/code`, `discovered=14`, `imported=0` during sampled runs

## Method

1. Added reproducible runner:
   - `/Users/fairchild/code/workspaces/scripts/perf-baseline.sh`
2. Executed:
   - `./scripts/perf-baseline.sh 5 8`
3. Script launches app with:
   - `WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO=1`
4. The env flag triggers one automatic repo selection through the same `handleRepoSelection` code path used by sidebar clicks. Default behavior is unchanged when unset.
5. Parsed `[Perf]` duration lines and summarized min/median/mean/max.

## Results (5 runs)

| Metric | n | Min (ms) | Median (ms) | Mean (ms) | Max (ms) | Target | Status |
|---|---:|---:|---:|---:|---:|---:|---|
| launch_to_first_prompt | 5 | 97.35 | 154.89 | 144.92 | 191.23 | <= 250 | pass |
| repo_hydration | 5 | 1.04 | 1.10 | 1.16 | 1.39 | <= 25 | pass |
| repo_click_to_focus | 5 | 158.86 | 159.99 | 160.85 | 163.59 | <= 250 | pass |

## Notes

- `repo_click_to_focus` completions were emitted as `outcome=focused_retry`, which is expected with the existing two-pass focus request strategy (`immediate` + `+150ms retry`).
- Attempted `xctrace` template captures for `Time Profiler` and `SwiftUI`; the local environment reported ktrace start/stop errors. Signpost metrics above are therefore the reliable baseline source for this pass.
- `xcrun xctrace list templates` in this environment does not include a `Hangs` template.

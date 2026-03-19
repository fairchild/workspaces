# Release Exception Perf Validation (2026-03-19)

## Summary

This report records the rebased March 19 release-candidate measurements used for the `v0.6.0` release decision.

The candidate was rebased onto `origin/main` before validation. Build and tests passed, but the release thresholds still fail. The release is proceeding as an explicit exception with the current performance issue called out in release messaging.

## Validation Commands

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
./scripts/perf-baseline.sh 5 8 --launch-mode no-activate
./scripts/perf-baseline.sh 5 8 --launch-mode activate
./scripts/new-workspace-perf.sh 5 12 --launch-mode no-activate
./scripts/new-workspace-perf.sh 5 12 --launch-mode activate
./scripts/perf-baseline.sh 5 8 --record --launch-mode no-activate
```

## Current Metrics

### Core launch + focus

| Mode | `launch_to_first_prompt` | `repo_click_to_focus` | `repo_hydration` | Gate Status |
| --- | ---: | ---: | ---: | --- |
| `no-activate` | `1784.76 ms` | `1346.78 ms` | `1.35 ms` | fail / fail / pass |
| `activate` | `2904.09 ms` | `1731.98 ms` | `1.98 ms` | fail / fail / pass |

Sources:

- `no-activate`: `/tmp/workspaces-perf-baseline-20260319-074208/summary.json`
- `activate`: `/tmp/workspaces-perf-baseline-20260319-074258/summary.json`

### New Workspace sheet-open

| Mode | `new_workspace_sheet_ready` | `workspace_provider_availability_refresh` | `lume_runtime_snapshot_refresh` | Gate Status |
| --- | ---: | ---: | ---: | --- |
| `no-activate` | `685.32 ms` | `0.20 ms` | `174.63 ms` | fail |
| `activate` | `559.45 ms` | `0.27 ms` | `177.19 ms` | fail |

Sources:

- `no-activate`: `/tmp/workspaces-new-workspace-perf-20260319-074428/summary.json`
- `activate`: `/tmp/workspaces-new-workspace-perf-20260319-074556/summary.json`

## Recorded History

The rolling performance history was updated from the rebased `no-activate` baseline:

- history row appended in `docs/performance/metrics-history.csv`
- dashboard regenerated in `docs/performance/dashboard.md`
- latest snapshot regenerated in `docs/performance/latest-summary.json`

Recorded baseline source:

- `/tmp/workspaces-perf-baseline-20260319-075302/summary.json`

Recorded medians:

- `launch_to_first_prompt`: `1784.48 ms`
- `repo_hydration`: `1.39 ms`
- `repo_click_to_focus`: `1367.83 ms`

## Interpretation

- The startup and terminal-focus regressions remain the blocking issue.
- The deferred provider refresh path is still cheap.
- The deferred Lume snapshot remains roughly `175-205 ms`, so it is not the dominant contributor to the current user-visible delay.

## Release Note Copy

Suggested known-issue note for `v0.6.0`:

> Known issue: release `v0.6.0` ships with a startup performance regression. Current March 19 medians are `1784.48 ms` launch-to-first-prompt and `1367.83 ms` repo-click-to-focus in shared-desktop mode, with New Workspace sheet-ready at `685.32 ms`; an activated run measured `2904.09 ms`, `1731.98 ms`, and `559.45 ms` respectively. A fix is planned for the next release.

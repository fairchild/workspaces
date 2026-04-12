# Phase 1 Perf Unblock Validation (2026-03-16)

## Summary

Phase 1 landed the intended behavior change:

- `New Workspace` opens immediately and no longer waits on Lume/runtime refresh.
- repo terminal focus now resolves from surface creation instead of a blind `+150 ms` retry.
- the perf scripts now launch the built debug binary directly instead of rebuilding with `swift run` inside the sample window.

Release is still blocked on one gate:

- `launch_to_first_prompt` improved substantially but is still above the `<= 250 ms` target.

## Validation commands

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
./scripts/dev-smoke.sh --no-build --trust-mise
./scripts/perf-baseline.sh 5 8 --launch-mode no-activate
./scripts/perf-baseline.sh 5 8 --launch-mode activate
./scripts/new-workspace-perf.sh 5 12 --launch-mode no-activate
./scripts/new-workspace-perf.sh 5 12 --launch-mode activate
```

## Before / After

### Core launch + focus

| Mode | `launch_to_first_prompt` before | `launch_to_first_prompt` after | `repo_click_to_focus` before | `repo_click_to_focus` after | `repo_hydration` after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `no-activate` | `2508.14 ms` | `423.05 ms` | `2730.07 ms` | `115.51 ms` | `4.19 ms` |
| `activate` | `3697.77 ms` | `412.80 ms` | `2597.76 ms` | `118.41 ms` | `1.40 ms` |

Sources:

- before `no-activate`: `/tmp/workspaces-perf-baseline-20260316-011218/summary.json`
- before `activate`: `/tmp/workspaces-perf-baseline-20260316-012700/summary.json`
- after `no-activate`: `/tmp/workspaces-perf-baseline-20260316-031353/summary.json`
- after `activate`: `/tmp/workspaces-perf-baseline-20260316-031442/summary.json`

### New Workspace sheet-open

| Mode | `new_workspace_sheet_ready` before | `new_workspace_sheet_ready` after | `lume_runtime_snapshot_refresh` after |
| --- | ---: | ---: | ---: |
| `no-activate` | `2287.82 ms` | `0.27 ms` | `148.58 ms` |
| `activate` | `1485.90 ms` | `0.26 ms` | `136.19 ms` |

Sources:

- before `no-activate`: `/tmp/workspaces-new-workspace-perf-20260316-012749/summary.json`
- before `activate`: `/tmp/workspaces-new-workspace-perf-20260316-012857/summary.json`
- after `no-activate`: `/tmp/workspaces-new-workspace-perf-20260316-031531/summary.json`
- after `activate`: `/tmp/workspaces-new-workspace-perf-20260316-031639/summary.json`

## Evidence

### Smoke

- screenshot: `/Users/fairchild/.codex/worktrees/f880/workspaces/output/dev-smoke/dev-smoke-20260316-030420.png`
- launch log: `/Users/fairchild/.codex/worktrees/f880/workspaces/.dev-data/logs/launch-dev-20260316-030417.log`

### Focus trace

Log: `/Users/fairchild/.codex/worktrees/f880/workspaces/.dev-data/logs/launch-dev-20260316-031310.log`

Key sequence:

- `surface_store_created` for the target repo session
- `coordinator_target_terminal_resolved` with `resolution_reason=surface_created`
- `focus_request_succeeded`
- `repo_click_to_focus duration_ms=87.93 ... outcome=focused`

### Sheet trace

Log: `/Users/fairchild/.codex/worktrees/f880/workspaces/.dev-data/logs/launch-dev-20260316-031820.log`

Key sequence:

- `landing_sheet_flow_started`
- `landing_sheet_context_set`
- `new_workspace_sheet_ready duration_ms=0.42 ... outcome=success`
- `workspace_provider_availability_refresh duration_ms=0.10`
- `lume_runtime_snapshot_refresh duration_ms=160.31`
- `landing_environment_refresh_completed`

This confirms the sheet is presented before deferred Lume work completes.

## Notes

- The first rerun of the perf scripts produced `missing` metrics because the harness was spending the sample window inside `swift run` rebuilds. Those runs are not used as acceptance evidence.
- After switching the scripts to execute the built debug binary directly, the metrics became stable again.

## Outcome

- `repo_click_to_focus`: passes the `<= 250 ms` gate.
- `repo_hydration`: passes the `<= 25 ms` gate.
- `new_workspace_sheet_ready`: passes the `<= 250 ms` gate by a large margin.
- `launch_to_first_prompt`: improved by roughly `2.1-3.3 s`, but still fails the `<= 250 ms` gate.

The release bar is therefore improved but not fully met. The remaining work is concentrated in startup-to-first-prompt latency, not in repo focus restoration or New Workspace sheet-open latency.

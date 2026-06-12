# Main-Window Hot Spots Performance Baseline (2026-06-09)

## Scope

Baseline capture for issue #637 steps 1-2 only: encode contract scenarios and record current numbers for the four structural main-window hot spots. No fixes were applied.

## Environment

- Date: 2026-06-09 21:06-21:21 America/Los_Angeles
- OS: macOS 26.4.1 (25E253)
- Hardware: Mac16,13, arm64
- Build/run mode: SwiftPM debug app
- Contract: `config/performance/contract.json`

## Commands

```bash
./scripts/perf-runner.sh --scenario main_window_agent_activity_burst --output-dir /tmp/workspaces-637-baselines/main_window_agent_activity_burst
./scripts/perf-runner.sh --scenario main_window_workspace_create_ui_stall --output-dir /tmp/workspaces-637-baselines/main_window_workspace_create_ui_stall --runs 5 --sleep-seconds 12
./scripts/perf-runner.sh --scenario main_window_idle_cpu_diagnostics_closed --output-dir /tmp/workspaces-637-baselines/main_window_idle_cpu_diagnostics_closed --capture-seconds 12
./scripts/perf-runner.sh --scenario main_window_resident_memory_20_workspaces --output-dir /tmp/workspaces-637-baselines/main_window_resident_memory_20_workspaces
```

The idle CPU and resident-memory scenarios launch the local debug app through `scripts/launch-dev.sh`. The resident-memory scenario prewarmed 20/20 terminal surfaces before sampling RSS.

## Results

| Scenario | Metric | Median | p95 | Gate | Diagnostic | Status |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `main_window_agent_activity_burst` | `main_window_agent_activity_burst_sidebar_latency_ms` | 1.51 ms | 2.01 ms | 10 ms | 24 ms | pass |
| `main_window_workspace_create_ui_stall` | `new_workspace_sheet_ready` | 0.39 ms | 0.42 ms | 500 ms | 1200 ms | pass |
| `main_window_workspace_create_ui_stall` | `workspace_provider_availability_refresh` | 0.14 ms | 0.22 ms | 125 ms | 375 ms | pass |
| `main_window_workspace_create_ui_stall` | `lume_runtime_snapshot_refresh` | 170.67 ms | 285.12 ms | 313 ms | 750 ms | pass |
| `main_window_idle_cpu_diagnostics_closed` | `main_window_idle_cpu_diagnostics_closed_percent` | 0.45% | 0.80% | 3% | 8% | pass |
| `main_window_resident_memory_20_workspaces` | `main_window_resident_memory_20_workspaces_mb` | 252.41 MB | 264.10 MB | 1500 MB | 2250 MB | pass |

## Budget Status

No budgets are breached in this baseline run.

The workspace-create path did not reproduce a user-visible sheet stall in the primary `new_workspace_sheet_ready` metric. The deferred work shows up in the supporting Lume runtime metric (`lume_runtime_snapshot_refresh`: median 170.67 ms, p95 285.12 ms), still within the initial contract gate.

The diagnostics-closed CPU result is also below budget. The current UI path starts `RuntimeDiagnosticsViewModel` from `DiagnosticsTabView.onAppear` and stops it on disappear, so this run should be treated as evidence that the original polling hypothesis is stale for the current code.

## Artifacts

- `/tmp/workspaces-637-baselines/main_window_agent_activity_burst/summary.json`
- `/tmp/workspaces-637-baselines/main_window_workspace_create_ui_stall/summary.json`
- `/tmp/workspaces-637-baselines/main_window_idle_cpu_diagnostics_closed/summary.json`
- `/tmp/workspaces-637-baselines/main_window_resident_memory_20_workspaces/summary.json`

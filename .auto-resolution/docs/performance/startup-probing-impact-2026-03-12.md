# Startup-Probing Impact - 2026-03-12

This report quantifies the impact of deferring the Lume/provider startup probing work off the initial app launch path.

## Environment

- Machine: Apple Silicon (`arm64`)
- OS: macOS `26.2` (`25C56`)
- Baseline commit: `origin/main@0581352` (`add .agents/MEMORY.md`)
- Candidate branch: `codex/issue-93-startup-probing`

## Method

Local repeated-run evidence:

1. Warm build both revisions before timing.
2. Run `./scripts/perf-baseline.sh 5 8` on the pre-fix baseline commit.
3. Run `./scripts/perf-baseline.sh 5 8` on the current branch.
4. Run `./scripts/new-workspace-perf.sh 5 12` on the current branch.
5. Keep the same machine, run count, and temp data-root shape across the local comparisons.

Installed-build spot check:

1. Run `./scripts/install-local.sh --no-open`.
2. Launch the installed app directly and through Launch Services with the perf env flags enabled.
3. Capture stderr plus unified logging around the run.

## Local Launch Comparison

`launch_to_first_prompt` is the primary startup metric for this change.

| Revision | n | Min (ms) | Median (ms) | Mean (ms) | Max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `origin/main@0581352` | 5 | 2210.48 | 2901.84 | 2789.39 | 3018.69 |
| `codex/issue-93-startup-probing` | 5 | 957.62 | 1461.53 | 1272.58 | 1479.86 |

Observed improvement:

- Median launch improved by `1440.31 ms` (`49.6%`).
- Mean launch improved by `1516.81 ms` (`54.4%`).

Artifacts:

- Pre-fix baseline: `/tmp/workspaces-perf-baseline-20260312-212544/summary.txt`
- Current branch baseline: `/tmp/workspaces-perf-baseline-20260312-211910/summary.txt`

## Deferred New Workspace Cost

The deferred user-visible cost is now measured with `new_workspace_sheet_ready`.

Observed trigger:

- `landing`

Current branch New Workspace sheet benchmark:

| Metric | n | Min (ms) | Median (ms) | Mean (ms) | Max (ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `new_workspace_sheet_ready` | 5 | 447.56 | 1060.43 | 989.45 | 1444.42 |
| `workspace_provider_availability_refresh` | 5 | 0.16 | 0.18 | 0.18 | 0.22 |
| `lume_runtime_snapshot_refresh` | 5 | 130.43 | 154.74 | 147.52 | 157.63 |
| `lume_runtime_snapshot` | 5 | 130.42 | 154.72 | 147.50 | 157.61 |
| `lume_runtime_daemon_reachability` | 5 | 20.41 | 22.60 | 24.14 | 33.45 |
| `lume_runtime_host_profile` | 5 | 78.85 | 88.13 | 87.69 | 98.55 |
| `lume_runtime_host_command.sw_vers` | 5 | 6.42 | 7.81 | 10.91 | 23.50 |
| `lume_runtime_host_command.xcodebuild` | 5 | 67.79 | 70.23 | 72.33 | 79.24 |
| `lume_runtime_host_command.xcode-select` | 5 | 3.60 | 4.19 | 4.09 | 4.37 |
| `lume_runtime_base_vm_inspection` | 5 | 28.63 | 31.60 | 32.77 | 37.60 |

Readout:

- The startup fix materially reduces launch time.
- Opening New Workspace now carries a visible but bounded deferred cost.
- Within the deferred path, provider availability refresh is negligible on this machine.
- The dominant measured runtime work is inside the Lume snapshot, especially host-profile detection and `xcodebuild -version`.

Artifact:

- Current branch New Workspace benchmark: `/tmp/workspaces-new-workspace-perf-20260312-211958/summary.txt`

## Installed-Build Spot Check

Validation performed:

- Installed the current app bundle with `./scripts/install-local.sh --no-open`.
- Launched the installed app directly via `/Applications/WorkspaceManager.app/Contents/MacOS/WorkspaceManager`.
- Launched the installed app through Launch Services with `open -na /Applications/WorkspaceManager.app`.
- Captured stderr and unified logging during both runs.

Observed result:

- The installed app launched successfully through both paths.
- The expected `[Perf]` markers did not surface through stderr or unified logging in this local unsigned install, even with the perf automation flags enabled.
- Because the app-level metrics were not observable from the installed bundle in this environment, this report does not claim installed-build launch or sheet-ready timings.

Artifacts:

- Direct installed launch stderr: `/tmp/workspaces-installed-direct-perf-ScmWXt/stdout.log`
- Broad installed log capture: `/tmp/workspaces-installed-open-perf-bMjZq6/stream.log`

Implication:

- Local installed-build timing remains a diagnostics gap.
- The repeated local debug-run benchmarks above are the reliable quantitative evidence for this change.

## Caveats

- The pre-fix baseline needed a warm build before `perf-baseline.sh` produced a valid 8-second launch sample.
- The New Workspace automation currently measures the landing entry point because it is the deterministic path in the local harness.
- Installed local unsigned bundles did not expose the new perf markers during this pass; that limitation is recorded here instead of being papered over.

---
name: workspaces-optimization
description: >
  Debug and improve WorkspaceManager performance on development hosts,
  CI or Tart lanes, and target machines.
  Use when investigating slow launch, slow typing in the Ghostty terminal,
  terminal focus lag, repo or workspace switching latency, or when collecting
  before and after evidence for a performance fix. Prefer this skill for
  requests like "optimize Workspaces", "why is typing slow", "performance
  regression", "slow machine", or "collect perf evidence".
---

# Workspaces Optimization

Use this skill when Workspaces feels slow and the next step should be evidence, not guessing.

The workflow supports two environments:

- repo checkout on a machine where you can build and run the debug app
- target machine with an installed app and little or no local repo context

## Quick Start

Collect the standard installed-app bundle on a target machine that also has a repo checkout:

```bash
./.agents/skills/workspaces-optimization/scripts/collect_installed_perf_bundle.py \
  --slow-repo /path/to/slow/repo
```

Summarize an exported diagnostic report:

```bash
./.agents/skills/workspaces-optimization/scripts/summarize_diagnostic_report.py \
  /path/to/workspaces-report.zip
```

Collect host-side shell and process evidence on a slow machine:

```bash
./.agents/skills/workspaces-optimization/scripts/host_perf_probe.py \
  --cwd /path/to/slow/repo \
  --sample-running
```

Capture active-lag samples for both the app and child shell processes:

```bash
./.agents/skills/workspaces-optimization/scripts/capture_active_lag_samples.py \
  --countdown 5 \
  --sample-seconds 8
```

Launch an installed build with focused diagnostics enabled:

```bash
./scripts/launch-installed-diagnostics.sh --clean-shell
```

Summarize the resulting `[Perf]` log:

```bash
./.agents/skills/workspaces-optimization/scripts/summarize_perf_log.py \
  /tmp/workspaces-installed-diagnostics-YYYYMMDD-HHMMSS.log
```

Run the repo's repeated launch baseline when you have a checkout and can use the debug app:

```bash
./scripts/perf-baseline.sh 5 8
./scripts/perf-baseline.sh 5 8 --launch-mode activate
```

## Workflow

### 1. Classify the environment

- If the user provides a diagnostic zip, run `summarize_diagnostic_report.py` first.
- If the machine has both the installed app and a repo checkout, prefer `collect_installed_perf_bundle.py` so the operator can run one command and return one zip bundle.
- If the machine only has the installed app, run `host_perf_probe.py` in the slow repo and use the installed app for manual repro.
- If you have a repo checkout and want an instrumented installed build run, use `./scripts/launch-installed-diagnostics.sh` with either `--clean-shell` or `--login-shell`.
- If you have the repo checkout and can build locally, use the repo perf scripts after the host probe so you have both target-machine and debug-build evidence.

### 2. Collect the smallest useful baseline

For target-machine triage:

1. Summarize the diagnostic report if available.
2. Launch the installed app with `./scripts/launch-installed-diagnostics.sh --clean-shell` and retry.
3. Launch it again with `./scripts/launch-installed-diagnostics.sh --login-shell` and compare.
4. Run `summarize_perf_log.py` on both logs and compare terminal surface timing, `terminal_first_output`, `first_prompt_ready`, and input event age.
5. Run `host_perf_probe.py --cwd <slow-repo> --sample-running`.
6. Run `capture_active_lag_samples.py` while reproducing visible lag.
7. Compare login-shell startup in the slow repo versus home.

If the primary complaint is "typing is delayed", rerun the installed launcher with:

```bash
./scripts/launch-installed-diagnostics.sh --clean-shell --with-input-diagnostics
```

Treat `--with-input-diagnostics` as a short capture mode. It logs on every key event and can perturb long typing sessions.

For repo-side tuning:

1. Run `swift build` and `swift test`.
2. Run `./scripts/perf-baseline.sh 5 8`.
3. If New Workspace is involved, run `./scripts/new-workspace-perf.sh 5 12`.
4. If focus or first-input latency is suspicious, rerun with `WORKSPACES_FOCUS_DIAGNOSTICS=1`.

### 3. Interpret the evidence before changing code

- If `launch_to_first_prompt` is huge but `repo_hydration` is tiny, the problem is in terminal readiness or focus, not repo discovery.
- If login-shell startup is much slower than a clean shell, suspect shell init, prompt tooling, repo hooks, or host-side monitoring/policy software.
- If Terminal.app is also slow in the same repo, treat that as host or shell overhead before blaming Ghostty.
- If Terminal.app is fine but Workspaces is slow, inspect the Ghostty surface creation and focus path.
- If `terminal_first_output` is early but `first_prompt_ready` is still late, the shell responded but prompt readiness is still delayed after the first terminal signal.
- If `tmux Per Session` is enabled, repeat the reproduction in `Ghostty Splits` before drawing conclusions.
- If the diagnostic report has empty `recent-logs.txt`, treat that as a diagnostics gap. Older builds may miss useful `[Perf]` lines in exported zips; newer builds broaden the recent-log capture, but a near-empty log is still a sign that you need a direct app-run capture.

Read [references/hypothesis-map.md](references/hypothesis-map.md) when you need the symptom-to-cause lookup table.
Read [references/case-studies/README.md](references/case-studies/README.md) for the local case-study convention, then look for any matching notes under `references/case-studies/`.

### 4. Read the code and docs that define the latency path

Use these repo sources for interpretation:

- `docs/performance-testing.md`
- `docs/performance/metrics-reference.md`
- `docs/performance/investigation-2026-03-16-lume-isolation-and-main-actor.md`
- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`

### 5. Optimization rules

- Keep before and after measurements on the same machine, with the same launch mode and run count.
- Prefer removing work from the first-input path over making slow critical-path work slightly faster.
- Be skeptical of anything that touches login shell startup, PTY creation, repo-aware prompt logic, or main-thread focus retries.
- For fixes, report the specific metric deltas and the exact commands used to gather them.

### 6. Local case studies

- Use `references/case-studies/` as the conventional location for host-specific investigation notes.
- Treat case studies as optional local working notes, not required committed references.
- Name files `YYYY-MM-DD-<slug>.local.md` for machine-specific notes you want to keep out of git by default.
- If a local case study produces reusable guidance, promote the durable part into `references/hypothesis-map.md`, the scripts, or this skill.

## Standalone Scripts

### `summarize_diagnostic_report.py`

Use for quick interpretation of exported `workspaces-report-*.zip` bundles.

- Reads `report.json`, `system-profile.txt`, and `recent-logs.txt`
- Flags startup patterns such as slow first prompt with fast repo hydration
- Explains when the report is missing useful logging signal

### `host_perf_probe.py`

Use on slow target machines.

- Measures login-shell and clean-shell startup from one or more directories
- Captures system context and matching process snapshots
- Optionally captures `sample` traces for running `WorkspaceManager` and child shell processes
- Writes a machine-readable `summary.json` plus a human-readable `summary.txt`

### `capture_active_lag_samples.py`

Use when the lag is visible right now and you want a timed capture while reproducing it.

- snapshots the process tree around `WorkspaceManager`
- waits for a short reproduce window
- runs `sample` for the app and matching child shell or tmux processes in parallel
- writes process-tree JSON plus a human-readable summary

### `summarize_perf_log.py`

Use after `launch-installed-diagnostics.sh` or any captured app log with `[Perf]` lines.

- groups metrics by `metric` and `phase`
- summarizes numeric fields such as `duration_ms`, `event_age_ms`, and `handler_duration_ms`
- emits quick findings about terminal surface creation and input-path timing

### `collect_installed_perf_bundle.py`

Use on target machines that have both the installed app and a checkout of this repo.

- runs clean-shell, login-shell, and optional input-diagnostics launch phases
- summarizes each log automatically
- runs the host probe
- runs active-lag sampling with a guided countdown
- writes `manifest.json`, `README.txt`, and a zip archive for easy handoff

## Guardrails

- Do not treat one timing number as enough. Always compare at least two variants.
- Do not claim an app-side fix when Terminal.app and raw login shell are slow in the same repo.
- Do not claim a shell-config problem when clean shell, login shell, and Terminal.app are all fast but Workspaces remains slow.
- When changing code, collect new evidence after the change instead of reasoning from old numbers.

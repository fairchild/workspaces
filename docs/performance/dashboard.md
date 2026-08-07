# Performance Dashboard

Last updated: `2026-08-07T08:12:53-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 674.47 | 674.47 | <= 1125 | pass | n/a |
| `repo_hydration` | n/a | n/a | <= n/a | ungated | n/a |
| `repo_click_to_focus` | n/a | n/a | <= n/a | ungated | n/a |

## Investigated Delta

- Not enough recorded history yet to compare this snapshot with a previous run.

## Trend (Last 10 Runs)

| Timestamp | Scenario | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |
|---|---|---:|---:|---:|---:|
| 2026-02-15T15:24:58-0800 | n/a | 167.03 | 1.12 | 163.95 | n/a |
| 2026-02-15T15:29:36-0800 | n/a | 249.61 | 2.59 | 167.02 | n/a |
| 2026-02-15T18:24:45-0800 | n/a | 159.01 | 1.12 | 159.20 | n/a |
| 2026-03-19T07:53:47-0700 | n/a | 1784.48 | 1.39 | 1367.83 | n/a |
| 2026-03-19T08:04:45-0700 | n/a | 2711.73 | 1.94 | 1898.94 | n/a |
| 2026-03-21T22:16:15-0700 | n/a | 3399.44 | 2.72 | 2603.74 | n/a |
| 2026-03-22T08:50:59-0700 | n/a | 1331.33 | 1.43 | 857.07 | n/a |
| 2026-03-22T10:29:08-0700 | n/a | 1468.20 | 1.24 | 1110.01 | n/a |
| 2026-08-07T08:12:40-0700 | installed_clean_shell | 288.20 | n/a | n/a | n/a |
| 2026-08-07T08:12:53-0700 | installed_login_shell | 674.47 | n/a | n/a | n/a |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 1125 ms

current 674.47 ms (60.0% of target)
[##############----------]

`repo_hydration` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

`repo_click_to_focus` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

## Run Context

- OS: `26.4.1` (build `25E253`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=n/a imported=n/a
- Sample setup: runs=n/a, sleep=n/as

## Recording Cadence

- The daily `perf-validation` cron measures the launch lanes via `./scripts/perf-baseline.sh 3 6 --record --assert-budget` whenever the tart-ui lane is up and uploads the refreshed history/dashboard as run artifacts; committing them back to the repo is a manual/orchestrated step. A run that cannot measure fails visibly instead of skipping green.
- Ad-hoc canonical summaries (e.g. re-baseline output dirs) are appended with `uv run --script scripts/perf-history-record.py --summary <summary.json>`.

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- `workspace_click_to_focus`: workspace row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

# Performance Dashboard

Last updated: `2026-08-23T21:38:53-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 1389.70 | 1384.87 | <= 1477 | pass | n/a |
| `repo_hydration` | 2.00 | 3.35 | <= 25 | pass | n/a |
| `repo_click_to_focus` | 255.05 | 278.72 | <= 275 | pass | n/a |

## Investigated Delta

- Not enough recorded history yet to compare this snapshot with a previous run.

## Trend (Last 10 Runs)

| Timestamp | Scenario | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |
|---|---|---:|---:|---:|---:|
| 2026-03-19T07:53:47-0700 | n/a | 1784.48 | 1.39 | 1367.83 | n/a |
| 2026-03-19T08:04:45-0700 | n/a | 2711.73 | 1.94 | 1898.94 | n/a |
| 2026-03-21T22:16:15-0700 | n/a | 3399.44 | 2.72 | 2603.74 | n/a |
| 2026-03-22T08:50:59-0700 | n/a | 1331.33 | 1.43 | 857.07 | n/a |
| 2026-03-22T10:29:08-0700 | n/a | 1468.20 | 1.24 | 1110.01 | n/a |
| 2026-08-07T08:12:40-0700 | installed_clean_shell | 288.20 | n/a | n/a | n/a |
| 2026-08-07T08:12:53-0700 | installed_login_shell | 674.47 | n/a | n/a | n/a |
| 2026-08-23T11:48:51-0700 | installed_clean_shell | 444.46 | n/a | n/a | n/a |
| 2026-08-23T21:37:31-0700 | debug_no_activate | 850.15 | 1.56 | 150.67 | n/a |
| 2026-08-23T21:38:53-0700 | debug_activate | 1389.70 | 2.00 | 255.05 | n/a |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 1477 ms

current 1389.70 ms (94.1% of target)
[#######################-]

`repo_hydration` target <= 25 ms

current 2.00 ms (8.0% of target)
[##----------------------]

`repo_click_to_focus` target <= 275 ms

current 255.05 ms (92.7% of target)
[######################--]

## Run Context

- OS: `26.6.2` (build `25G83`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=28 imported=0
- Sample setup: runs=10, sleep=8s

## Recording Cadence

- Measurement is opt-in on the owner's laptop, one approved session at a time: `./scripts/perf-baseline.sh 3 6 --record --assert-budget`, then commit the refreshed `docs/performance/` files. No schedule runs this — read staleness off the `Last updated` timestamp above, not off a workflow's colour. Protocol and hygiene preconditions: `docs/decisions/perf-measurement-laptop-optin.md`.
- Ad-hoc canonical summaries (e.g. re-baseline output dirs) are appended with `uv run --script scripts/perf-history-record.py --summary <summary.json>`.

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- `workspace_click_to_focus`: workspace row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

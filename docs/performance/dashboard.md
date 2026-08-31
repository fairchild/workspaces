# Performance Dashboard

Last updated: `2026-08-30T19:25:47-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 147.08 | 147.08 | <= 800 | pass | -19.54 ms (-11.7%) |
| `repo_hydration` | n/a | n/a | <= n/a | ungated | n/a |
| `repo_click_to_focus` | n/a | n/a | <= n/a | ungated | n/a |

## Investigated Delta

- Portfolio size changed from discovered=n/a to discovered=n/a, and `repo_hydration` moved n/a — unmeasured in the latest snapshot.
- Terminal readiness movement: `launch_to_first_prompt` changed -19.54 ms (-11.7%) and `repo_click_to_focus` changed n/a.
- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` measurements, is recorded in `./release-exception-validation-2026-03-19.md`.

## Trend (Last 10 Runs)

| Timestamp | Scenario | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |
|---|---|---:|---:|---:|---:|
| 2026-03-22T08:50:59-0700 | n/a | 1331.33 | 1.43 | 857.07 | n/a |
| 2026-03-22T10:29:08-0700 | n/a | 1468.20 | 1.24 | 1110.01 | n/a |
| 2026-08-07T08:12:40-0700 | installed_clean_shell | 288.20 | n/a | n/a | n/a |
| 2026-08-07T08:12:53-0700 | installed_login_shell | 674.47 | n/a | n/a | n/a |
| 2026-08-23T11:48:51-0700 | installed_clean_shell | 444.46 | n/a | n/a | n/a |
| 2026-08-23T21:37:31-0700 | debug_no_activate | 850.15 | 1.56 | 150.67 | n/a |
| 2026-08-23T21:38:53-0700 | debug_activate | 1389.70 | 2.00 | 255.05 | n/a |
| 2026-08-30T19:25:03-0700 | installed_clean_shell | 150.92 | n/a | n/a | n/a |
| 2026-08-30T19:25:25-0700 | installed_clean_shell | 166.62 | n/a | n/a | n/a |
| 2026-08-30T19:25:47-0700 | installed_clean_shell | 147.08 | n/a | n/a | n/a |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 800 ms

current 147.08 ms (18.4% of target)
[####--------------------]

`repo_hydration` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

`repo_click_to_focus` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

## Run Context

- OS: `26.6.2` (build `25G83`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=n/a imported=n/a
- Sample setup: runs=n/a, sleep=n/as

## Recording Cadence

- Measurement is opt-in on the owner's laptop, one approved session at a time: `./scripts/perf-baseline.sh 3 6 --record --assert-budget`, then commit the refreshed `docs/performance/` files. No schedule runs this — read staleness off the `Last updated` timestamp above, not off a workflow's colour. Protocol and hygiene preconditions: `docs/decisions/perf-measurement-laptop-optin.md`.
- Ad-hoc canonical summaries (e.g. re-baseline output dirs) are appended with `uv run --script scripts/perf-history-record.py --summary <summary.json>`.

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- `workspace_click_to_focus`: workspace row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

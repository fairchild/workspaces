# Performance Dashboard

Last updated: `2026-11-13T18:58:46-0800`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 74.69 | 74.69 | <= 800 | pass | -0.75 ms (-1.0%) |
| `repo_hydration` | n/a | n/a | <= n/a | ungated | n/a |
| `repo_click_to_focus` | n/a | n/a | <= n/a | ungated | n/a |

## Investigated Delta

- Portfolio size changed from discovered=n/a to discovered=n/a, and `repo_hydration` moved n/a — unmeasured in the latest snapshot.
- Terminal readiness movement: `launch_to_first_prompt` changed -0.75 ms (-1.0%) and `repo_click_to_focus` changed n/a.
- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` measurements, is recorded in `./release-exception-validation-2026-03-19.md`.

## Trend (Last 10 Runs)

| Timestamp | Scenario | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |
|---|---|---:|---:|---:|---:|
| 2026-09-14T20:30:26-0700 | installed_clean_shell | 150.49 | n/a | n/a | n/a |
| 2026-09-14T20:30:39-0700 | installed_clean_shell | 100.05 | n/a | n/a | n/a |
| 2026-09-14T20:30:53-0700 | installed_clean_shell | 142.81 | n/a | n/a | n/a |
| 2026-09-14T20:31:06-0700 | installed_clean_shell | 128.62 | n/a | n/a | n/a |
| 2026-09-14T20:31:19-0700 | installed_clean_shell | 96.22 | n/a | n/a | n/a |
| 2026-11-13T18:57:49-0800 | installed_clean_shell | 104.42 | n/a | n/a | n/a |
| 2026-11-13T18:58:03-0800 | installed_clean_shell | 90.20 | n/a | n/a | n/a |
| 2026-11-13T18:58:17-0800 | installed_clean_shell | 88.18 | n/a | n/a | n/a |
| 2026-11-13T18:58:31-0800 | installed_clean_shell | 75.44 | n/a | n/a | n/a |
| 2026-11-13T18:58:46-0800 | installed_clean_shell | 74.69 | n/a | n/a | n/a |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 800 ms

current 74.69 ms (9.3% of target)
[##----------------------]

`repo_hydration` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

`repo_click_to_focus` target <= n/a ms

current n/a ms (n/a of target)
[------------------------]

## Run Context

- OS: `27.2` (build `26B123`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=n/a imported=n/a
- Sample setup: runs=n/a, sleep=n/a

## Recording Cadence

- Measurement is opt-in on the owner's laptop, one approved session at a time: `./scripts/perf-baseline.sh 3 6 --record --assert-budget`, then commit the refreshed `docs/performance/` files. No schedule runs this — read staleness off the `Last updated` timestamp above, not off a workflow's colour. Protocol and hygiene preconditions: `docs/decisions/perf-measurement-laptop-optin.md`.
- Ad-hoc canonical summaries (e.g. re-baseline output dirs) are appended with `uv run --script scripts/perf-history-record.py --summary <summary.json>`.

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- `workspace_click_to_focus`: workspace row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

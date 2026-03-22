# Performance Dashboard

Last updated: `2026-03-22T08:50:59-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 1331.33 | 1339.39 | <= 250 | fail | -2068.11 ms (-60.8%) |
| `repo_hydration` | 1.43 | 5.35 | <= 25 | pass | -1.29 ms (-47.4%) |
| `repo_click_to_focus` | 857.07 | 850.52 | <= 250 | fail | -1746.67 ms (-67.1%) |

## Investigated Delta

- Portfolio size changed from discovered=18 to discovered=18, but `repo_hydration` only moved -1.29 ms (-47.4%) and remains within the `<= 25 ms` gate.
- The large regression is concentrated in terminal readiness: `launch_to_first_prompt` changed -2068.11 ms (-60.8%) and `repo_click_to_focus` changed -1746.67 ms (-67.1%).
- The post-activation ready-to-type gap changed -1506.00 ms (-68.9%), from `2187.00 ms` to `681.00 ms`. That points to terminal focus/readiness after activation as the main place the extra time moved.
- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` measurements, is recorded in `./release-exception-validation-2026-03-19.md`.

## Trend (Last 10 Runs)

| Timestamp | Launch (ms) | Hydration (ms) | Repo Click-to-Focus (ms) | Workspace Click-to-Focus (ms) |
|---|---:|---:|---:|---:|
| 2026-02-15T15:23:45-0800 | 229.96 | 2.58 | 158.85 | n/a |
| 2026-02-15T15:24:28-0800 | 143.23 | 1.07 | 159.91 | n/a |
| 2026-02-15T15:24:58-0800 | 167.03 | 1.12 | 163.95 | n/a |
| 2026-02-15T15:29:36-0800 | 249.61 | 2.59 | 167.02 | n/a |
| 2026-02-15T18:24:45-0800 | 159.01 | 1.12 | 159.20 | n/a |
| 2026-03-19T07:53:47-0700 | 1784.48 | 1.39 | 1367.83 | n/a |
| 2026-03-19T08:04:45-0700 | 2711.73 | 1.94 | 1898.94 | n/a |
| 2026-03-21T22:16:15-0700 | 3399.44 | 2.72 | 2603.74 | n/a |
| 2026-03-22T08:50:59-0700 | 1331.33 | 1.43 | 857.07 | n/a |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 250 ms

current 1331.33 ms (532.5% of target)
[########################]

`repo_hydration` target <= 25 ms

current 1.43 ms (5.7% of target)
[#-----------------------]

`repo_click_to_focus` target <= 250 ms

current 857.07 ms (342.8% of target)
[########################]

## Run Context

- OS: `26.2` (build `25C56`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=18 imported=0
- Sample setup: runs=5, sleep=8s

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- `workspace_click_to_focus`: workspace row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

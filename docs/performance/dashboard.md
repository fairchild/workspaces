# Performance Dashboard

Last updated: `2026-03-19T08:04:45-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 2711.73 | 2431.95 | <= 250 | fail | +927.25 ms (+52.0%) |
| `repo_hydration` | 1.94 | 12.47 | <= 25 | pass | +0.55 ms (+39.6%) |
| `repo_click_to_focus` | 1898.94 | 1773.60 | <= 250 | fail | +531.11 ms (+38.8%) |

## Investigated Delta

- Portfolio size changed from discovered=18 to discovered=18, but `repo_hydration` only moved +0.55 ms (+39.6%) and remains within the `<= 25 ms` gate.
- The large regression is concentrated in terminal readiness: `launch_to_first_prompt` changed +927.25 ms (+52.0%) and `repo_click_to_focus` changed +531.11 ms (+38.8%).
- The post-activation ready-to-type gap changed +491.00 ms (+40.0%), from `1227.00 ms` to `1718.00 ms`. That points to terminal focus/readiness after activation as the main place the extra time moved.
- Broader release-candidate context, including `activate` and `new_workspace_sheet_ready` measurements, is recorded in `./release-exception-validation-2026-03-19.md`.

## Trend (Last 10 Runs)

| Timestamp | Launch (ms) | Hydration (ms) | Click-to-Focus (ms) |
|---|---:|---:|---:|
| 2026-02-15T15:23:45-0800 | 229.96 | 2.58 | 158.85 |
| 2026-02-15T15:24:28-0800 | 143.23 | 1.07 | 159.91 |
| 2026-02-15T15:24:58-0800 | 167.03 | 1.12 | 163.95 |
| 2026-02-15T15:29:36-0800 | 249.61 | 2.59 | 167.02 |
| 2026-02-15T18:24:45-0800 | 159.01 | 1.12 | 159.20 |
| 2026-03-19T07:53:47-0700 | 1784.48 | 1.39 | 1367.83 |
| 2026-03-19T08:04:45-0700 | 2711.73 | 1.94 | 1898.94 |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 250 ms

current 2711.73 ms (1084.7% of target)
[########################]

`repo_hydration` target <= 25 ms

current 1.94 ms (7.8% of target)
[##----------------------]

`repo_click_to_focus` target <= 250 ms

current 1898.94 ms (759.6% of target)
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
- Detailed flow diagrams: `./metrics-reference.md`

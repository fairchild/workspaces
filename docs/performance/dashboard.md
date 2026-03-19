# Performance Dashboard

Last updated: `2026-03-19T07:53:47-0700`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 1784.48 | 1888.04 | <= 250 | fail | +1625.47 ms (+1022.2%) |
| `repo_hydration` | 1.39 | 8.64 | <= 25 | pass | +0.27 ms (+24.1%) |
| `repo_click_to_focus` | 1367.83 | 1343.19 | <= 250 | fail | +1208.63 ms (+759.2%) |

## Trend (Last 10 Runs)

| Timestamp | Launch (ms) | Hydration (ms) | Click-to-Focus (ms) |
|---|---:|---:|---:|
| 2026-02-15T15:23:45-0800 | 229.96 | 2.58 | 158.85 |
| 2026-02-15T15:24:28-0800 | 143.23 | 1.07 | 159.91 |
| 2026-02-15T15:24:58-0800 | 167.03 | 1.12 | 163.95 |
| 2026-02-15T15:29:36-0800 | 249.61 | 2.59 | 167.02 |
| 2026-02-15T18:24:45-0800 | 159.01 | 1.12 | 159.20 |
| 2026-03-19T07:53:47-0700 | 1784.48 | 1.39 | 1367.83 |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 250 ms

current 1784.48 ms (713.8% of target)
[########################]

`repo_hydration` target <= 25 ms

current 1.39 ms (5.6% of target)
[#-----------------------]

`repo_click_to_focus` target <= 250 ms

current 1367.83 ms (547.1% of target)
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

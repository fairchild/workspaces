# Performance Dashboard

Last updated: `2026-02-15T18:24:45-0800`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 159.01 | 151.91 | <= 250 | pass | -90.60 ms (-36.3%) |
| `repo_hydration` | 1.12 | 1.14 | <= 25 | pass | -1.47 ms (-56.8%) |
| `repo_click_to_focus` | 159.20 | 159.20 | <= 250 | pass | -7.82 ms (-4.7%) |

## Trend (Last 10 Runs)

| Timestamp | Launch (ms) | Hydration (ms) | Click-to-Focus (ms) |
|---|---:|---:|---:|
| 2026-02-15T15:23:45-0800 | 229.96 | 2.58 | 158.85 |
| 2026-02-15T15:24:28-0800 | 143.23 | 1.07 | 159.91 |
| 2026-02-15T15:24:58-0800 | 167.03 | 1.12 | 163.95 |
| 2026-02-15T15:29:36-0800 | 249.61 | 2.59 | 167.02 |
| 2026-02-15T18:24:45-0800 | 159.01 | 1.12 | 159.20 |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 250 ms

current 159.01 ms (63.6% of target)
[###############---------]

`repo_hydration` target <= 25 ms

current 1.12 ms (4.5% of target)
[#-----------------------]

`repo_click_to_focus` target <= 250 ms

current 159.20 ms (63.7% of target)
[###############---------]

## Run Context

- OS: `26.2` (build `25C56`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=14 imported=0
- Sample setup: runs=5, sleep=8s

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

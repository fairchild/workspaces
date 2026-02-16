# Performance Dashboard

Last updated: `2026-02-15T15:29:36-0800`

## Latest Snapshot

| Metric | Median (ms) | Mean (ms) | Target (ms) | Status | Delta vs Previous |
|---|---:|---:|---:|---|---|
| `launch_to_first_prompt` | 249.61 | 249.61 | <= 250 | pass | +82.59 ms (+49.4%) |
| `repo_hydration` | 2.59 | 2.59 | <= 25 | pass | +1.46 ms (+130.2%) |
| `repo_click_to_focus` | 167.02 | 167.02 | <= 250 | pass | +3.07 ms (+1.9%) |

## Trend (Last 10 Runs)

| Timestamp | Launch (ms) | Hydration (ms) | Click-to-Focus (ms) |
|---|---:|---:|---:|
| 2026-02-15T15:23:45-0800 | 229.96 | 2.58 | 158.85 |
| 2026-02-15T15:24:28-0800 | 143.23 | 1.07 | 159.91 |
| 2026-02-15T15:24:58-0800 | 167.03 | 1.12 | 163.95 |
| 2026-02-15T15:29:36-0800 | 249.61 | 2.59 | 167.02 |

## Visual Bars (Last 10 Run Window)

`launch_to_first_prompt` target <= 250 ms

current 249.61 ms (99.8% of target)
[########################]

`repo_hydration` target <= 25 ms

current 2.59 ms (10.4% of target)
[##----------------------]

`repo_click_to_focus` target <= 250 ms

current 167.02 ms (66.8% of target)
[################--------]

## Run Context

- OS: `26.2` (build `25C56`)
- Hardware: `arm64` / `Mac16,13`
- Portfolio context: discovered=14 imported=0
- Sample setup: runs=1, sleep=5s

## Metric Definitions

- `launch_to_first_prompt`: launch init -> first terminal focus success (ready to type)
- `repo_hydration`: auto-discovery/import pass for `~/code` repos
- `repo_click_to_focus`: repo row click -> focused terminal session restore
- Detailed flow diagrams: `./metrics-reference.md`

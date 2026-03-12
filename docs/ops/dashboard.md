# Ops Dashboard

Last updated: `2026-03-12T06:31:21.520469Z`

## Funnel

| Ideas | Approved | Planned | Active | Merged | Stalled |
|---:|---:|---:|---:|---:|---:|
| 4 | 1 | 1 | 1 | 0 | 0 |

## Lead Times

| Stage | Median Days |
|---|---:|
| Idea -> approval | 0.94 |
| Approval -> plan | 0.10 |
| Plan -> first PR | 0.06 |
| First PR -> merge | n/a |

## CI Health (30 Days)

| Metric | Value |
|---|---:|
| Completed runs | 492 |
| Failure rate | 9.96% |
| Rerun rate | 0.00% |

Top failing workflows:
- `CI` — 39 failure(s)
- `Release` — 5 failure(s)
- `Agent: Peter Planner` — 3 failure(s)
- `Perf Validation` — 1 failure(s)
- `Agent Ideation` — 1 failure(s)

## Perf Snapshot

Latest perf snapshot: `2026-02-15T18:24:45-0800`
Freshness: 24.2 days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 159.01 | 250.00 | -36.3% | pass |
| `repo_hydration` | 1.12 | 25.00 | -56.8% | pass |
| `repo_click_to_focus` | 159.20 | 250.00 | -4.7% | pass |

## Stale Planned Work

- none

## Current Breaches

- none

## Latest Discussions

- #42 — [idea] Surface agent-running status in sidebar workspace rows (`idea`)
- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (`active`)
- #44 — [idea] Navigate from Activity tab events directly to the relevant repo/workspace (`idea`)
- #52 — [idea] Migrate NotificationCoordinator to @Environment DI (`idea`)

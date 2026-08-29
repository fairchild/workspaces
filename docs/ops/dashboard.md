# Ops Dashboard

Last updated: `2026-08-29T13:33:01.284277Z`
Source: `live`

## Funnel

| Ideas | Approved | Planned | Active | Merged | Stalled |
|---:|---:|---:|---:|---:|---:|
| 12 | 3 | 2 | 0 | 0 | 2 |

## Lead Times

| Stage | Median Days |
|---|---:|
| Idea -> approval | 0.94 |
| Approval -> plan | 0.05 |
| Plan -> first PR | n/a |
| First PR -> merge | n/a |

## CI Health (30 Days)

| Metric | Value |
|---|---:|
| Completed runs | 499 |
| Failure rate | 2.40% |
| Rerun rate | 0.00% |

Top failing workflows:
- `Factory Review Executor` — 7 failure(s)
- `Factory Revise` — 2 failure(s)
- `Web Next Validate` — 1 failure(s)
- `CD` — 1 failure(s)
- `Factory Implement` — 1 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 58 | 0 | 0.00% | 0 | 0.00% |
| Mention Triage | 62 | 0 | 0.00% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `2026-08-23T21:38:53-0700`
Freshness: 5.4 days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 1389.70 | 1115.00 | 63.5% | fail |
| `repo_hydration` | 2.00 | 25.00 | 28.2% | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (110.7 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (42.0 days idle)

## Current Breaches

- `perf` — Performance targets regressed or exceeded threshold
- `throughput` — Planned discussions are sitting without linked PR activity

## Latest Discussions

- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (`stalled`)
- #111 — [idea] Split release.yml into three jobs: build-sign-notarize → validate-artifact → publish (`idea`)
- #112 — [idea] Archive xcresult bundles from CI and surface test failure summaries (`idea`)
- #195 — [idea] [ops] Investigate performance regression (`idea`)
- #327 — what do i need to do to have this an [Idea] discussion? [run-planner] 
I want it to run, but got 

S (`idea`)

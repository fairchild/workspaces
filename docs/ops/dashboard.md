# Ops Dashboard

Last updated: `2026-08-14T13:57:46.198507Z`
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
| Failure rate | 1.40% |
| Rerun rate | 0.20% |

Top failing workflows:
- `Factory Review Executor` — 4 failure(s)
- `CI Fallback` — 1 failure(s)
- `CI` — 1 failure(s)
- `PR Readiness` — 1 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 44 | 0 | 0.00% | 0 | 0.00% |
| Mention Triage | 51 | 0 | 0.00% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `None`
Freshness: n/a days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 674.47 | 740.00 | 134.0% | pass |
| `repo_hydration` | n/a | 25.00 | n/a | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (95.7 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (27.0 days idle)

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

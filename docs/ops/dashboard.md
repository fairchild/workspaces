# Ops Dashboard

Last updated: `2026-09-12T13:33:04.787094Z`
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
| Failure rate | 1.80% |
| Rerun rate | 0.20% |

Top failing workflows:
- `Factory Review Executor` — 3 failure(s)
- `Factory Implement` — 2 failure(s)
- `PR Readiness` — 2 failure(s)
- `CI — Agent Scripts` — 1 failure(s)
- `CI Fallback` — 1 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 63 | 0 | 0.00% | 0 | 0.00% |
| Mention Triage | 63 | 0 | 0.00% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `None`
Freshness: n/a days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 146.70 | 1115.00 | -3.9% | pass |
| `repo_hydration` | n/a | 25.00 | n/a | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (180.9 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (172.0 days idle)

## Current Breaches

- `throughput` — Planned discussions are sitting without linked PR activity

## Latest Discussions

- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (`stalled`)
- #111 — [idea] Split release.yml into three jobs: build-sign-notarize → validate-artifact → publish (`idea`)
- #112 — [idea] Archive xcresult bundles from CI and surface test failure summaries (`idea`)
- #195 — [idea] [ops] Investigate performance regression (`idea`)
- #327 — what do i need to do to have this an [Idea] discussion? [run-planner] 
I want it to run, but got 

S (`idea`)

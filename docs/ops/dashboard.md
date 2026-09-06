# Ops Dashboard

Last updated: `2026-09-06T13:33:09.067355Z`
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
| Failure rate | 1.20% |
| Rerun rate | 0.00% |

Top failing workflows:
- `PR Readiness` — 4 failure(s)
- `Probe Failed Job Outputs` — 1 failure(s)
- `Factory Review Executor` — 1 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 54 | 0 | 0.00% | 0 | 0.00% |
| Mention Triage | 66 | 0 | 0.00% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `None`
Freshness: n/a days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 146.70 | 1115.00 | -3.9% | pass |
| `repo_hydration` | n/a | 25.00 | n/a | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (174.9 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (166.0 days idle)

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

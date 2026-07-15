# Ops Dashboard

Last updated: `2026-07-15T14:09:02.018149Z`
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
| Failure rate | 12.42% |
| Rerun rate | 0.00% |

Top failing workflows:
- `Managed Reviewer Health` — 34 failure(s)
- `PR Readiness` — 14 failure(s)
- `Factory Implement` — 6 failure(s)
- `Factory Review Executor` — 4 failure(s)
- `Repo Settings Drift` — 1 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 28 | 0 | 0.00% | 0 | 0.00% |
| Carl Community | 1 | 1 | 100.00% | 0 | 0.00% |
| Mention Triage | 26 | 0 | 0.00% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `2026-03-22T10:29:08-0700`
Freshness: 114.9 days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 1468.20 | 740.00 | 10.3% | fail |
| `repo_hydration` | 1.24 | 25.00 | -13.3% | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (65.7 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (65.7 days idle)

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

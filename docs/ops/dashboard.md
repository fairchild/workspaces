# Ops Dashboard

Last updated: `2026-07-27T14:17:18.482946Z`
Source: `live`

## Funnel

| Ideas | Approved | Planned | Active | Merged | Stalled |
|---:|---:|---:|---:|---:|---:|
| 12 | 3 | 2 | 0 | 0 | 1 |

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
| Failure rate | 9.02% |
| Rerun rate | 0.00% |

Top failing workflows:
- `Managed Reviewer Health` — 35 failure(s)
- `Milestone Legibility` — 7 failure(s)
- `Agent: Carl Community` — 3 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Carl Community | 7 | 3 | 42.86% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `2026-03-22T10:29:08-0700`
Freshness: 126.9 days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 1468.20 | 740.00 | 10.3% | fail |
| `repo_hydration` | 1.24 | 25.00 | -13.3% | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (77.7 days idle)

## Current Breaches

- `perf` — Performance targets regressed or exceeded threshold
- `agent` — Individual agent failure rate crossed the alert threshold

## Latest Discussions

- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (`planned`)
- #111 — [idea] Split release.yml into three jobs: build-sign-notarize → validate-artifact → publish (`idea`)
- #112 — [idea] Archive xcresult bundles from CI and surface test failure summaries (`idea`)
- #195 — [idea] [ops] Investigate performance regression (`idea`)
- #327 — what do i need to do to have this an [Idea] discussion? [run-planner] 
I want it to run, but got 

S (`idea`)

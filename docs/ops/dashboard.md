# Ops Dashboard

Last updated: `2026-07-13T03:16:27.356695Z`
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
| Completed runs | 493 |
| Failure rate | 6.69% |
| Rerun rate | 0.00% |

Top failing workflows:
- `Managed Reviewer Health` — 11 failure(s)
- `CD` — 8 failure(s)
- `Web Next CI` — 7 failure(s)
- `Agent: Plat Ironwood` — 2 failure(s)
- `Agent: April Clearwater` — 2 failure(s)

## Agent Health

| Agent | Runs | Failures | Rate | Reruns | Rerun Rate |
|---|---:|---:|---:|---:|---:|
| Approved Mention Execution | 51 | 0 | 0.00% | 0 | 0.00% |
| April Clearwater | 3 | 2 | 66.67% | 0 | 0.00% |
| Carl Community | 1 | 1 | 100.00% | 0 | 0.00% |
| Fable Orchestrator | 1 | 0 | 0.00% | 0 | 0.00% |
| Mention Triage | 31 | 0 | 0.00% | 0 | 0.00% |
| Plat Ironwood | 3 | 2 | 66.67% | 0 | 0.00% |

## Perf Snapshot

Latest perf snapshot: `2026-03-22T10:29:08-0700`
Freshness: 112.4 days

| Metric | Latest Median (ms) | Target (ms) | Delta vs Previous | Status |
|---|---:|---:|---:|---|
| `launch_to_first_prompt` | 1468.20 | 740.00 | 10.3% | fail |
| `repo_hydration` | 1.24 | 25.00 | -13.3% | pass |

## Stale Planned Work

- #43 — [task] [idea][endorsed] Isolate intrusive CI jobs onto a Tart VM runner lane (63.3 days idle)
- #110 — [idea][endorsed] Fix environment status color semantics in New Workspace sheet (63.3 days idle)

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

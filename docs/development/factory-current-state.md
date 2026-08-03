# Agent Factory: Current State

What is actually wired and running today, verified against the workflow YAML and live `gh variable list` output on 2026-08-03. `docs/development/agent-factory-v2-plan.md` is the design record — why the pipeline looks like this. This doc is the operational reference — which of it is live, how to turn a lane on or off, and where the telemetry lives. Update it whenever a lane's trigger, guard, or status changes; it will drift otherwise.

## Lane table

| Lane | Workflow | Trigger | Guard | Status |
|---|---|---|---|---|
| Implement | `factory-implement.yml` | issue labeled `ready` (owner-applied only); or owner `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_IMPLEMENT_ENABLED`, capped by `FACTORY_IMPLEMENT_DAILY_CAP` | **Live** |
| Review (signal) | `factory-review.yml` | PR opened / `ready_for_review` / synchronize; or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_REVIEW_ENABLED` | **Live** — untrusted, writes a context artifact only |
| Review (execute) | `factory-review-execute.yml` | `workflow_run` of Factory Review completing | same as above, plus `FACTORY_REVIEW_DAILY_CAP` | **Live** — trusted, runs from default-branch code |
| Monitor | `factory-monitor.yml` | daily cron (13:30 UTC); or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_MONITOR_ENABLED` | **Live** — telemetry, Digest, reconciliation janitor |
| Evidence Verify | `factory-evidence-verify.yml` | `check_suite` completed; or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_EVIDENCE_VERIFY_ENABLED` | **Wired but effectively off** — `FACTORY_EVIDENCE_VERIFY_ENABLED` is unset in `gh variable list`, and an unset repo variable reads as empty in Actions expressions, so the guard never passes. Nothing currently sets this switch. |
| Owner Comment Responder | `factory-comment-responder.yml` | `issue_comment` created by the owner; or owner `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_RESPONDER_ENABLED` | **Live** |
| Mention Triage → Executor | `agent-mention.yml` → `agent-executor.yml` | `@april-clearwater` / `@plat` / `@peter` / `@claude` mentions on issues/PRs/reviews | `AGENT_AUTOMATIONS_ENABLED`; execution additionally requires the `safe-to-run-agent` label, server-verified | **Live** — this is a distinct lane from the "Triage" pipeline Stage below; naming collision, not the same code path |
| Milestone Legibility | `milestone-legibility.yml` | daily cron (13:37 UTC); PR touching the check script; `workflow_dispatch` | none (no Factory switch — always runs) | **Live** |
| Evidence Reminder | `evidence-reminder.yml` | PR opened/edited/`ready_for_review` | none | **Live** — plain CI gate, not part of the Factory pipeline |
| Triage / Spec (pipeline Stages) | none | — | — | **Aspirational.** `docs/agents/CONTEXT.md` names these as Factory Stages and assigns them to Peter, but no workflow triggers `run-planner.py` today. See "Peter planner: parked" below. |
| Carl Community | — | — | — | **Deleted this PR.** Daily cron that only 429s or no-ops; never posted once; not a v2-plan persona. |
| Codespaces Claude Worker | — | — | — | **Deleted this PR.** Manual break-glass dispatch; zero runs since it shipped. |
| App Review Smoke | — | — | — | **Deleted this PR.** Manual dispatch; dormant since 2026-05-26. |

`AGENT_AUTOMATIONS_ENABLED` is the global master switch — every Factory lane except Milestone Legibility and Evidence Reminder requires it `true` in addition to its own per-stage switch.

## Peter planner: parked

`.agents/scripts/run-planner.py` (a compatibility shim over `.agents/skills/peter-planner/scripts/run-planner.py`) and the `peter-planner` skill were hardened twice (#1133, #1144), and their tests (`.agents/scripts/test_run_planner.py`) still run in `ci-agents.yml`. No workflow exists that invokes the runtime — `agent-peter.yml` was never re-created after the v1 retirement, so nothing calls it on any trigger. This PR leaves it in place rather than deleting it: wiring it up is Milestone M2 ("Front door" — Triage stage) of the v2 plan, and dropping the hardened runtime now would just mean rebuilding it later. Revisit at M2; drop it only if M2 is abandoned outright.

## Switch inventory

Live values as of 2026-08-03 (`gh variable list --repo fairchild/workspaces`):

| Variable | Value | Gates |
|---|---|---|
| `AGENT_AUTOMATIONS_ENABLED` | `true` | Global master — every lane above except Milestone Legibility / Evidence Reminder |
| `FACTORY_IMPLEMENT_ENABLED` | `true` | Implement lane |
| `FACTORY_IMPLEMENT_DAILY_CAP` | `6` | Implement lane — max owner-authorized `factory-implement.yml` runs per UTC day |
| `FACTORY_REVIEW_ENABLED` | `true` | Review (signal + execute) lanes |
| `FACTORY_REVIEW_DAILY_CAP` | `12` | Review (execute) lane — max executor attempts per UTC day, including reruns |
| `FACTORY_MONITOR_ENABLED` | `true` | Monitor lane |
| `FACTORY_RESPONDER_ENABLED` | `true` | Owner Comment Responder lane |
| `FACTORY_EVIDENCE_VERIFY_ENABLED` | *(unset)* | Evidence Verify lane — unset means off; set it to `true` to activate |

`APPLE_ID`, `APPLE_TEAM_ID`, and `PREFERRED_RUNNER` also show up in `gh variable list` but are release/runner configuration, not Factory switches.

## Enable or disable a lane

```bash
# Turn a lane off without touching workflow YAML:
gh variable set FACTORY_IMPLEMENT_ENABLED --body false --repo fairchild/workspaces

# Turn it back on:
gh variable set FACTORY_IMPLEMENT_ENABLED --body true --repo fairchild/workspaces

# Kill every Factory lane at once (Milestone Legibility and Evidence Reminder are unaffected):
gh variable set AGENT_AUTOMATIONS_ENABLED --body false --repo fairchild/workspaces
```

A disabled lane's `if:` guard simply evaluates false — the job is skipped, not queued, so flipping the switch back on does not replay missed events. `workflow_dispatch` from the repository owner bypasses the trigger condition but never the switch itself (see the `if:` blocks above): every lane still requires its guard variables to be `true`.

## `factory/ops-data` branch contract

`factory/ops-data` is an orphan branch (no shared history with `main`) written only by CI, never by hand and never through a PR — `main` is PR-only and can't take direct telemetry commits, so the Monitor lane pushes straight to this branch instead. `factory-monitor.yml` creates it on first run (orphan `git switch --orphan`, seeded with a README) and thereafter checks it out, regenerates `docs/ops/` via `scripts/ops-report.py`, and pushes only if `docs/ops/dashboard.md`, `docs/ops/latest-summary.json`, or `docs/ops/timeline.csv` changed. `scripts/factory-cost-append.py` separately appends per-run cost rows to `docs/ops/cost/runs.jsonl` on that same branch, deduplicated by row `id` so re-runs and lane races don't double-count.

**Retention**: none exists today. `runs.jsonl` is append-only and dedup-only — nothing prunes or rotates it. It will grow without bound as long as the Factory runs; if it becomes a problem, that's follow-up work, not something this PR invents a policy for.

## Dashboard: `scripts/factory-dashboard.py`

Local-only reporting tool — no server, no hosted tracing. Pulls from three on-disk-cacheable sources (Actions API workflow runs, issue/PR label-event timelines, and `factory/ops-data`'s cost rows) into a SQLite cache, then renders a static HTML report. A missing or unreachable source degrades to a stale banner rather than crashing.

```bash
# Sync new signal into the local cache, then render:
uv run --script scripts/factory-dashboard.py --sync --render

# Render only, from whatever's already cached:
uv run --script scripts/factory-dashboard.py --render --days 30

# Or via mise:
mise run factory-dashboard
```

`--days` sets the reporting window (default 30); `--db` and `--out` override the cache and HTML output paths if you don't want the defaults.

## Dispatch mechanism (in flight)

Today, standing `ready` issues only get dispatched once — the Implement lane fires off the `ready` label event, and if that run doesn't land a PR (transient failure, cap exhaustion, whatever), the issue just sits until a human re-toggles the label. PR #1172 ("level-triggered sweep for the standing ready queue") closes that gap: a new `scripts/factory-sweep.py`, invoked daily from `factory-monitor.yml`, re-dispatches `factory-implement.yml` for the oldest standing `ready`+`agent`+`task` issues with no open linked PR, within the remaining `FACTORY_IMPLEMENT_DAILY_CAP` headroom for the day. It re-fires standing admission without ever granting new admission itself — `claim()`'s owner-actor and content-staleness checks in `factory-implement.py` are unchanged and still gate every dispatch, sweep-triggered or not. Not merged as of this writing; once it lands, add a row to the switch inventory above for whatever guard variable it introduces.

## References

- `docs/development/agent-factory-v2-plan.md` — design record: why this pipeline, the decisions behind it, the milestone roadmap
- `docs/agents/CONTEXT.md` — Factory vocabulary (Stage, Gate, Persona, etc.)
- `docs/agents/triage-labels.md` — the `ready`/`claimed`/`review`/`mergeable` label state machine and `author:*` attribution labels
- `docs/development/evidence.md` — the evidence lane the Implement lane reuses as-is

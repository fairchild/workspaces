# Agent Factory: Current State

What is actually wired and running today, verified against the workflow YAML and live `gh variable list` output on 2026-08-04. `docs/development/agent-factory-v2-plan.md` is the design record — why the pipeline looks like this. This doc is the operational reference — which of it is live, how to turn a lane on or off, and where the telemetry lives. Update it whenever a lane's trigger, guard, or status changes; it will drift otherwise.

## Lane table

| Lane | Workflow | Trigger | Guard | Status |
|---|---|---|---|---|
| Implement | `factory-implement.yml` | issue labeled `ready` (owner-applied, or a factory rollback restoring an owner-applied one — see below); or owner `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_IMPLEMENT_ENABLED`, both branches — capped by `FACTORY_IMPLEMENT_DAILY_CAP` | **Live** |
| Review (signal) | `factory-review.yml` | PR opened / `ready_for_review` / synchronize; or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_REVIEW_ENABLED` on the PR-event path only — **`workflow_dispatch` bypasses both switches** (the `if:` uses boolean OR, not AND) | **Live** — untrusted, writes a context artifact only |
| Review (execute) | `factory-review-execute.yml` | `workflow_run` of Factory Review completing | same switches, same bypass — if the upstream Review run's triggering event was `workflow_dispatch`, this job runs regardless of either switch; otherwise gated, plus `FACTORY_REVIEW_DAILY_CAP` | **Live** — trusted, runs from default-branch code |
| Monitor | `factory-monitor.yml` | daily cron (13:30 UTC); or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_MONITOR_ENABLED` on the cron path only — **`workflow_dispatch` bypasses both switches** (same OR-not-AND pattern) | **Live** — telemetry, Digest, reconciliation janitor |
| Evidence Verify | `factory-evidence-verify.yml` | `check_suite` completed; or `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_EVIDENCE_VERIFY_ENABLED`, both branches (dispatch does not bypass here) | **Live** — `FACTORY_EVIDENCE_VERIFY_ENABLED` was set `true` 2026-08-04 (#1149); the lane shipped green with #1136/#1137 but sat 100% skipped for two weeks because nobody had run `gh variable set` yet. `config/github/repo-variables.json` now guards against a repeat: any workflow referencing an unset `vars.FACTORY_*_ENABLED` fails `scripts/tests/test_factory_workflows.py` in CI. |
| Review Response | `factory-review-response.yml` | `pull_request_review` submitted as `changes_requested` on a same-repository head; or owner `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_REVIEW_RESPONSE_ENABLED`, both branches (dispatch does not bypass here) | **Proposed** (PR #1383, #1378) — merged code, switch off. Set `FACTORY_REVIEW_RESPONSE_ENABLED=true` to arm it. Answers a blocking review with one gesture-named owner escalation; deterministic, no model. |
| Owner Comment Responder | `factory-comment-responder.yml` | `issue_comment` created by the owner; or owner `workflow_dispatch` | `AGENT_AUTOMATIONS_ENABLED` + `FACTORY_RESPONDER_ENABLED`, both branches (dispatch does not bypass here) | **Live** |
| Mention Triage → Executor | `agent-mention.yml` → `agent-executor.yml` | `@april-clearwater` / `@plat` / `@peter` / `@claude` mentions on issues/PRs/reviews | `AGENT_AUTOMATIONS_ENABLED`; execution additionally requires the `safe-to-run-agent` label, server-verified | **Live** — this is a distinct lane from the "Triage" pipeline Stage below; naming collision, not the same code path |
| Milestone Legibility | `milestone-legibility.yml` | daily cron (13:37 UTC); PR touching the check script; `workflow_dispatch` | none (no Factory switch — always runs) | **Live** |
| Evidence Reminder | `evidence-reminder.yml` | PR opened/edited/`ready_for_review` | none | **Live** — non-blocking: it only posts a reminder comment when evidence looks absent, it never fails the check. Not part of the Factory pipeline. |
| Triage / Spec (pipeline Stages) | none | — | — | **Aspirational.** `docs/agents/CONTEXT.md` names these as Factory Stages and assigns them to Peter, but no workflow triggers `run-planner.py` today. See "Peter planner: parked" below. |
| Carl Community | — | — | — | **Deleted this PR.** Daily cron that only 429s or no-ops; never posted once; not a v2-plan persona. |
| Codespaces Claude Worker | — | — | — | **Deleted this PR.** Manual break-glass dispatch; zero runs since it shipped. |
| App Review Smoke | — | — | — | **Deleted this PR.** Manual dispatch; dormant since 2026-05-26. |

`AGENT_AUTOMATIONS_ENABLED` is the global master switch, but it is not an unconditional kill for every lane: Implement, Evidence Verify, and the Owner Comment Responder `&&` it into every trigger path including `workflow_dispatch`, so it always gates them. Review (signal), Review (execute), and Monitor instead OR a bare `workflow_dispatch` check ahead of the switches — an owner-triggered manual dispatch runs those three regardless of `AGENT_AUTOMATIONS_ENABLED` or their own per-stage switch. Milestone Legibility and Evidence Reminder have no Factory switch at all. Treat "turn off `AGENT_AUTOMATIONS_ENABLED`" as "stops label/cron/comment-driven runs," not "nothing can run" — a manual dispatch on Review or Monitor still can.

## Admission: what the owner's release actually is

`factory-implement.py`'s claim step admits an issue only when the issue's own
timeline shows an owner-applied `ready`. Two details are easy to get wrong and
both cost live runs (#1380):

- **`rollback`'s restore is transparent — but only in the shape a real retry
  leaves behind.** `rollback` re-applies `ready` with April's App token, so the
  newest `ready` event on a retried issue is bot-attributed. Admission walks
  `ready` adds and removals newest-first and accepts exactly one sequence:
  owner release → the claim's own factory-attributed removal → rollback's
  factory-attributed restore. A factory `ready` with no claim removal under it
  is not a restore of anything and ends the walk, because the App token is held
  by several lanes and identity alone is not provenance. A removal by anyone
  else is a revocation and also ends the walk, so an owner who withdraws `ready`
  mid-claim cannot have that release replayed by the retry that follows. Before
  this, a single failed run locked the issue's front door until a human cycled
  the label by hand, and the documented `workflow_dispatch` recovery path failed
  on the same poisoned timeline.
- **The content-staleness boundary is the owner's release, not the restore.**
  What the owner reviewed is the issue as it stood when they released it, so a
  non-owner edit landing between the release and a retry still defers.
- **The janitor's stale-claim restore is still opaque.** When a rollback job is
  cancelled or never recognises the claim, the janitor flips `claimed` back to
  `ready` 24 hours later under `github-actions[bot]` — an identity shared by
  every workflow in the repo, so admission stops there and the issue still
  needs a human label cycle. Closing that needs one verifiable restore
  mechanism shared by rollback and the janitor, not a wider actor list;
  tracked in #1386.

Admission also requires a `## Requested Evidence` section with at least one
real item, read with the same `extract_requested_evidence` the contributor
runtime uses. Without it the runtime refuses to execute anyway
(`FACTORY_REQUIRE_EXPLICIT_EVIDENCE`), so catching it at the gate turns a
wasted claim-plus-model run into one API read and an explanatory comment.

## Peter planner: parked

`.agents/scripts/run-planner.py` (a compatibility shim over `.agents/skills/peter-planner/scripts/run-planner.py`) and the `peter-planner` skill were hardened twice (#1133, #1144), and their tests (`.agents/scripts/test_run_planner.py`) still run in `ci-agents.yml`. No workflow exists that invokes the runtime — `agent-peter.yml` was never re-created after the v1 retirement, so nothing calls it on any trigger. This PR leaves it in place rather than deleting it: wiring it up is Milestone M2 ("Front door" — Triage stage) of the v2 plan, and dropping the hardened runtime now would just mean rebuilding it later. Revisit at M2; drop it only if M2 is abandoned outright.

## Switch inventory

Live values as of 2026-08-04 (`gh variable list --repo fairchild/workspaces`):

| Variable | Value | Gates |
|---|---|---|
| `AGENT_AUTOMATIONS_ENABLED` | `true` | Global master for Implement, Evidence Verify, and Owner Comment Responder on every trigger path; for Review and Monitor it only gates the non-`workflow_dispatch` path (see lane table above) |
| `FACTORY_IMPLEMENT_ENABLED` | `true` | Implement lane |
| `FACTORY_IMPLEMENT_DAILY_CAP` | `6` | Implement lane — max owner-authorized `factory-implement.yml` runs per UTC day |
| `FACTORY_REVIEW_ENABLED` | `true` | Review (signal + execute) lanes |
| `FACTORY_REVIEW_DAILY_CAP` | `12` | Review (execute) lane — max executor attempts per UTC day, including reruns |
| `FACTORY_MONITOR_ENABLED` | `true` | Monitor lane |
| `FACTORY_RESPONDER_ENABLED` | `true` | Owner Comment Responder lane |
| `FACTORY_EVIDENCE_VERIFY_ENABLED` | `true` | Evidence Verify lane |
| `FACTORY_REVIEW_RESPONSE_ENABLED` | `false` (set 2026-08-27, after this table's 2026-08-04 snapshot) | Review Response lane — registered so the drift gate passes, but off; `gh variable set FACTORY_REVIEW_RESPONSE_ENABLED --body true` arms it |

`APPLE_ID`, `APPLE_TEAM_ID`, and `PREFERRED_RUNNER` also show up in `gh variable list` but are release/runner configuration, not Factory switches.

## Enable or disable a lane

```bash
# Turn a lane off without touching workflow YAML:
gh variable set FACTORY_IMPLEMENT_ENABLED --body false --repo fairchild/workspaces

# Turn it back on:
gh variable set FACTORY_IMPLEMENT_ENABLED --body true --repo fairchild/workspaces

# Stop label/cron/comment-driven runs across every lane (Milestone Legibility and
# Evidence Reminder are unaffected; owner workflow_dispatch on Review or Monitor
# still runs — see the bypass note under the lane table):
gh variable set AGENT_AUTOMATIONS_ENABLED --body false --repo fairchild/workspaces
```

A disabled lane's `if:` guard simply evaluates false — the job is skipped, not queued, so flipping the switch back on does not replay missed events. For Implement, Evidence Verify, and the Owner Comment Responder, `workflow_dispatch` still requires both switches to be `true` — there's no bypass. For Review (signal + execute) and Monitor, `workflow_dispatch` bypasses both switches entirely (boolean OR in the `if:`, not AND): an owner with dispatch access can run those three lanes even with `AGENT_AUTOMATIONS_ENABLED` off.

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

## `workspaces-factory` rollout (worker PR authorship, issue #1180)

**Problem.** All agent-authored PRs post from the shared owner account (`fairchild`), and GitHub blocks the owner from submitting an *approving review* on their own PR — the only formal-approval path is gone, forcing workarounds like an "I approve" comment + auto-merge (#1173) when the App reviewers' runtime crashed (#1179). This is a **separate mechanism** from the Factory Implement/Review lanes above, which already push as `april-clearwater[bot]`/`workspace-agents[bot]` via `actions/create-github-app-token` inside GitHub Actions — the owner-account problem is specific to CLI-dispatched implementation workers (local or cloud coding-agent sessions on any harness — Claude Code, codex, Cursor, Orca-managed terminals, etc.), which push and `gh pr create` using the operator's own ambient `gh` auth.

**Fix.** A single shared GitHub App identity, `workspaces-factory[bot]`, that an opted-in worker authors PRs as instead. Per-agent attribution stays on `author:<agent>` labels (§ "Author Labels" above) — this only changes the git/PR *authorship* identity, not who gets credited.

**What's shipped in this PR (machinery only — nothing flips by default):**

- `config/github/apps/workspaces-factory.manifest.json` — App manifest: `contents:write`, `pull_requests:write`, `issues:write`, `metadata:read`; no webhooks.
- `scripts/factory-worker-token.py` — mints a ~1-hour installation token from `FACTORY_WORKER_APP_ID` + `FACTORY_WORKER_APP_KEY` (PEM path). `--check` reports one of three states without minting anything: `not-configured` (env unset/unreadable), `configured-but-app-not-installed` (valid-looking credentials, no installation on this repo), `working`.
- `scripts/factory-worker-identity.sh` — `source` this in a worker session; when `FACTORY_WORKER_IDENTITY=app` it mints a token, exports `GH_TOKEN`, and points worktree-scoped (`git config --worktree`, isolated from every other linked worktree of this repo, never global) git commit identity + credential helper at `workspaces-factory[bot]`. **Unset (the default) or any other value: verified no-op** — no env mutation, no git config change. (Earlier revision used `--local`, which under this repo's standard multi-worktree topology targets the shared `$GIT_COMMON_DIR/config` — caught via collateral damage from a live worker run; fixed to `--worktree` + `extensions.worktreeConfig`, covered by a two-worktree isolation test.)
- `scripts/tests/test_factory_worker_token.py` — unit tests for JWT construction (RS256, `iss`/`iat`/`exp` claims, GitHub's 10-minute cap) against a throwaway RSA key generated at test time, plus the HTTP-status-to-state classifier, with no real App and no network calls.

**What this PR cannot test.** No App exists yet, so end-to-end minting (`working` state), a live `gh pr create` as the bot, and whether GitHub actually counts `fairchild`'s review as a formal approval on a bot-authored PR are all unverified. Evidence for this PR is the `not-configured` `--check` output, the unit test run, and the pre-flight audit below — not a live mint.

### Michael's two clicks

1. **Create the App** from the manifest: `https://github.com/settings/apps/new`, paste/upload `config/github/apps/workspaces-factory.manifest.json`'s contents as the `manifest` field (or use the `gh-apps` skill's `create` flow pointed at that file). Save the generated App ID and download the private key PEM.
2. **Install the App** on `fairchild/workspaces` (only that repo). Then make credentials reachable from worker environments as `FACTORY_WORKER_APP_ID` (the App ID) and `FACTORY_WORKER_APP_KEY` (a path to the PEM) — *how* those reach a CLI worker's environment is a follow-up decision, not resolved by this PR (parallel to how `EVIDENCE_UPLOAD_TOKEN` is sourced today, see root `AGENTS.md` § Evidence-Driven Development).

Verify with `uv run --script scripts/factory-worker-token.py --check` — `working` means both clicks landed correctly.

**The missing `workflows` permission is deliberate and permanent** (decided 2026-08-09, `docs/decisions/factory-harness-human-gate.md`). The manifest's permissions (`contents`, `pull_requests`, `issues`, `metadata`) don't include `workflows: write`, so GitHub rejects any push from this identity that touches `.github/workflows/*.yml`. A worker whose legitimate change touches CI config commits as the bot and pushes over owner credentials, which makes the PR owner-authored and forces a human approval — that is the intended control, not a gap to close. Do not add `workflows: write` to the manifest.

### Pre-flight audit (owner-authorship conditionals)

Before flipping anything on, PR #1180's implementation ran a repo-wide audit for logic keyed on the PR author being the owner (`author == fairchild`-shaped checks, `authorAssociation`, assignee assumptions) across `.github/workflows/`, `scripts/`, `web/`, `web-next/`, and `docs/`. Full hit-list (~39 reviewed) is in the PR body and the audit comment on issue #1180. Summary:

- **Fixed in this PR:** `scripts/factory-janitor.py`'s `TRUSTED_AUTOMATION_LOGINS` (used by `trusted_comment_author()`, since a bot's `authorAssociation` is never `OWNER`/`MEMBER`/`COLLABORATOR`) now includes `workspaces-factory[bot]` — otherwise an opted-in worker's own claim/state comments (posted with `GH_TOKEN` set for the whole session, not just PR creation) would stop being recognized as trusted. `docs/development/github-app-identities.md` and `docs/agents/triage-labels.md` updated to describe mixed authorship instead of a single shared account.
- **Flagged for Michael's judgment, not changed here:**
  - `config/github/rulesets/main-merge.json` currently sets `required_approving_review_count: 0` and `require_code_owner_review: false` — **no approving review is required to merge to `main` today**, so this fix's actual benefit (a formal approval GitHub will count) isn't enforced by branch protection yet. Whether to turn that on is a separate, more consequential decision than shipping the App plumbing.
  - `scripts/factory-evidence-verify.py`'s `FACTORY_LABEL_ACTORS` (derived from the CI-contributor `APP_BOT_GIT_IDENTITIES` table) doesn't include `workspaces-factory[bot]` either — low practical impact today since workers don't typically self-apply `blocked:evidence`, but worth a follow-up if that changes.
  - `scripts/ops-report.py`'s `select_approval_timestamp` matches comments authored by the repo owner for *discussion*-approval-lag metrics — likely unrelated to PR self-approval, but flagged since it's an owner-authorship comparison in the same theme.
  - `.github/workflows/factory-review-execute.yml` templates `"@${REPOSITORY_OWNER} mentioned you in PR #..."` into the reviewer prompt regardless of actual PR author — cosmetic, will read oddly on a `workspaces-factory[bot]`-authored PR, not a gate.
- **Confirmed unaffected (not exhaustive — see full list):** the Factory Implement/Review/Monitor/Responder lanes' `github.actor == github.repository_owner` checks gate who *triggered* automation, not PR authorship, and are a different lane entirely; `scripts/factory-review.py`'s self-review guard already compares against the reviewer-bot logins generically; `.github/CODEOWNERS` (`@fairchild`) does not need to change — it's the mechanism this fix unblocks, not something it invalidates; `web`/`web-next` owner-login references are dashboard sign-in allowlists, unrelated to CLI-worker git/PR authorship.

### Proof step before flipping any default

Per the accepted issue #1180 recommendation: land **one worker PR authored end-to-end via `workspaces-factory[bot]`** (`FACTORY_WORKER_IDENTITY=app` on a real dispatch of a CLI-based coding-agent worker) before `app` becomes the default for any worker. That PR should verify, and record in its own body:

1. PR author renders as `workspaces-factory[bot]`, not `fairchild`.
2. `fairchild` can submit a formal `APPROVED` review on it (not just a comment) — the actual property this issue is about.
3. CI triggered on the App-token push. GitHub App tokens do trigger workflows (unlike the default `GITHUB_TOKEN`), but that's unverified in this repo's specific workflow config until a real push proves it.

Only after that lands does defaulting `FACTORY_WORKER_IDENTITY=app` for worker dispatch become its own follow-up decision — not automatic, and not part of this PR.

## References

- `docs/development/agent-factory-v2-plan.md` — design record: why this pipeline, the decisions behind it, the milestone roadmap
- `docs/agents/CONTEXT.md` — Factory vocabulary (Stage, Gate, Persona, etc.)
- `docs/agents/triage-labels.md` — the `ready`/`claimed`/`review`/`mergeable` label state machine and `author:*` attribution labels
- `docs/development/evidence.md` — the evidence lane the Implement lane reuses as-is
- `docs/development/github-app-identities.md` — App identity table, mechanism, and verification checklist

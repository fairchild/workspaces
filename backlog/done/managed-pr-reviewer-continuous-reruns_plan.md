---
status: done
issue: 545
completed: 2026-05-25
resolution: promoted-to-github-issue
topic: pr-reviewer
priority: 1
description: Make the managed PR reviewer run again on meaningful PR updates while carrying forward prior review context and avoiding review loops.
---

# Managed PR Reviewer Continuous Reruns

## Problem Statement

The managed PR reviewer currently behaves like a one-shot opening review. That was enough for initial coverage, but PR #460 exposed a workflow gap: the bot requested changes for missing evidence, the author later added evidence and all checks passed, but the managed reviewer did not run again. The stale request-changes review had to be handled manually even though the new PR body and comments contained the information the reviewer asked for.

We need a continuous review model that reruns on meaningful PR updates and gives the reviewer its own previous output as context. This should let it approve or revise a stale evidence-only request after new commits, PR body edits, or evidence comments, without requiring a human to dismiss the stale review. The production reviewer should still use server-side trusted context assembly and must not load mutable skill instructions from the PR branch.

## Investigation Notes

- `web/src/app/api/webhooks/github/route.ts:149` triggers `triggerPrReview()` only for `pull_request.opened`.
- `web/docs/pr-reviewer.md:169` documents the same limitation and only sketches adding `reopened` or `synchronize`.
- `web/src/lib/agent-runtime/pr-review.ts:345` fetches recent issue comments for evidence context, but does not fetch prior managed reviews for the current PR.
- `web/src/lib/agent-runtime/pr-review.ts:249` only checks whether relationship-candidate PRs have been reviewed by the managed reviewer. It records a boolean, not the previous review body or decision.
- `web/src/lib/agent-runtime/pr-review.ts:494` injects previous PR narrative context and current PR comments into the kickoff message, but does not include same-PR review history, stale review state, dismissed review state, or commit-to-commit delta context.
- `web/src/lib/db.ts:75` has `managed_agents_cache` for agent/environment IDs, but no table that tracks reviewer runs, trigger fingerprints, session IDs, or last reviewed head SHA.
- In PR #460, an `@claude` comment fired `Agent: Mention Triage` but the workflow skipped, and a direct reviewer request to `workspaces-claude-pr-reviewer[bot]` left no pending reviewer. The managed reviewer does not currently expose a reliable manual rerun path.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Trigger scope | Rerun on `pull_request.opened`, `reopened`, `ready_for_review`, `synchronize`, PR body `edited`, and evidence-bearing PR comments | These events cover new code, changed evidence, and revived PRs without waiting for manual dismissal |
| Same-PR context | Fetch prior managed reviewer reviews for the current PR and include their state, commit SHA, submitted time, dismissal state, and a truncated body | The reviewer needs to know whether it is revisiting its own prior request, especially evidence-only blockers |
| Idempotency | Add durable reviewer-run fingerprints keyed by repo, PR number, head SHA, trigger kind, trigger source ID, and reviewer config hash | This prevents duplicate sessions from webhook retries and bot self-triggered events while still allowing same-head evidence reruns |
| Loop guards | Skip events from `workspaces-claude-pr-reviewer[bot]`, skip GitHub Actions bot evidence reminders unless author-supplied evidence changed, and skip PRs with an existing completed managed review for the same fingerprint | Continuous review must not create bot-review loops or cost spikes |
| Runtime boundary | Keep prompt/context assembly in `web/src/lib/agent-runtime/pr-review.ts`; do not load local skills into the managed-agent session | Prior reviewer work established server-side context as deterministic and safer than branch-local prompt loading |
| Manual path | Add a trusted operator rerun command or route after automatic reruns work | PR #460 showed we need an explicit fallback when event triggers do not cover a real-world case |

## Proposed Architecture

```text
GitHub webhook
  |
  v
web/src/app/api/webhooks/github/route.ts
  |
  +--> parsePrReviewTrigger(eventType, action, payload)
  |      - opened/reopened/ready_for_review
  |      - synchronize
  |      - edited body/title changes
  |      - issue_comment.created with evidence-like content
  |
  +--> shouldStartPrReview(trigger)
  |      - skip draft PRs
  |      - skip reviewer bot events
  |      - skip duplicate fingerprint
  |      - optionally debounce same-PR bursts
  |
  v
triggerPrReview(payload, triggerContext)
  |
  +--> fetchPrNarrativeContext()
  +--> fetchPrEvidenceContext()
  +--> fetchCurrentPrReviewHistory()
  +--> record reviewer run start
  |
  v
Managed Agent kickoff
  |
  +--> current PR body and comments
  +--> previous PR narrative context
  +--> same-PR managed review history
  +--> trigger reason and delta hint
```

## Implementation Phases

### Phase 1: Extract Trigger Parsing

**Files to modify:**
- `web/src/app/api/webhooks/github/route.ts` - replace the inline `pull_request.opened` condition with a small trigger parser and dispatcher.
- `web/src/app/api/webhooks/github/route.test.ts` - add trigger matrix coverage.
- `web/docs/pr-reviewer.md` - document continuous rerun behavior and loop guards.

**Trigger rules:**
- `pull_request.opened`: initial review.
- `pull_request.reopened`: rerun because old review state may be stale.
- `pull_request.ready_for_review`: run when a draft becomes reviewable.
- `pull_request.synchronize`: rerun when the head SHA changes.
- `pull_request.edited`: rerun when the PR body changes and the PR is not a draft.
- `issue_comment.created`: rerun only on PR comments by non-bot trusted users when the body contains evidence-like signals such as `evidence.cloudcompute.com`, `Evidence:`, `swift test`, `Playwright`, `screenshot`, `recording`, or `validation`.

**Acceptance criteria:**
- [ ] `triggerPrReview()` still runs for `pull_request.opened`.
- [ ] `triggerPrReview()` runs for `synchronize` with the new head SHA.
- [ ] A PR body edit reruns the reviewer when evidence links are added.
- [ ] A trusted evidence comment reruns the reviewer even when the head SHA is unchanged.
- [ ] Comments from `workspaces-claude-pr-reviewer[bot]`, `github-actions[bot]`, and other bots do not trigger a rerun.
- [ ] Draft PRs are skipped unless the action is `ready_for_review`.

### Phase 2: Add Durable Reviewer Run State

**Files to modify:**
- `web/src/lib/db.ts` - add a `managed_pr_review_runs` table type.
- `web/src/lib/agent-runtime/pr-review-runs.ts` - create a small helper for table creation, fingerprinting, start records, and completion/error updates.
- `web/src/lib/agent-runtime/pr-review.ts` - record session IDs and trigger metadata when a session starts.
- `web/src/lib/agent-runtime/__tests__/pr-review.test.ts` - cover run recording and duplicate handling.

**Table shape:**

```sql
CREATE TABLE IF NOT EXISTS managed_pr_review_runs (
  fingerprint TEXT PRIMARY KEY,
  repo TEXT NOT NULL,
  pr_number INTEGER NOT NULL,
  head_sha TEXT NOT NULL,
  trigger_kind TEXT NOT NULL,
  trigger_source_id TEXT NOT NULL,
  reviewer_config_hash TEXT NOT NULL,
  session_id TEXT,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  error TEXT
);
```

**Acceptance criteria:**
- [ ] Webhook retries do not start duplicate sessions for the same fingerprint.
- [ ] A same-head evidence comment can start a new review because its `trigger_source_id` differs from the prior run.
- [ ] A new head SHA starts a new review even when the trigger kind is still `synchronize`.
- [ ] Failed session creation records a failed run with enough error text for operator debugging.

### Phase 3: Fetch Same-PR Managed Review History

**Files to modify:**
- `web/src/lib/agent-runtime/pr-review.ts` - add `fetchCurrentPrReviewHistory()` and `formatCurrentPrReviewHistory()`.
- `web/src/lib/agent-runtime/__tests__/pr-review.test.ts` - cover prior request-changes, prior approval, dismissed review, and no-history cases.

**Context to fetch:**
- REST `GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`.
- Filter to `workspaces-claude-pr-reviewer[bot]`.
- Keep the newest 3 managed reviews.
- Include:
  - review state: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, or `DISMISSED`.
  - review commit SHA.
  - submitted timestamp.
  - body truncated to a safe size.
  - whether the review is on the current head SHA.
  - dismissal message when available from the API.

**Kickoff instruction changes:**
- Tell the reviewer when it is rerunning because evidence or code changed.
- Tell it to explicitly reconsider any prior `REQUEST_CHANGES` review in light of current PR body, comments, and head SHA.
- Tell it to approve if the prior blocker is now resolved and no new blockers exist.
- Tell it not to repeat a stale evidence request if current evidence satisfies the previously requested proof.

**Acceptance criteria:**
- [ ] Kickoff message contains `Current PR managed review history:` for reruns.
- [ ] Prior evidence-only request-changes reviews appear as untrusted context.
- [ ] The reviewer can distinguish stale old-head review state from current-head review state.
- [ ] Prompt tests assert that prior review content is treated as untrusted data, not instructions.

### Phase 4: Add Manual Rerun Support

**Files to modify:**
- `web/src/app/api/webhooks/github/route.ts` or a new internal route under `web/src/app/api/managed-agents/` - support a trusted rerun entry point.
- `web/docs/pr-reviewer.md` - document the operator command.
- Optional: `scripts/pr-reviewer-status.py` - add a `rerun` subcommand if it can authenticate safely.

**Options to evaluate:**
- A trusted PR comment command, for example `/pr-reviewer rerun`, accepted only from repository owners/collaborators.
- A protected internal HTTP route using existing app auth or a shared operator secret.
- A `workflow_dispatch` wrapper that calls the production route with a signed GitHub event-like payload.

**Acceptance criteria:**
- [ ] Maintainers can retrigger the managed reviewer for PR #460-style cases without manually dismissing reviews first.
- [ ] Untrusted PR comments cannot trigger privileged review compute.
- [ ] Manual reruns still use the same idempotency and loop-guard layer.

### Phase 5: Production Safety And Observability

**Files to modify:**
- `web/docs/pr-reviewer.md` - add troubleshooting for continuous reruns.
- `scripts/test_security_hardening.py` - add coverage if trigger expansion affects public-content event handling.
- `web/src/lib/agent-runtime/config.ts` - add optional `PR_REVIEWER_RERUNS_ENABLED` or similar rollout flag if needed.

**Safety controls:**
- Keep `PR_REVIEWER_ENABLED=1` as the primary gate.
- Consider `PR_REVIEWER_RERUNS_ENABLED=1` for staged rollout.
- Add event logs for skip reasons: draft, bot author, duplicate fingerprint, missing PR payload, unsupported action.
- Keep GitHub write credentials out of managed-agent resources.
- Continue to let the server-side broker validate final review intent before posting.

**Acceptance criteria:**
- [ ] Vercel logs show why a potential rerun was skipped or started.
- [ ] Duplicate webhook deliveries are visible but harmless.
- [ ] The reviewer cannot trigger itself through its own review or comment.
- [ ] Security hardening tests still pass.

## Verification Commands

```bash
# Web checks for implementation PR
mise -C web run web:check

# Security workflow checks if triggers or privileged events change
uv run --script scripts/test_security_hardening.py

# Targeted webhook route tests during development
cd web
pnpm vitest run src/app/api/webhooks/github/route.test.ts
pnpm vitest run src/lib/agent-runtime/__tests__/pr-review.test.ts

# Manual production observation after deploy
./scripts/pr-reviewer-status.py --errors
./scripts/pr-reviewer-status.py
```

## Rollback Plan

1. Disable continuous reruns with `PR_REVIEWER_RERUNS_ENABLED=0` if a rollout flag is added.
2. Revert the route trigger expansion while keeping same-PR review history formatting if it is useful for opened reviews.
3. Keep the durable run table in place; unused rows are harmless and can support a later retry.
4. If prior-review context makes the reviewer echo stale findings, remove only the same-PR review-history block from the kickoff message and keep the trigger/idempotency layer.

## References

- `web/src/app/api/webhooks/github/route.ts:149` - current one-shot `pull_request.opened` trigger.
- `web/docs/pr-reviewer.md:169` - current docs for manually changing the trigger.
- `web/src/lib/agent-runtime/pr-review.ts:345` - current evidence comment context.
- `web/src/lib/agent-runtime/pr-review.ts:494` - kickoff context assembly.
- `web/src/lib/db.ts:75` - current DB table registry with no reviewer run table.
- `backlog/pr-reviewer-narration-eval-skill_plan.md` - related eval skill plan; keep this runtime change separate from eval tooling.
- PR #460 - concrete incident: stale evidence-only request-changes review after evidence was added.

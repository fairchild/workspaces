# Managed Reviewer Understanding Guide

Use this guide when you need to explain or verify the current managed reviewer
system from behavior instead of table names. For the canonical component model,
state machine, and operator surfaces, keep
[`architecture.md`](architecture.md) as the source of truth. For operational
configuration and production runbooks, use [`pr-reviewer.md`](pr-reviewer.md).

The companion quiz is offline and deterministic:

```bash
uv run --script scripts/pr-reviewer-quiz.py
uv run --script scripts/pr-reviewer-quiz.py --check-answer-key
```

Run the quiz after reading this page, after changing managed-reviewer docs, or
when onboarding someone who needs the reviewer vocabulary before touching the
runtime.

## The Mental Model

The managed reviewer is a ReviewRun pipeline:

1. A material GitHub trigger creates or coalesces a ReviewRun.
2. The managed agent executes and returns a validated review intent.
3. The broker projects the completed ReviewRun to GitHub.
4. Health and dashboard surfaces explain the same run record.

Keep two lifecycle questions separate:

| Question | Field | Meaning |
|----------|-------|---------|
| Did the managed agent produce usable review intent? | `status` | `started`, `completed`, `failed`, or `superseded` |
| Did GitHub receive the review/status projection? | `projection_status` | `pending`, `projected`, `failed`, or `superseded` |

That split is the fastest way to avoid the wrong recovery action. Retry
execution only when there is no valid review intent and the run is still safe to
retry. Repair projection when the ReviewRun is already completed and the stored
intent only needs to be applied to GitHub.

## Scenario Walkthroughs

### 1. Pickup Is Visible Before A Review Exists

A PR opens and the `WorkSpaces Managed Review` status appears as pending on the
new head. That status means the webhook route accepted a material trigger,
created a ReviewRun, and published the first GitHub-facing indicator. It does
not mean the managed agent has finished or that the broker has posted a review.

If an operator sees no review yet, the first check is the ReviewRun report:
`uv run --script scripts/pr-reviewer-runs.py`. A healthy early row may be
`starting` or `running`. A problem row may be `missingRuns`, `stuckStarting`, or
`runningTooLong`.

### 2. Coalescing Prevents Parallel Reviews

A PR receives two pushes while the first review is still active. The system does
not start three independent agents for the same reviewer config. It records the
latest trigger and latest head on the active run's coalesced fields. The broker
then suppresses stale output and starts one follow-up run for the latest PR
state.

The key vocabulary is active coalescing: one active run, latest known head
recorded, older output retired, one follow-up review for the current state.

### 3. Stale Output Is Suppressed, Not Published Late

A managed-agent session may complete successfully for a head that is no longer
current. If a newer run or managed review covers the PR, the broker marks the
older run superseded. A superseded run is terminal and should not be retried.

This is intentional. The system prefers no review from an old head over a
confusing late review that appears authoritative on outdated code.

### 4. Failed Execution Means No Valid Intent Exists

An execution failure happens before usable review intent is stored: session
creation failed, session output could not be read, PR metadata was unavailable,
or the returned intent failed validation. The run records a failure kind,
retryability, and a sanitized message.

Safe retry is limited. Retry execution only when the failure is retryable and
the run still targets the current PR head. If the PR moved on, the safer action
is a fresh run for the current head, not reviving stale execution.

### 5. Failed Projection Means The Intent Already Exists

A completed run can still fail to update GitHub. For example, the broker may
store validated review intent but fail while posting the GitHub review or final
status. That is `status=completed` with `projection_status=failed`.

Do not rerun the managed agent in this case. Repair projection from the stored
ReviewRun intent. The repair sweep is designed for this path: re-apply missing
or failed GitHub effects without spending another agent run.

### 6. Health Output Has Two Lenses

The ReviewRun report is the source-of-truth health lens for pickup, execution,
coalescing, failure, supersession, and projection due rows. It uses buckets such
as `missingRuns`, `runningTooLong`, `completedAwaitingProjection`,
`failedExecution`, `projectionFailed`, `superseded`, and `published`.

The GitHub projection audit is a drift lens for open PRs: statuses, pending
timeouts, failures, and whether a current-head managed review exists. A green
projection audit is useful, but it does not prove ingestion, session execution,
or broker projection is healthy.

## Choosing The Next Action

| Observation | Interpret As | First Action |
|-------------|--------------|--------------|
| No ReviewRun row for an eligible trigger | Pickup or ingestion gap | Inspect ReviewRun report for `missingRuns`; then check ingress/trigger classification. |
| Pending status just appeared | Pickup succeeded; execution or projection may still be in progress | Wait inside SLO or open the details URL for run state. |
| Active run has coalesced fields | Newer material trigger arrived during execution | Let the broker suppress older output and create one follow-up run. |
| Completed run has failed projection | Valid intent exists, GitHub projection failed | Repair projection or let a repair sweep re-apply effects. |
| Failed run has retryable execution failure on current head | No valid intent exists, but retry is safe | Retry execution from the run details surface. |
| Failed run targets an older head | Retry would revive stale work | Start or wait for a current-head run instead. |
| Superseded run | Newer work intentionally replaced it | Do not retry; use the covering current-head run. |

## Boundaries To Preserve

- Do not include raw webhook payloads, secrets, tokens, or transcript dumps in
  learning materials.
- Do not teach production-only emergency steps as the default path.
- Do not collapse execution failure and projection failure into one "reviewer
  failed" bucket.
- Do not treat an old successful review as proof that the current PR head is
  covered.

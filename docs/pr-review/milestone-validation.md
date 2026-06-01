# Managed Reviewer Milestone Validation

Validation date: 2026-06-01 UTC.

This page records the current acceptance evidence for the managed reviewer
simplification milestone. It is intentionally about the current operating model:
`ReviewRun` is the source of truth, GitHub status and review are projections,
and the broker repairs projection from completed runs instead of rerunning the
agent.

## What Passed

| PR | Evidence | Result |
|----|----------|--------|
| [#600](https://github.com/fairchild/workspaces/pull/600) | Details URL: <https://spaces.cloudcompute.com/dashboard/review-runs/54800385ca110467006319c470dd742b> | Retry and repair controls landed after managed review approval; final `WorkSpaces Managed Review` status was `success`. |
| [#601](https://github.com/fairchild/workspaces/pull/601) | Details URL: <https://spaces.cloudcompute.com/dashboard/review-runs/39e5ca038dfcca55f58bfc2a4e1f22db> | Architecture docs landed after managed review approval; final status was `success`. |
| [#602](https://github.com/fairchild/workspaces/pull/602) | Details URL: <https://spaces.cloudcompute.com/dashboard/review-runs/93933483670bc23113ace2dc85b1c198> | Understanding guide and quiz landed after managed review approval; final status was `success`. |

The validation covered a successful managed-review path and a repairable
projection path: completed ReviewRuns were published by the broker from stored
run state, and the final status details URLs opened ReviewRun details instead
of looping back to the PR.

## Health Checks

The primary operator health command is:

```bash
uv run --script scripts/pr-reviewer-runs.py
```

It reads the protected production monitor and reports ReviewRun buckets such as
`missingRuns`, `stuckStarting`, `runningTooLong`,
`completedAwaitingProjection`, `failedExecution`, `projectionFailed`, and
`published`.

The GitHub projection audit remains separate:

```bash
uv run --script scripts/pr-review-health.py --repo fairchild/workspaces --updated-within-hours 72 --pending-timeout-min 30
```

Local projection-audit output during validation:

```text
Active PRs checked: 1
Active failures: 0
Skipped/unassessed PRs: 4
Queue coverage: incomplete (4 skipped/unassessed PRs)
```

The scheduled health workflow now mirrors the same split: one job checks
ReviewRun health through `scripts/pr-reviewer-runs.py`, and a separate job
audits GitHub projection drift through `scripts/pr-review-health.py`.

## Understanding Check

The offline answer-key check passed:

```bash
uv run --script scripts/pr-reviewer-quiz.py --check-answer-key
```

Expected output:

```text
answer-key check passed: 12/12 questions
```

A human maintainer should still run or review the quiz before closing the
milestone:

```bash
uv run --script scripts/pr-reviewer-quiz.py
```

If any question is confusing, fix the guide or quiz before treating the
milestone as complete.

## Remaining Posture

The system is simpler than the starting point because operators can answer the
important questions from one durable run model:

- Was the trigger picked up?
- Is an agent still running?
- Did execution fail before a valid intent existed?
- Did GitHub projection fail after the intent existed?
- Was older output superseded by newer PR state?
- Is the GitHub status/review merely drifting from the source-of-truth run?

Do not expand managed reviewer capabilities until this model stays stable under
normal PR traffic.

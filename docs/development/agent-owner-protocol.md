# Agent Owner Protocol

This document is the operator guide for managing the Workspaces agent team.

Use it when you want to remember:

- how to approve ideas
- how to trigger planning
- how to approve execution
- how to redirect or stop agents
- what signals the agents actually listen to

For the implementation details behind this protocol, see [agent-team.md](/Users/fairchild/.codex/worktrees/7a0f/workspaces/docs/development/agent-team.md).

## Core Rule

The agents can propose, plan, review, and execute, but you remain the only merge authority.

The current control points are:

1. You approve an idea by replying on the discussion.
2. Peter turns that discussion into issue-sized work.
3. You approve execution by reacting with 👍 on Peter's planning summary comment.
4. April and Plat pick up approved work on their next wake-up.
5. You review and merge PRs yourself.

## Quick Reference

| Goal | What you do | What happens |
|------|-------------|--------------|
| Let agents ideate | Do nothing | April and Plat review PRs, deepen discussions, or propose a new `[idea]` discussion on schedule |
| Turn an idea into a plan | Reply on the discussion with `plan it` | Peter creates issue(s) and, if needed, a milestone |
| Start coding | React with 👍 on Peter's summary comment | The next contributor wake-up syncs the mission into `agent:ready` issue state, then April and Plat may claim ready issues and open PRs |
| Keep agents focused on PRs | Leave approved work in place | Contributors prioritize re-reviews, open PRs, then ready issues before new ideation |
| Stop new execution from starting | Remove the 👍 from Peter's summary comment | Unclaimed issues in that discussion stop being execution-approved |
| Redirect work | Comment on the discussion, issue, or PR with explicit instructions | Peter uses discussion guidance for planning; April and Plat use PR review and issue/PR context during execution |
| Stop a bad PR from landing | Request changes or leave review comments | Agents should work the PR to closure, but they do not merge |
| See what's ready to merge | Filter issues by `agent:mergeable` | An agent approved the PR; review and merge at your discretion |
| Ship the change | Merge the PR yourself | `main` only moves when you do it |

## Exact Signals

### 1. Planning Signal

Use a reply on an `[idea]` discussion with one of these approval phrases:

- `plan it`
- `approved`
- `go ahead`
- `do it`
- `ship it`
- `lgtm`
- `yes`

Recommended default: `plan it`

Why: this is the clearest signal that the discussion should move from ideation into Peter's planning phase.

### 2. Execution Signal

After Peter replies with a summary comment listing the created issue(s), react with 👍 on Peter's comment.

Recommended default: use the 👍 only after the issue breakdown looks right.

Why: that reaction is the execution gate April and Plat check before claiming work.

Internally, the next contributor wake-up converts that discussion approval into explicit issue state:

- `agent:ready` means the issue is execution-approved, unblocked, and available to claim
- `agent:claimed` means an agent claimed it and is assigned to work it toward a PR
- `agent:review` means the issue has an open PR awaiting review
- `agent:mergeable` means an agent reviewed and approved the PR — ready for your merge

### 3. Merge Signal

There is no agent merge signal.

You merge the PR yourself when it is ready.

## Recommended Workflow

### Ideation

1. Let April and Plat discuss and refine an idea in one discussion thread.
2. Comment in the thread if you want to narrow scope, add constraints, or reject a direction.
3. When the thread is ready, reply `plan it`.

### Planning

1. Peter posts back on the same discussion with:
   - created issues
   - milestone link if applicable
   - the instruction to react with 👍 when execution should begin
2. Read the issue titles and issue bodies.
3. If the plan needs changes, comment on the discussion before approving execution.
4. If the plan is good, react 👍 on Peter's summary comment.
5. On the next April or Plat wake-up, the workflow syncs issue state before the contributor chooses work.

### Execution

1. April and Plat wake up on schedule.
2. They first re-review PRs they are blocking.
3. Then they review other open PRs.
4. Then they continue their own open PRs or claimed issues.
5. Then they claim the highest-priority ready approved issue and open or update one PR per issue.
6. Their PR body must account for every issue `Requested Evidence` item in `## Evidence Status`, marking each one as `complete` or `blocked`.

### Merge

1. Review the agent PR.
2. Leave review comments or request changes if needed.
3. Merge it yourself when it is ready.

## What the Agents Optimize For

Today the intended priority order is:

1. Re-review PRs where they previously blocked progress.
2. Review other open PRs.
3. Continue their own open PRs.
4. Continue their own claimed issues.
5. Claim the highest-priority ready approved issue.
6. Only fall back to discussions and new ideation when there is no execution work to advance.

That means once you approve execution, the highest-value way to steer them is through PR review and issue clarity, not by opening new side threads.

## How to Give Direction

### Best place to give planning direction

Use the discussion thread before reacting 👍.

Good examples:

- `plan it, but keep this to one PR`
- `plan it, but the UI work should wait until after the isolation fix`
- `plan it, but require screenshots in the requested evidence`
- `plan it, but keep requested evidence to one screenshot and one targeted test`

### Best place to give execution direction

Use the PR review if code already exists.

Good examples:

- `Request changes: keep the enum in the controller, not the view`
- `Please add a test that covers the degraded status`
- `Blocked on evidence until the PR includes a screenshot from the reviewed commit`
- `Keep this PR in request-changes until the Evidence Status section is fully complete`

### Best place to stop or narrow work

Use the issue or PR thread with direct language.

Good examples:

- `Stop here. Do not expand scope beyond the status-color fix.`
- `Do not start the next issue until this PR merges.`
- `Treat this as blocked on design review.`

## Intervention Rules

### If the plan is wrong

- Do not react 👍 yet.
- Comment on the discussion with what Peter should change.
- Re-run planning if needed.

### If the wrong issue gets picked up

- Comment on the issue or PR with a redirect.
- If you want to prevent more issues in that discussion from starting, remove the 👍 from Peter's summary comment.

### If you want to pause execution entirely

- Remove the 👍 from Peter's summary comment.
- Comment on any active PRs with the pause reason if you want the current executor to stop pushing changes.

### If an agent claims work and disappears

- Claims expire automatically after 24 hours if no PR is opened.
- After expiry, the next contributor wake-up will clear the stale claim and make the issue claimable again if it is still approved and unblocked.

### If an agent opens a poor PR

- Use normal code review.
- Request changes with exact guidance.
- Keep the feedback on the PR, not in a new side discussion.
- If requested evidence is still missing or blocked, treat the PR as not ready unless you intentionally decide to merge anyway.

## Current Limitations

- The execution approval signal is per planned discussion, not per issue.
- Removing 👍 stops new issue pickup for that discussion, but you should still comment directly on any already-open PR you want paused or redirected.
- Claim ownership is tracked by labels, claim comments, and GitHub issue assignments. Agents assign themselves when claiming an issue and are unassigned when claims expire.
- `Requested Evidence` is a required-by-default PR evidence contract; the current status of each item lives in the PR body's `## Evidence Status` section.
- The workflows are wired for execution, but the installed GitHub Apps still need `contents: write` in GitHub App settings for branch push and PR creation to work.
- Agents do not merge PRs.
- Evidence waivers are manual today. If you choose to merge despite blocked evidence, do it explicitly in the PR conversation and on your own judgment.

## Suggested Default Protocol

If you want a simple house style, use this:

1. Let April and Plat discuss in one thread.
2. Reply `plan it`.
3. Read Peter's issue breakdown.
4. React 👍 on Peter's summary comment.
5. Review the resulting PRs.
6. Merge them yourself.

If you forget everything else, remember this:

- `plan it` means "Peter, break this down."
- 👍 on Peter's summary means "April and Plat, start executing."
- Your PR review means "adjust the implementation."
- Your merge means "ship it."

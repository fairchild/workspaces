---
name: drive
description: >
  Execute GitHub milestones from this repo from planning through delivery.
  Use when the user wants to drive a milestone by number or relative target,
  for example `/drive m4`, `/drive to milestone 4`, `/drive next milestone`,
  or "deliver milestone 4". Always refresh the latest milestone, issue, PR,
  and workflow state from GitHub before planning, then work issues one at a
  time with issue updates, validation, PR management, review follow-up, and
  milestone retro notes.
---

# Drive

## Overview

Use this skill to turn an existing milestone into an execution loop. Start from live GitHub state, refresh or replace any stale plan, then deliver the milestone issue by issue.

## Quick Start

Resolve the target milestone first:

```bash
uv run --script .agents/skills/drive/scripts/milestone_status.py "/drive m4"
uv run --script .agents/skills/drive/scripts/milestone_status.py "/drive to milestone 4"
uv run --script .agents/skills/drive/scripts/milestone_status.py "/drive next milestone"
```

Read these repo sources before acting:

- `AGENTS.md` for project guardrails and validation expectations
- `docs/development/agent-team.md` for the planner/executor lifecycle
- `.agents/skills/peter-planner/references/peter-planner.md` if the existing milestone plan looks thin or stale
- `.agents/skills/gh-discuss/SKILL.md` when execution should also claim work or update GitHub Discussions
- `.agents/skills/tart-gui-automation/SKILL.md` when execution includes UI, terminal, runner, or other Tart-backed validation

## Workflow

### 1. Refresh live milestone context

- Use `milestone_status.py` to resolve the target and fetch the latest milestone description, issue list, and planner marker status.
- If the milestone work is represented in GitHub Discussions, check the `gh-discuss` dashboard and claim the relevant task before coding so parallel sessions do not duplicate work.
- Re-check GitHub directly for issue comments, open or merged PRs, workflow state, and any existing execution branches.
- Never trust an old copied plan or a stale milestone description without re-validating it against current GitHub state.

### 2. Plan before coding

- Every drive starts with a fresh execution plan in the conversation.
- If the milestone already has a good plan, audit it against the latest repo and GitHub state and reuse only what is still true.
- If reality drifted, rewrite the plan before touching code.
- Decide PR shape as part of the plan: one PR, one PR per issue, or a stacked series.
- If the work is performance-sensitive and no usable baseline metrics were supplied with the task, add an early baseline-capture step to the plan before making code changes. Use `./scripts/prepare-perf-evidence.sh --scenario <id>` and scenarios from `config/performance/contract.json`.

### 3. Execute issues one at a time

- Start with the highest-priority open issue or the next dependency in the plan.
- Rebase on the latest `origin/main` before starting the first issue and again before final PR updates if `main` moved materially.
- Update the issue when you start, when scope changes, when blocked, and when complete.
- Prefer issue-specific branches named `codex/milestone-<milestone>-issue-<issue>`. Reuse existing branches or PRs when they already exist.

### 4. Validate the actual landing point

- Run the smallest relevant local checks first.
- When workflows, CI, runners, or UI automation change, validate on the real lane for this repo, including Tart when applicable.
- Present evidence in issue and PR updates instead of only saying that something worked.
- For UI-affecting work, treat visual evidence as a delivery gate: attach proof from the exact commit under review to the PR itself before asking for review or calling it ready.
- Minimum UI evidence: at least one rendered screenshot or equivalent visual artifact, the exact verification commands used, and a linked log or artifact path. If the behavior is interactive, include a second screenshot or short recording.
- For performance-sensitive work, include the canonical `Scenario ID`, `Before Summary`, `After Summary`, and `Delta Summary` fields in the PR from the same or clearly described workload and environment, and note the delta instead of only reporting the final number.
- If baseline metrics were not provided up front, gather them before changing code whenever feasible so the final PR can compare the merged result against a real pre-change baseline.
- If the comparison is not like-for-like, say so explicitly. If a metric is missing, regresses meaningfully, or crosses a target boundary, call that out directly instead of burying it.
- If visual evidence cannot be produced, mark the work `blocked on evidence`, explain why in the PR and issue, and do not merge unless the user explicitly accepts shipping without that proof.

### 5. Manage PRs and review

- If issues are independent, prefer separate issue-sized PRs.
- If later issues build directly on earlier branches, use stacked PRs and say where each PR sits in the stack.
- If one consolidated PR is the better plan, explain that explicitly in issue updates and the PR summary.
- Before requesting review, confirm the PR description or comments include the required evidence links for any UI-affecting work.
- Before requesting review on performance-sensitive work, confirm the PR body satisfies the `performance-sensitive` gate and includes a short comparison note describing any meaningful change or explaining why the numbers are not directly comparable.
- Request review with stack context, then address review comments one by one through code changes, direct explanation, or a tracked backlog item.

### 6. Close out the milestone

- Make sure each issue has a completion note and the relevant PR link.
- Update the milestone with retro notes covering outcome, what went well, what was learned, and explicit follow-ups.
- If the milestone is truly complete, say so clearly in the final summary.

## PR Strategy Rules

- Default to issue-sized PRs when work is reviewable and independent.
- Use stacked PRs when the milestone has branch dependencies or runner-lane work that must land in sequence.
- Use one PR only when the plan says the work is tightly coupled enough that splitting would make review or validation worse.
- Re-evaluate the PR shape if the live GitHub state changes while you are working.

## Guardrails

- Always plan first. No `/drive` execution starts with coding.
- Always work from latest GitHub state, even if the milestone already contains a plan.
- Never assume issues are still open, PRs are absent, or runner state is unchanged.
- Never treat local-only screenshots or logs as sufficient PR evidence for UI-affecting work.
- Never treat a final perf number without a baseline or comparison note as sufficient performance evidence for performance-sensitive work.
- Keep milestone, issue, and PR comments aligned so another agent can resume without rediscovering the whole story.
- When execution uncovers work that should not block the milestone, capture it in `backlog/` rather than hiding it in a PR comment.

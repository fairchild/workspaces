---
name: peter-planner
description: >-
  Convert an approved GitHub Discussion idea into actionable GitHub Issues and,
  when needed, a milestone. Use when planning endorsed ideas, turning a
  discussion into issue-sized work, reconciling existing planner markers, or
  running the Peter Planner workflow manually or from automation.
---

# Peter Planner

Use this skill for the repo's discussion-to-issues planning loop.

## Resources

- Prompt: `references/peter-planner.md`
- Runtime: `scripts/run-planner.py`
- Validation helpers: `scripts/validate-agent-output.py`, `scripts/parse-frontmatter.py`
- Label catalog: `config/peter-planner.toml`

## What the runtime does

1. Resolve the target discussion from workflow dispatch or GitHub event payload.
2. Confirm the owner approval signal when running from `discussion_comment`.
3. Fetch the discussion, existing issues, labels, and milestones.
4. Run Claude Code with the Peter Planner prompt.
5. Validate and normalize the multi-document YAML plan.
6. Reconcile retries using planner markers, then create or reuse issues, milestones, and discussion comments.

## Usage

Manual dry run:

```bash
uv run .agents/skills/peter-planner/scripts/run-planner.py --discussion-number 44 --dry-run
```

Manual execution:

```bash
uv run .agents/skills/peter-planner/scripts/run-planner.py --discussion-number 44
```

## Guardrails

- Use only labels from `config/peter-planner.toml`.
- Keep issue scope to one focused session per issue.
- When 3+ issues are needed, derive the milestone name from the discussion title.
- Preserve planner markers so retries reuse existing artifacts instead of leaking duplicates.
- Treat `requested_evidence` as the required PR evidence contract for each issue, not optional guidance.

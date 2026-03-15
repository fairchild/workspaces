---
name: cofounder-contributor
description: >-
  Run the cofounder contributor workflow for this repo's standing personas.
  Use when you want April Clearwater or Plat Ironwood to sweep open PRs,
  discussions, and issues, then produce one structured action: proposal,
  discussion comment, PR review, or issue-advancing comment.
---

# Cofounder Contributor

Use this skill to run the shared contributor runtime with one of the repo's cofounder personas.

## Personas

- `references/april-clearwater.md` — application/UI/UX lead
- `references/plat-ironwood.md` — platform/CI/infra lead

## Runtime

- `scripts/run-contributor.py`
- `scripts/validate-agent-output.py`
- `scripts/parse-frontmatter.py`

## What the runtime does

1. Load the selected persona prompt.
2. Gather current repo and GitHub context.
3. Run Claude Code with the persona and appended context.
4. Validate the YAML frontmatter output.
5. Route the result back into GitHub as a proposal, discussion comment, PR review, or issue comment.

## Usage

April dry run:

```bash
uv run .agents/skills/cofounder-contributor/scripts/run-contributor.py \
  --prompt-file .agents/skills/cofounder-contributor/references/april-clearwater.md \
  --dry-run
```

Plat execution:

```bash
uv run .agents/skills/cofounder-contributor/scripts/run-contributor.py \
  --prompt-file .agents/skills/cofounder-contributor/references/plat-ironwood.md
```

## Guardrails

- Work through the persona priority order instead of freelancing.
- Produce exactly one action.
- Keep the final output valid YAML frontmatter with no preamble.
- Deduplicate new ideas before posting them.

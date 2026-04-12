# `cofounder-contributor`

Repo-local skill for running the shared contributor workflow with the Workspaces cofounder personas.

## Contents

- `SKILL.md` — trigger/usage instructions
- `scripts/run-contributor.py` — main contributor runtime
- `scripts/validate-agent-output.py` — structured output validation
- `scripts/parse-frontmatter.py` — lightweight YAML frontmatter parser
- `references/april-clearwater.md` — April persona prompt
- `references/plat-ironwood.md` — Plat persona prompt

## Notes

Existing automation may still call `.agents/scripts/run-contributor.py`; that path is retained as a compatibility shim.
The skill-local `references/` prompts are the source of truth for workflow/runtime use.

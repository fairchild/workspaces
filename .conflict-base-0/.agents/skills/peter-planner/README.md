# `peter-planner`

Repo-local skill for converting approved GitHub Discussions into actionable GitHub Issues and milestones.

## Contents

- `SKILL.md` — trigger/usage instructions
- `scripts/run-planner.py` — main planner runtime
- `scripts/validate-agent-output.py` — structured output validation
- `scripts/parse-frontmatter.py` — lightweight YAML frontmatter parser
- `references/peter-planner.md` — planner prompt
- `config/peter-planner.toml` — allowed labels and aliases

## Notes

Existing automation may still call `.agents/scripts/run-planner.py`; that path is retained as a compatibility shim.

# `.agents/scripts`

Compatibility entrypoints and tests for the agent automation flows in this repo. The skill directories under `.agents/skills/` are the source of truth for the actual runtimes.

## What’s here

- `run-planner.py` — compatibility shim that delegates to `.agents/skills/peter-planner/scripts/run-planner.py`. Kept because Peter is parked, not deleted — see `docs/development/factory-current-state.md`. The `run-contributor.py`, `validate-agent-output.py`, and `parse-frontmatter.py` shims were removed 2026-08 (no live workflow, test, or skill code called them; every current caller already used the skill paths directly — historical docs like `backlog/done/agent-peter-refactor-followup.md` still name the old shim paths as an archived record).

## Tests

- `test_parse_frontmatter.py` — stdlib tests for frontmatter parsing.
- `test_run_planner.py` — stdlib tests for planner/contributor helper behavior and output validation.

## Generated files

- `__pycache__/` — Python bytecode cache files generated locally; not hand-maintained.

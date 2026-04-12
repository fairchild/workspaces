# `.agents/scripts`

Compatibility entrypoints and tests for the agent automation flows in this repo. The skill directories under `.agents/skills/` are now the source of truth for the actual runtimes.

## What’s here

- `run-contributor.py` — compatibility shim that delegates to `.agents/skills/cofounder-contributor/scripts/run-contributor.py`.
- `run-planner.py` — compatibility shim that delegates to `.agents/skills/peter-planner/scripts/run-planner.py`.
- `validate-agent-output.py` — compatibility shim that delegates to the shared validator implementation in the contributor skill.
- `parse-frontmatter.py` — compatibility shim that delegates to the shared frontmatter parser implementation in the contributor skill.

## Tests

- `test_parse_frontmatter.py` — stdlib tests for frontmatter parsing.
- `test_run_planner.py` — stdlib tests for planner/contributor helper behavior and output validation.

## Generated files

- `__pycache__/` — Python bytecode cache files generated locally; not hand-maintained.

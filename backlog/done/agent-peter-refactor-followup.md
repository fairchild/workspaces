---
status: completed
category: followup
pr: 67
retro_summary: Peter now runs through `run-planner.py`, handles milestone reuse, and uses tempfile-backed orchestration instead of inline workflow bash.
completed: 2026-03-11
topic: agent-workflows
priority: 3
description: Refactor Peter Planner workflow to match April/Plat's clean Python wrapper pattern
---

# Agent Peter Workflow Refactor

## Implementation Status

This follow-up is complete and retained as a delivery record for the agent-team workflow evolution.

What landed:

- `agent-peter.yml` now delegates to `.agents/scripts/run-planner.py`
- planner validation and milestone handling are centralized in Python
- milestone reuse and tempfile-backed orchestration are in place

This file remains useful as historical context, but it is no longer active backlog work.

## Problem Statement

Peter Planner (`agent-peter.yml`) implements its entire orchestration inline in bash/YAML, while April and Plat delegate to `run-contributor.py`. This inconsistency makes Peter harder to test, maintain, and evolve. Several patterns are duplicated or divergent across the agent workflows.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Script pattern | Create `run-planner.py` following `run-contributor.py` | Consistency, testability |
| Dedup strategy | Use `--check-dedup` at validation time | Semantic title comparison > brittle string match |
| Issue creation | Extract to shared script | Reusable across future agents |
| Temp file handling | Python `tempfile` module | Guaranteed cleanup on failure |

## Implementation Phases

### Phase 1: Extract `run-planner.py`

Move Peter's inline bash logic into a Python script following `run-contributor.py`'s pattern.

**Files to create:**
- `.agents/scripts/run-planner.py` — wraps approval detection, discussion fetch, Claude invocation, validation, and issue creation

**Files to modify:**
- `.github/workflows/agent-peter.yml` — simplify to match april/plat pattern: checkout, setup-uv, `uv run .agents/scripts/run-planner.py`

**Acceptance criteria:**
- [ ] `agent-peter.yml` is as concise as `agent-april.yml`
- [ ] Manual dispatch with `discussion_number` still works
- [ ] Approval detection logic preserved (keyword matching, owner check)
- [ ] Dedup uses `--check-dedup` via `validate-agent-output.py`

### Phase 2: Harden issue creation

**Files to modify:**
- `.agents/scripts/run-planner.py` — handle milestone 422 (already exists) gracefully by looking up existing milestone
- `.agents/scripts/run-planner.py` — use `tempfile.NamedTemporaryFile` with `try/finally` cleanup

**Acceptance criteria:**
- [ ] Milestone creation handles "already exists" by finding and using the existing one
- [ ] No temp files left in `/tmp` on failure
- [ ] Error messages are actionable (include discussion number, step that failed)

## Current Architecture

```
agent-peter.yml (inline bash)
├── Detect approval (bash + python3 one-liner)
├── Acknowledge (uv run gh-discuss.py)
├── Fetch discussion (gh api graphql → /tmp/discussion.json)
├── Run Claude (npx --yes claude-code --print → /tmp/plan.txt)
├── Validate (uv run validate-agent-output.py)
└── Create issues (python3 heredoc with subprocess calls)
```

```
agent-april.yml (clean wrapper)
├── checkout + setup-uv
└── uv run run-contributor.py
    ├── gather_context()
    ├── invoke_claude()
    ├── validate_output()
    └── route_actions()
```

## Verification Commands

```bash
# Test manual dispatch
gh workflow run agent-peter.yml -f discussion_number=<NUM>

# Verify workflow syntax
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/agent-peter.yml'))"
```

## References

- `.agents/scripts/run-contributor.py` — pattern to follow (April/Plat wrapper)
- `.agents/scripts/validate-agent-output.py` — existing validation with `--check-dedup`
- `.agents/skills/gh-discuss/scripts/gh-discuss.py` — discussion posting helper
- `.agents/prompts/peter-planner.md` — Peter's system prompt
- PR #58 — version bump PR where this followup was identified

# backlog/

Deferred work items for future sessions. Each file represents work identified as valuable but out of scope for the current PR.

## Frontmatter Schema

Every backlog work-item file (all markdown files except `AGENTS.md`) should start with YAML frontmatter.

Use only fields that currently have real values. Do not add placeholder `null` fields. Add a field when you have a value for it.

```yaml
---
status: pending          # pending | in-progress | completed
category: plan           # plan | followup | task-list | ideas
---
```

Optional fields, only when populated:

```yaml
issue: 81                # GitHub issue number created from this doc
milestone: 1             # GitHub milestone number when this doc is promoted
discussion: 52           # GitHub discussion number, if planned from one
pr: 71                   # PR number that implements this
branch: codex/example    # branch name that implements this
score: 4                 # 0-5 effectiveness/efficiency rating
retro_summary: Shipped with smaller controller seams and no behavior regressions.
completed: 2026-03-12    # YYYY-MM-DD
```

## Categories

### plan
Comprehensive design documents for new features.

### followup
Post-merge improvements and tech debt.

### task-list
Collections of related items discovered during other work.

### ideas
Ideas to explore, not yet developed into actionable plans.

## Naming Convention

`{feature}-{category}.md`

## Lifecycle

1. **pending** - Created, waiting to be picked up
2. **in-progress** - Actively being worked or partially landed
3. **completed** - Move file to `backlog/done/`

## GitHub Linking

- When a backlog doc is promoted into execution, add `issue` and `milestone` only when those values exist.
- If a doc came from a GitHub Discussion, add `discussion` only when that value exists.
- Issue bodies should link back to the source backlog doc.
- Milestone descriptions should link to both the roadmap and the backlog source docs.
- If one backlog doc seeds multiple issues, keep the doc as the source of truth and add a short `## GitHub` section in the body listing the related issue numbers.

---
name: gh-discuss
description: >
  Coordinate multi-agent development via GitHub Discussions.
  Use when starting a session (discover tasks), claiming work,
  posting progress, requesting decisions, or completing tasks.
  Triggers on: "find work", "claim task", "post status",
  "ask decision", "coordination", "what should I work on".
---

# gh-discuss: Multi-Agent Coordination via GitHub Discussions

Agents coordinate through GitHub Discussions — a durable, web-visible layer that works across worktrees, sessions, and tools.

## Script Location

```bash
uv run .agents/skills/gh-discuss/scripts/gh-discuss.py <command>
```

## Quick Reference

| Action | Command |
|--------|---------|
| See current state | `gh-discuss.py dashboard` |
| Find available work | `gh-discuss.py list --unclaimed` |
| Create a task | `gh-discuss.py create "Title" --body "Details"` |
| Create from backlog | `gh-discuss.py create --from-backlog backlog/some-plan.md` |
| Claim a task | `gh-discuss.py claim <NUMBER>` |
| Post progress | `gh-discuss.py update <NUMBER> "Status message"` |
| Complete a task | `gh-discuss.py complete <NUMBER> --pr <PR>` |
| Abandon a task | `gh-discuss.py abandon <NUMBER>` |
| Ask a blocking question | `gh-discuss.py create --decision "Question?" --body "Options"` |
| Check pending decisions | `gh-discuss.py list --decisions` |
| Verify app credentials | `gh-discuss.py setup` |
| Live bot identity test | `gh-discuss.py verify` |
| Run unit tests | `test_gh_discuss.py` |
| Run all tests (+ live) | `test_gh_discuss.py --live` |

## Category Mapping

Uses existing default GitHub Discussion categories — no custom categories needed.

| Category | Purpose |
|----------|---------|
| **General** | Task discussions — agents discover, claim, and complete work |
| **Q&A** | Blocking decisions — marking an answer unblocks the agent |
| **Announcements** | Session summaries, protocol changes (human/lead only) |
| **Show and tell** | Completed work demos |

## Conventions

### Title Prefixes

All discussion titles use machine-parseable prefixes. These are the source of truth for task state — the script filters on them.

```
[task] Implement workspace creation progress UI
[task][claimed:el-paso-v1] Implement workspace creation progress UI
[decision] Pane tree: reducer vs direct state?
[shipped] Ghostty split actions working
```

### Agent Identity

Auto-detected from worktree directory name (e.g. `el-paso-v1`, `albany-v2`). Every comment includes a header:

```markdown
**Agent**: `el-paso-v1` | **Branch**: `feat/progress-ui`
```

## Workflow

### Session Start

1. Run `dashboard` to see open tasks, claimed work, and pending decisions
2. Run `list --unclaimed` to find available work
3. `claim` a task before starting work

### During Work

1. Post `update` comments at major milestones
2. If blocked, `create --decision` to ask for input
3. Check `list --decisions` for answers to previous questions

### Session End

1. `complete` finished tasks (link the PR)
2. `abandon` any tasks you can't finish (frees them for other agents)

### Race Conditions

After claiming, the script re-reads the discussion title to verify the claim stuck. If another agent overwrote it, the claim exits with an error.

## Backlog Integration

Discussions augment `backlog/*.md` files — they don't replace them.

- **Backlog file** = detailed design document (versioned in git)
- **Discussion** = work order for an active agent

Create a task from a backlog file:
```bash
gh-discuss.py create --from-backlog backlog/some-plan.md
```

This extracts the first `# heading` as the title and includes the file content in the discussion body.

## GitHub App (Optional)

Posts as a bot account instead of your personal account. See `references/github-app-setup.md` for setup instructions. Run `gh-discuss.py setup` to validate credentials.

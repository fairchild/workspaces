# Session Handoff

## Current Task
Cleaned up 10 stale git worktrees, then hardened the `wt.sh` git-worktree skill based on real friction encountered during cleanup.

## Progress
- Archived 7 merged worktrees via `wt archive`, removed 3 stale detached-HEAD worktrees from .cline/.codex/.claude
- Deleted 8 local branches and 1 remote branch
- Shipped 4 commits to dotclaude (all direct to main):
  - `wt clean` command with two-tier merge detection (git + gh squash-merge detection)
  - Slash-in-branch-name bug fix for `cmd_archive`
  - `--delete-branch` flag on archive
  - `wt list --all` showing worktrees from other tools
  - `wt done` shell function (archive + cd home from within a worktree) — PR #145
  - `wt prune` for deleting old archived worktrees
  - `wt clean --all-sources` for cross-tool worktree cleanup
- Pruned 23 archived worktrees, reclaimed 3.6GB
- Dead code removed (`carry_modified_files`), `wt install` implemented
- Tab completion updated for all new commands

## Key Decisions
- **`wt done` is a shell function, not a script command** — it needs to `cd` the parent shell after archiving, which a subprocess can't do. Same pattern as `wt cd` and `wt home`.
- **`wt clean --all-sources` uses `git worktree remove --force`** for external worktrees (not archive) since they aren't wt-managed and don't have the archive directory structure.
- **Two-tier merge detection** — `git merge-base --is-ancestor` for regular merges, `gh pr list --state merged` for squash merges. Falls back to tier 1 if `gh` unavailable.
- **Direct commits to dotclaude main** for small self-contained changes (prune, --all-sources). PR for larger features (wt done).

## Next Steps
1. The cairo-v3 worktree at `~/conductor/workspaces/workspaces/cairo-v3` is the only remaining worktree — check if `durable-workflows-skill` is still active
2. Consider adding `wt clean --all-sources` to a periodic maintenance workflow
3. The `wt apply` command may have the same slash-branch issues we fixed in archive — worth investigating

## Relevant Files
- `~/.claude/skills/git-worktree/scripts/wt.sh` — main script (all changes)
- `~/.claude/skills/git-worktree/scripts/wt.zsh` — shell functions (wt done, tab completion)
- `~/.claude/skills/git-worktree/SKILL.md` — documentation

## Open Questions
- Should `wt prune` be added to a session-end hook for automatic cleanup?
- Should `--delete-branch` be the default for `wt done` (since "done" implies finality)?

---
*Session completed on 2026-03-29*
*dotclaude commits: 4d7bae3, 238c49d (PR #145), b34adb4, a3f2a1e*

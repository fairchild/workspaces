---
status: pending
category: followup
pr: null
branch: null
---

# Consolidate prek.toml and .githooks/pre-commit

## Problem

Two hook systems define the same checks:

1. `prek.toml` — defines `swift-format` and `biome-web` hooks via prek framework
2. `.githooks/pre-commit` — standalone bash script referenced by `core.hooksPath`

Only `.githooks/pre-commit` actually runs because `core.hooksPath=.githooks` overrides prek's `.git/hooks/` installation. The biome-web hook in prek.toml was never executing.

## Options

### A: Remove prek, keep .githooks/ (simplest)
- Delete `prek.toml`
- `.githooks/pre-commit` already has both swift-format and biome
- No dependency on prek binary
- Downside: lose prek's file-type filtering and staged-only checking

### B: Switch to prek, remove .githooks/ 
- Remove `core.hooksPath` from git config
- Run `prek install` to install hooks into `.git/hooks/`
- Downside: every worktree needs `prek install` (not automatic)

### C: Keep .githooks/ but generate it from prek.toml
- Use prek as the source of truth but generate .githooks/pre-commit from it
- Best of both: prek's declarative config + worktree compatibility

## Recommendation

Option A unless prek's staged-file filtering proves important. The current `.githooks/pre-commit` runs `pnpm --dir web lint` on the full web/ directory (not just staged files), which is fast enough (~50ms).

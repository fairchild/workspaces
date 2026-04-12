# Phase 0 — Scope

Change-aware targeting. You spend ~60 seconds understanding what's changed on the branch so that Phase 1 probes the right surfaces instead of wandering.

## When to run

- Bare `/qa` or `/qa explore` (no area)
- `/qa <change summary>` — free-form caller hint
- On `main`: **skip**. No branch changes to target.

## Procedure

1. **Branch state**
   - `git branch --show-current`
   - `git log --oneline main..HEAD -- web/` (commit subjects → intent)
   - `git diff --stat main...HEAD -- web/` (file change counts)
   - `git diff --name-only main...HEAD -- web/` (bare file list)
   - `git status --short` (uncommitted changes — they count)
2. **PR context, if any**
   - `gh pr status --json number,title,body,labels,isDraft,headRefName 2>/dev/null`
   - If a PR exists: `gh pr view --json title,body,labels,reviews,comments`
   - `gh pr checks 2>/dev/null` — CI failures are P0 candidates
3. **Caller summary**
   - If provided, treat as authoritative intent. Quote verbatim.
   - If the diff and the summary conflict, the summary wins (the caller knows why; the diff doesn't). Note the discrepancy.
4. **Classify changed files → user surfaces**

   | Path pattern | Surface |
   |---|---|
   | `web/src/app/**/page.tsx`, `layout.tsx` | routes |
   | `web/src/app/dashboard/components/*-panel.tsx` | dashboard tabs |
   | `web/src/app/api/**/route.ts` | API endpoints (note HTTP method + path) |
   | `web/src/lib/agent-runtime/**` | agent chat backend (session lifecycle, provider) |
   | `web/src/lib/auth/**`, `web/middleware.ts` | auth flows |
   | `web/e2e/**` | test suite (**deleted tests = red flag**) |
   | `web/vitest.config.ts`, `web/playwright.config.ts`, `tsconfig.json` | test infra |
   | `web/package.json` | dependency changes (major bumps of Next/React/Playwright/Better Auth/libsql = risk) |
5. **Ledger cross-reference** — for each surface, read `web/tests/LEDGER.md`. Tag as `covered` / `stale (>30 days)` / `gap`. **Changed ∧ uncovered = highest priority.**
6. **Emit the Scope Report** (template below) before moving on.

## Scope Report template

```
## Phase 0 — Scope Report

**Branch**: <name> ({N} commits ahead of main{, M uncommitted})
**PR**: #<number> — <title> (<state>), or "no PR yet"
**Caller summary**: "<quoted verbatim>" or "not provided"

**Surfaces most likely affected** (ranked):
1. <surface> — <files>, <covered | stale | gap>
2. ...

**Exploration plan**:
- [P0] <surface> — why: <changed + uncovered, or changed + CI failure, or auth-adjacent>
- [P1] <surface> — why: <changed + has coverage but worth smoke>
- [skip] <surface> — why: <unchanged, covered, recently verified>

**Risk flags**:
- <dep bump, deleted test, middleware change, etc.>
```

## What NOT to do in Phase 0

- **Do not read diff content** of `web/src/**`. File names + commit subjects + PR body are enough. Reading the actual code is reserved for the caller who authorizes it or Phases 2/3 (Author/Heal).
- Do not rank surfaces by file-change size — one line in `middleware.ts` outranks 200 lines in a component.
- Do not silently ignore a caller summary when the diff looks different — quote both, note the discrepancy, ask if unsure.

## Shortcut

Use `scripts/scope-report.sh [caller-summary]` to run steps 1–3 as a single command. It emits a draft Scope Report that you then enrich with the surface classification and ledger cross-reference.

---
status: done
issue: 536
completed: 2026-05-25
resolution: promoted-to-github-issue
topic: web-dashboard-testing
priority: 2
description: Add a lightweight component-test harness for dashboard regressions like hook-order violations and stale repo-switch fetches.
---

# Web Dashboard Component Regression Tests

## Problem Statement

The recent `web/` simplify pass exposed two dashboard bugs that are hard to catch with the current test surface: a Rules-of-Hooks violation in `MainPanel` and stale async responses winning after repo switches in dashboard fetch effects. Both were fixed, but the current `web/vitest.config.ts` runs in `node` and the repo does not include a React DOM test harness, so those regressions are not covered by automated tests.

Pure module tests are already in place and stay fast, but they cannot exercise render transitions or effect cleanup behavior in client components. That leaves a gap specifically for dashboard lifecycle regressions.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Test harness | Add a minimal DOM-capable Vitest path for dashboard component tests | Needed to render React client components and assert effect cleanup/race handling |
| Scope | Cover only high-signal dashboard regressions first | Keep the added tooling small and focused |
| Initial targets | `MainPanel`, `DashboardShell`, `ActivityFeed` | These files already had real bugs or race-prone repo-scoped fetch behavior |

## Architecture

```text
Vitest
├── node environment
│   └── existing lib/unit tests
└── DOM-capable environment
    └── dashboard component regression tests
        ├── render transition tests
        ├── stale response / cancellation tests
        └── repo-switch behavior tests
```

## Implementation Phases

### Phase 1: Add the component-test lane

**Files to modify:**
- `web/vitest.config.ts` - support a DOM-capable test environment or split project config
- `web/package.json` - add the minimal test dependencies if needed

**Files to create:**
- `web/src/test/` helpers as needed for dashboard component rendering

**Acceptance criteria:**
- [ ] Dashboard component tests can run locally under `pnpm test`
- [ ] Existing node-only unit tests remain green and unchanged in behavior

### Phase 2: Cover the known regressions

**Files to create:**
- `web/src/app/dashboard/components/__tests__/main-panel.test.tsx` - verify render-state transitions do not violate hook ordering
- `web/src/app/dashboard/components/__tests__/dashboard-shell.test.tsx` - verify stale repo fetches do not overwrite newer selection
- `web/src/app/dashboard/components/__tests__/activity-feed.test.tsx` - verify cleanup prevents stale poll results from winning after filter changes

**Acceptance criteria:**
- [ ] A transition from loading/error/empty to loaded in `MainPanel` renders without hook-order errors
- [ ] Switching repos while a previous fetch is in flight preserves the newest repo data
- [ ] Changing `filterRepo` in `ActivityFeed` prevents old results from replacing newer state

## Verification Commands

```bash
cd web
pnpm test
mise run web:check
```

## Rollback Plan

Remove the DOM-specific Vitest setup and the new dashboard component tests, then revert to the existing node-only unit test configuration.

## References

- `web/vitest.config.ts`
- `web/src/app/dashboard/components/main-panel.tsx`
- `web/src/app/dashboard/components/dashboard-shell.tsx`
- `web/src/app/dashboard/components/activity-feed.tsx`
- `web/src/app/dashboard/components/sidebar.tsx`

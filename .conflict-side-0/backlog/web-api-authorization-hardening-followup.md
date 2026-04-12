---
topic: web
priority: 2
description: Add cross-tenant Playwright coverage for the read-API authorization checks landed in PR #342.
---

# Web API Authorization Hardening — E2E Regression Coverage

## Status

Phases 1–3 (the actual fixes) shipped in PR #342 (commit `16edcb0`):

- `/api/events`, `/api/events/[id]`, `/api/events/stats` now session-gated and scoped to the user's repos via `getEventsForRepos` / `getEventStatsForRepos`.
- `GET /api/chat/messages`, `/api/repos/*/agents`, `/api/repos/*/webhook-status` now enforce repo ownership via `authorizeRepoAccess` in `web/src/lib/api-auth.ts`.
- `/api/managed-agents/transcript` now authorizes via `getSessionByInstanceId` → session's `repo` → `authorizeRepoAccess`.

What remains is end-to-end regression coverage.

## Problem Statement

The vitest suite exercises the authz helpers in isolation but does not exercise the route wiring with two distinct authenticated sessions. A future refactor could drop an `authorizeRepoAccess` call site and still pass vitest + typecheck. A cross-tenant Playwright spec would catch that.

## Scope

One new Playwright spec: `web/e2e/api-authorization.spec.ts`.

For each of the 7 endpoints listed in Status, sign in as user A, request user B's repo (or user B's managed-agent session), assert 403. For the unauth case, hit `/api/events/*` without a session and assert 401.

## Implementation

**Files to create:**
- `web/e2e/api-authorization.spec.ts`

**Fixture shape:**
- Seed two users, each with a non-overlapping `user_repos` row, via the existing test DB setup (see `web/e2e/` for the auth-bypass pattern).
- Seed one `agent_sessions` row with `compute_instance_id` = `test-managed-session-1` owned by user A's repo.
- For each table row below, request as the "caller" session and assert the expected status.

| Endpoint | Caller | Target | Expected |
|----------|--------|--------|----------|
| `GET /api/events?repo=userB/repo` | user A | user B's repo | 403 |
| `GET /api/events/:id` where event.repo = user B's | user A | — | 403 |
| `GET /api/events` (no auth) | anon | — | 401 |
| `GET /api/events/stats` (no auth) | anon | — | 401 |
| `GET /api/chat/messages?repo=userB/repo` | user A | — | 403 |
| `GET /api/repos/userB/repo/agents` | user A | — | 403 |
| `GET /api/repos/userB/repo/webhook-status` | user A | — | 403 |
| `GET /api/managed-agents/transcript?sessionId=test-managed-session-1` | user B | — | 403 |

**Acceptance criteria:**
- [ ] Spec runs under `mise run web:e2e` and all 8 cases pass
- [ ] A deliberate revert of any `authorizeRepoAccess` call in the 7 routes causes at least one spec failure (manually verify once during authoring, then leave the tests pinned)

## Verification

```bash
cd web
mise run web:e2e -- api-authorization
```

## References

- `web/src/lib/api-auth.ts` — `authorizeRepoAccess`, `unauthorizedResponse`, `isRepoOwnedByUser`
- PR #342 for the route changes being covered
- `web/e2e/` for the existing Playwright auth-bypass pattern

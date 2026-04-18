---
topic: web
priority: 1
description: Close authorization gaps in /api/events, /api/chat/messages GET, /api/managed-agents/transcript, and repo-scoped GET routes that leak cross-tenant data.
---

# Web API Authorization Hardening

## Problem Statement

Several API routes in `web/` either skip authentication entirely or check a session but never verify that the authenticated user owns the resource they're querying. Any authenticated user can read activity, chat timelines, agent discovery, and managed-agent transcripts for arbitrary repositories and sessions — as long as they know (or can guess) the URL parameters. One route family is fully unauthenticated.

This was surfaced during the `/simplify web` pass that introduced `authorizeRepoAccess()` in `web/src/lib/api-auth.ts`. POST routes (`/api/chat/messages`, `/api/chat/dispatch`, `/api/chat/agent-stream`, `/api/terminal/*`) correctly gate on both session and repo ownership. The corresponding GET/read paths do not.

Impact is bounded by: (a) the current user pool is small and allowlisted via `ALLOWED_AGENT_LOGINS`; (b) no secret credentials are returned. But repo activity timelines, discussion-linked chat messages, agent tool_use inputs, and webhook payloads are not data we want any authenticated user to browse for any repo — and one endpoint (`/api/events`) is fully public.

## Scope

In-scope (all `web/src/app/api/`):

| Route | Current state | Required |
|-------|---------------|----------|
| `GET /api/events[?repo=X]` | **No auth at all** | Session + repo ownership when `?repo` set; session-only otherwise |
| `GET /api/events/[id]` | **No auth at all** | Session + repo ownership of the event's repo |
| `GET /api/events/stats` | **No auth at all** | Session-only (aggregate across user's repos only) |
| `GET /api/chat/messages?repo=X` | Session only | Session + `authorizeRepoAccess` |
| `GET /api/repos/[owner]/[repo]/agents` | Session only | Session + `authorizeRepoAccess` |
| `GET /api/repos/[owner]/[repo]/webhook-status` | Session only | Session + `authorizeRepoAccess` |
| `GET /api/managed-agents/transcript?sessionId=X` | Session only | Session + ownership of the `AgentSession` row |

Out-of-scope:
- Webhook intake routes (`/api/webhooks/github`, `/api/webhooks/[platform]`) — intentionally unauthenticated; they verify GitHub's HMAC signature.
- Better Auth handler (`/api/auth/[...all]`) — owned by Better Auth.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Reuse existing helper? | Yes — `authorizeRepoAccess` in `web/src/lib/api-auth.ts` already exists and is used by 7 POST routes | Consistent pattern; no new abstraction |
| How to authorize transcript? | Add `getSessionOwner(sessionId)` to `agent-sessions.ts`; check `session.userId === authedUserId` | Session rows are stored per-user in the sessions table; the mapping exists but isn't surfaced |
| What about `/api/events/stats`? | Scope stats to the user's repos instead of global | Currently `SELECT DISTINCT repo` reveals every repo any user ever webhooked into |
| `GET /api/events` with no `?repo`? | Return events only for repos the user owns | Matches the dashboard's actual use case (activity-feed filters client-side by repo) |
| Raise to 401 vs 403? | 401 for missing session, 403 for session-but-not-authorized | Matches the existing convention in `api-auth.ts` |

## Implementation Phases

### Phase 1: Repo-scoped GET routes (quick wins)

**Files to modify:**
- `web/src/app/api/chat/messages/route.ts` — add `authorizeRepoAccess(session.user.id, repo)` to GET handler after the `repo` query param is read (before `getMixedTimeline`)
- `web/src/app/api/repos/[owner]/[repo]/agents/route.ts` — add `authorizeRepoAccess(session.user.id, \`${owner}/${repo}\`)` after params are awaited
- `web/src/app/api/repos/[owner]/[repo]/webhook-status/route.ts` — same as above

**Acceptance criteria:**
- [ ] Each of the 3 routes returns 403 when an authenticated user requests a repo not in their `user_repos` row
- [ ] Existing POST/GET happy-paths still work (covered by Playwright `e2e/`)

### Phase 2: `/api/events/*` authentication

**Files to modify:**
- `web/src/app/api/events/route.ts` — add session check; if `?repo` is set, call `authorizeRepoAccess`; if no `?repo`, scope `getEvents(limit, repo)` to the union of repos the user owns (may need a new `getEventsForRepos(limit, repos: string[])` in `web/src/lib/events.ts`)
- `web/src/app/api/events/[id]/route.ts` — add session check; fetch event, then call `authorizeRepoAccess(userId, event.repo)` before returning the full payload
- `web/src/app/api/events/stats/route.ts` — add session check; scope `repos` count to `getUserRepos(userId)` so we don't leak other tenants' repo names

**Files to create:**
- Possibly `getEventsForRepos(limit: number, repos: string[]): Promise<WebhookEvent[]>` in `web/src/lib/events.ts` for the unfiltered `/api/events` call. Kysely `.where("repo", "in", repos)` + the existing `idx_webhook_events_repo_ts` index.

**Acceptance criteria:**
- [ ] All 3 events routes return 401 without a session
- [ ] Authenticated users see only events for repos in their `user_repos`
- [ ] `/api/events/stats` `repos` count matches the caller's `user_repos`, not the global distinct list

### Phase 3: Managed-agents transcript ownership

**Files to modify:**
- `web/src/lib/agent-sessions.ts` — add `getSessionOwner(sessionId: string): Promise<string | null>` returning `user_id` (the column exists; confirm via a read of the migration)
- `web/src/app/api/managed-agents/transcript/route.ts` — after the sessionId is extracted, call `getSessionOwner(sessionId)`; if null → 404; if owner !== session.user.id → 403

**Acceptance criteria:**
- [ ] User A cannot subscribe to User B's managed-agents session SSE stream
- [ ] Nonexistent sessionId returns 404 (not 403)

### Phase 4: Regression tests

**Files to create:**
- `web/e2e/api-authorization.spec.ts` — Playwright tests that authenticate as user A, attempt to hit each protected route with a repo/session owned by user B, assert 403

**Files to modify:**
- `web/src/app/api/__tests__/*` if any exist (check — may need new unit test directory)

**Acceptance criteria:**
- [ ] E2E suite exercises each of the 8 endpoints with cross-tenant request and asserts 403/404
- [ ] `mise run web:check` stays green
- [ ] `mise run web:e2e` passes

## Architecture

```
                        session required?   repo ownership required?
/api/events                    NO  →  YES            NO  →  YES (when ?repo= set)
/api/events/[id]               NO  →  YES            NO  →  YES (derived from event.repo)
/api/events/stats              NO  →  YES            (implicit scoping)
/api/chat/messages (GET)       YES                    NO  →  YES
/api/repos/*/agents            YES                    NO  →  YES
/api/repos/*/webhook-status    YES                    NO  →  YES
/api/managed-agents/transcript YES                    NO  →  YES (session owner match)

POST side (already correct):
/api/chat/messages POST        YES                    YES
/api/chat/dispatch             YES                    YES
/api/chat/agent-stream         YES                    YES
/api/terminal/{start,stop,     YES                    YES
               resume,status}
```

## Verification Commands

```bash
cd web

# Static verification
mise run web:check

# Runtime verification (E2E)
mise run web:e2e -- api-authorization

# Manual smoke (with DEV_BYPASS_AUTH off)
curl -i http://localhost:3000/api/events                      # expect 401
curl -i http://localhost:3000/api/events/some-id              # expect 401
curl -i -b "session=..." "http://localhost:3000/api/events?repo=other/repo"  # expect 403
```

## Rollback Plan

Each phase is an independent commit. If a change breaks a legitimate read (e.g., the dashboard's initial activity-feed load), revert that single commit. The `authorizeRepoAccess` helper is already battle-tested on the POST side, so behavioral risk is mostly in `/api/events/*` where we're tightening from "no auth" to "auth + repo scope" — the dashboard's activity-feed currently calls `/api/events?repo=X` with a repo from the user's own sidebar, so the new check will pass. The unfiltered `/api/events` call (when activity-feed has no `filterRepo` selected) needs the new `getEventsForRepos` helper to preserve the cross-repo view.

## References

- `web/src/lib/api-auth.ts` — existing `authorizeRepoAccess()` and `unauthorizedResponse()` helpers
- `web/src/lib/repos.ts:23-34` — `getUserRepos(userId)` returns the allowlist
- `web/src/lib/events.ts:75-98` — `getEvents(limit, repo?)` current signature
- `web/src/lib/agent-sessions.ts` — check schema for `user_id` column on `agent_sessions`
- `web/src/app/api/chat/dispatch/route.ts:40-41` — canonical POST-side pattern to follow
- `web/e2e/` — Playwright E2E harness for regression tests
- Surfaced by `/simplify web` reflection on branch `simplify-web` (April 2026)

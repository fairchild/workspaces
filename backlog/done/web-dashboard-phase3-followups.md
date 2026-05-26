---
status: done
issue: 537
children: [538, 539, 540, 541]
completed: 2026-05-25
resolution: promoted-to-github-issues
category: followup
pr: null
branch: null
---

# Web Dashboard Phase 3 Follow-ups

Deferred items from PR #188 review and Phase 2 implementation.

## Persistent Event Store
- In-memory event store works locally but events are lost across Vercel serverless invocations
- Turso is already wired for auth — add an `events` table for webhook events
- Replace `web/src/lib/events.ts` ring buffer with Turso reads/writes

## Responsive Layout
- Three-column layout hides sidebar (<640px) and activity feed (<960px) with `display: none`
- No escape hatch — add hamburger/drawer or tab bar for narrow viewports
- Primary audience is desktop but mobile should at least be usable

## Chat SDK Cleanup
- `chat` and `@chat-adapter/state-memory` dependencies add weight but aren't used in Phase 2
- The `[platform]` dynamic webhook route and `bot.ts` are scaffolding from Phase 1
- Evaluate whether to build on Chat SDK or remove it in favor of direct webhook handling

## Middleware Session Validation
- Middleware only checks cookie presence, not validity
- Expired tokens pass middleware, hit layout `getSession()`, then redirect — causes an extra page load cycle
- Investigate Better Auth middleware helpers or edge-compatible token verification

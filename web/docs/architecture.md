# Web Dashboard Architecture

## System Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Browser                                                             │
│                                                                      │
│  ┌───────────────┐  ┌──────────────┐                                 │
│  │  Dashboard    │  │  Chat Panel  │                                 │
│  │  (MainPanel)  │  │  (SSE stream │                                 │
│  │               │  │   to agents) │                                 │
│  │  Stats,       │  │              │                                 │
│  │  agents,      │  │  Compose bar │                                 │
│  │  pipeline     │  │  + @mentions │                                 │
│  └───────────────┘  └──────────────┘                                 │
└──────────┬──────────────────┬────────────────────────────────────────┘
           │                  │
           ▼                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Next.js API Routes (Vercel)                                        │
│                                                                     │
│  /api/chat/messages     — CRUD chat messages, trigger agent sessions│
│  /api/chat/agent-stream — SSE stream of agent output                │
│  /api/terminal/status   — list live sessions for the chat sub-tabs  │
│  /api/repos             — user repo management                      │
│  /api/events            — webhook event tracking                    │
│  /api/webhooks/*        — GitHub webhook ingestion (HMAC-verified)  │
└──────────┬──────────────────┬──────────────────┬────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────┐ ┌───────────────┐ ┌─────────────────────────────┐
│  LibSQL / Kysely │ │  GitHub API   │ │  Compute Provider Registry  │
│                  │ │               │ │                             │
│  - chat_messages │ │  - Agent      │ │  ┌─────────────────────┐    │
│  - agent_sessions│ │    discovery  │ │  │ Vercel Sandbox      │    │
│  - user_repos    │ │  - Discussions│ │  │ (Firecracker microVM)│   │
│  - webhook_events│ │  - Webhooks   │ │  └─────────────────────┘    │
│                  │ │               │ │  ┌─────────────────────┐    │
│                  │ │               │ │  │ Anthropic Managed   │    │
│                  │ │               │ │  │ Agents              │    │
│                  │ │               │ │  └─────────────────────┘    │
│                  │ │               │ │  ┌─────────────────────┐    │
│                  │ │               │ │  │ Daytona / GitHub    │    │
│                  │ │               │ │  │ Actions stubs / Mock│    │
│                  │ │               │ │  └─────────────────────┘    │
└──────────────────┘ └───────────────┘ └─────────────────────────────┘
```

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Framework | Next.js 15 (App Router) | SSR, API routes, deployment |
| Auth | Better Auth + GitHub OAuth | User authentication |
| Database | LibSQL + Kysely | Chat messages, sessions, repos, events |
| Styling | CSS Modules + CSS custom properties | Dark theme, no Tailwind |
| Agent runtime | Compute provider registry | Vercel Sandbox and Anthropic Managed Agents sessions |
| Linting | Biome | Format + lint |
| Unit tests | Vitest | Fast unit/integration tests |
| E2E tests | Playwright | Browser tests with video capture |
| Deployment | Vercel | Hosting, serverless functions |
| Infrastructure | Cloudflare Workers | Webhook relay, evidence store |

## Database & Schema

The schema is defined in one ordered migration list (`src/lib/schema/migrations.ts`)
and applied by `ensureSchema()` (`src/lib/schema/index.ts`), which every persistence
query awaits before touching the database. It runs at request time, once per warm
serverless instance, tracked via a `schema_migrations` table. The typed row shapes
live in the `Database` interface in `src/lib/db.ts`.

See [`schema-management.md`](./schema-management.md) for where each piece lives, how
to add a migration, and the design tradeoffs; the Kysely-vs-Drizzle decision is in
[`docs/decisions/web-schema-toolchain.md`](../../docs/decisions/web-schema-toolchain.md).

## Agent Runtime

The agent runtime executes Claude Code through the `ComputeProviderRegistry` at `src/lib/agent-runtime/provider-registry.ts`. The registry loads Vercel Sandbox, Daytona, GitHub Actions, and Anthropic Managed Agents providers by default; Daytona and GitHub Actions are registered stubs that currently report unavailable. `MOCK_AGENT=1` adds the test-only mock provider and makes it the default.

| Provider | Backend | Snapshot | Terminal |
|----------|---------|----------|----------|
| `vercel-sandbox` | Firecracker microVM | Yes (ephemeral) | Via ttyd + tmux |
| `managed-agents` | Anthropic Managed Agents | No | Transcript |
| `daytona` | VM stub | No | Transcript stub |
| `github-actions` | Runner stub | No | Transcript stub |
| `mock` | In-process test provider | Yes | PTY stub |

> Historical note: `cloudflare-sandbox` was scaffolded alongside the Vercel provider as a multi-provider proof-of-concept. The Worker and provider class were deleted in PR #321 because the scaffold had never been wired to a real Cloudflare account and was sitting in the runtime as ~500 lines of dead code. Design notes preserved in `backlog/done/cloudflare-sandbox-live-plan.md`.

### Session Lifecycle

```
User sends message
  → SessionManager.handleMention()
    → Check for active session (reuse sandbox)
    → Check for snapshotted session (restore from snapshot)
    → Create fresh session (new sandbox)
      → Clone repo, write system prompt + runner script
      → Stream output via SSE to browser
    → Snapshot and release (save state, stop sandbox)
```

Sessions persist across messages via snapshot/restore. The `agent_sessions` table tracks `userId`, `computeBackend`, `computeInstanceId`, `snapshotId`, and `claudeSessionId` per session.

## Terminal Removal

The dashboard's Terminal tab (a ghostty-web canvas attached to ttyd inside the
sandbox) was removed in #1858. Interactive terminals now live in the macOS app
and in `web-next/`. In `web/`, `/api/terminal/status` remains because the Chat
tab polls it to label agent sub-tabs with live and paused sessions. It never
returns a direct ttyd URL. The start, stop, resume, and ticket routes are gone,
so nothing in `web/` opens a ttyd WebSocket.

The provider layer still starts ttyd inside Vercel sandboxes (see
`src/lib/agent-runtime/vercel-sandbox.ts` and `docs/development/agent-chat-sandbox.md`);
the `terminal_access_tickets` table stays in the schema because migrations are
append-only.

## Authorization

Every API route that reads or mutates repo-scoped data passes through the two helpers in `src/lib/api-auth.ts`:

| Helper | Purpose | Returns |
|--------|---------|---------|
| `unauthorizedResponse()` | 401 for missing/expired session | `Response` |
| `authorizeRepoAccess(userId, repo)` | 403 if the user doesn't own the repo | `Response \| null` (null = allowed) |

The ownership check is backed by `isRepoOwnedByUser` in `src/lib/repos.ts`, which does a pinpoint `SELECT 1 FROM user_repos WHERE user_id=? AND owner=? AND repo=? LIMIT 1` — hits the table's primary key index, one row read per request.

Routes that accept a session or sandbox identifier instead of a repo (e.g. `/api/managed-agents/transcript?sessionId=`) resolve the identifier through `src/lib/agent-sessions.ts` with the authenticated `user_id`, then authorize against the resolved repo. `agent_sessions` stores `user_id`; terminal status and transcript lookups must include it so one user cannot attach to another user's live sandbox just because both can access the same repo.

Webhook intake routes (`/api/webhooks/*`) are intentionally unauthenticated and verify GitHub's HMAC signature instead. The Better Auth handler at `/api/auth/[...all]` owns its own auth flow.

## Dashboard Tabs

| Tab | Component | Shortcut | Purpose |
|-----|-----------|----------|---------|
| Dashboard | `MainPanel` | Cmd+1 | Stats, agents, issue pipeline |
| Chat | `ChatPanel` | Cmd+2 | Message timeline, @agent mentions, SSE streaming |

## Infrastructure

| Service | Location | Purpose |
|---------|----------|---------|
| Webhook relay | `infra/cloudflare-webhook-relay/` | GitHub webhook ingestion + WebSocket fan-out |
| Evidence store | `infra/cloudflare-evidence-store/` | R2-backed screenshot/artifact uploads for PRs |

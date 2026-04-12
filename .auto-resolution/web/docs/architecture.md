# Web Dashboard Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  Browser                                                            │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────────────┐ │
│  │  Dashboard    │  │  Chat Panel  │  │  Terminal Panel            │ │
│  │  (MainPanel)  │  │  (SSE stream │  │  (ghostty-web WASM)       │ │
│  │              │  │   to agents)  │  │                            │ │
│  │  Stats,      │  │              │  │  WSS → ttyd on sandbox     │ │
│  │  agents,     │  │  Compose bar │  │   (path is HMAC token,     │ │
│  │  pipeline    │  │  + @mentions  │  │    derived from sandboxId)│ │
│  └──────────────┘  └──────────────┘  └────────────────────────────┘ │
└──────────┬──────────────────┬──────────────────┬────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Next.js API Routes (Vercel)                                        │
│                                                                     │
│  /api/chat/messages     — CRUD chat messages, trigger agent sessions│
│  /api/chat/agent-stream — SSE stream of agent output                │
│  /api/terminal/status   — list live sessions + per-agent terminalUrl│
│  /api/terminal/start    — provision a new sandbox for an agent      │
│  /api/terminal/stop     — stop the sandbox for an agent             │
│  /api/terminal/resume   — restore a paused (snapshotted) session    │
│  /api/repos             — user repo management                      │
│  /api/events            — webhook event tracking                    │
└──────────┬──────────────────┬──────────────────┬────────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────┐ ┌───────────────┐ ┌─────────────────────────────┐
│  LibSQL / Kysely │ │  GitHub API   │ │  Compute Provider Registry  │
│                  │ │               │ │                             │
│  - chat_messages │ │  - Agent      │ │  ┌─────────────────────┐   │
│  - agent_sessions│ │    discovery  │ │  │ Vercel Sandbox      │   │
│  - user_repos    │ │  - Discussions│ │  │ (Firecracker microVM)│   │
│  - webhook_events│ │  - Webhooks   │ │  └─────────────────────┘   │
│                  │ │               │ │  ┌─────────────────────┐   │
│                  │ │               │ │  │ Cloudflare Sandbox  │   │
│                  │ │               │ │  │ (Container)         │   │
│                  │ │               │ │  └─────────────────────┘   │
│                  │ │               │ │  ┌─────────────────────┐   │
│                  │ │               │ │  │ Daytona / GitHub    │   │
│                  │ │               │ │  │ Actions / Mock      │   │
│                  │ │               │ │  └─────────────────────┘   │
└──────────────────┘ └───────────────┘ └─────────────────────────────┘
```

## Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Framework | Next.js 15 (App Router) | SSR, API routes, deployment |
| Auth | Better Auth + GitHub OAuth | User authentication |
| Database | LibSQL + Kysely | Chat messages, sessions, repos, events |
| Styling | CSS Modules + CSS custom properties | Dark theme, no Tailwind |
| Terminal | ghostty-web (WASM) | Browser terminal emulator |
| Agent runtime | Vercel Sandbox SDK | Sandboxed Claude Code sessions |
| Linting | Biome | Format + lint |
| Unit tests | Vitest | Fast unit/integration tests |
| E2E tests | Playwright | Browser tests with video capture |
| Deployment | Vercel | Hosting, serverless functions |
| Infrastructure | Cloudflare Workers | Webhook relay, evidence store, terminal proxy |

## Agent Runtime

The agent runtime executes Claude Code inside sandboxed environments. The `ComputeProviderRegistry` at `src/lib/agent-runtime/provider-registry.ts` supports multiple backends:

| Provider | Backend | Snapshot | Terminal |
|----------|---------|----------|----------|
| `vercel-sandbox` | Firecracker microVM | Yes (ephemeral) | Via ttyd + tmux |
| `daytona` | VM | No | — |
| `github-actions` | Runner | No | — |
| `mock` | In-process | Yes | — |

> Historical note: `cloudflare-sandbox` was scaffolded alongside the Vercel provider as a multi-provider proof-of-concept. The Worker and provider class were deleted in PR #321 because the scaffold had never been wired to a real Cloudflare account and was sitting in the runtime as ~500 lines of dead code. Design notes preserved in `backlog/cloudflare-sandbox-live-plan.md`.

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

Sessions persist across messages via snapshot/restore. The `agent_sessions` table tracks `computeBackend`, `computeInstanceId`, `snapshotId`, and `claudeSessionId` per session.

## Terminal Architecture

The Terminal tab provides shell access to active agent sandboxes.

### Direct connection

**ghostty-web** (WASM-compiled Ghostty) renders the terminal canvas. It connects via **WebSocket** directly to **ttyd** running inside the Vercel sandbox on port 7681. The WebSocket endpoint is path-protected: ttyd is started with `--base-path /<token>` where the token is `HMAC-SHA256(secret, sandboxId).hex.slice(0, 24)`. The status API derives the same token from the sandboxId, so the public sandbox URL alone (which can leak via screenshots, browser history, etc.) is not enough to connect — an attacker would need both the URL and the server-side secret.

The ttyd protocol itself uses the `tty` WebSocket subprotocol with binary frames: command-byte prefix (`0`=INPUT/OUTPUT, `1`=RESIZE) plus payload. Auth handshake on open is a JSON `{AuthToken: "", columns, rows}`.

ttyd's target command is `tmux new-session -A -s shell`, not bare bash — the `-A` flag attaches to an existing named session if one exists (so a tab reload reattaches to the same tmux state), otherwise creates a new one. See `docs/development/agent-chat-sandbox.md` § "Session Continuity via tmux".

```
Browser (ghostty-web canvas)
  │ WSS /<token>/ws
  ▼
Vercel Sandbox ttyd (port 7681)
  │
  ▼
tmux new-session -A -s shell
  │
  ▼
bash in /vercel/sandbox/repo
```

## Authorization

Every API route that reads or mutates repo-scoped data passes through the two helpers in `src/lib/api-auth.ts`:

| Helper | Purpose | Returns |
|--------|---------|---------|
| `unauthorizedResponse()` | 401 for missing/expired session | `Response` |
| `authorizeRepoAccess(userId, repo)` | 403 if the user doesn't own the repo | `Response \| null` (null = allowed) |

The ownership check is backed by `isRepoOwnedByUser` in `src/lib/repos.ts`, which does a pinpoint `SELECT 1 FROM user_repos WHERE user_id=? AND owner=? AND repo=? LIMIT 1` — hits the table's primary key index, one row read per request.

Routes that accept a session or sandbox identifier instead of a repo (e.g. `/api/managed-agents/transcript?sessionId=`) resolve the identifier to its repo via `getSessionByInstanceId` in `src/lib/agent-sessions.ts`, then authorize against that repo. `agent_sessions` has no `user_id` column by design — session ownership is derived from the repo so co-owners can see each other's agent activity on the same repo.

Webhook intake routes (`/api/webhooks/*`) are intentionally unauthenticated and verify GitHub's HMAC signature instead. The Better Auth handler at `/api/auth/[...all]` owns its own auth flow.

## Dashboard Tabs

| Tab | Component | Shortcut | Purpose |
|-----|-----------|----------|---------|
| Dashboard | `MainPanel` | Cmd+1 | Stats, agents, issue pipeline |
| Chat | `ChatPanel` | Cmd+2 | Message timeline, @agent mentions, SSE streaming |
| Terminal | `TerminalPanel` | Cmd+3 | Shell access to active sandbox |

## Infrastructure

| Service | Location | Purpose |
|---------|----------|---------|
| Webhook relay | `infra/cloudflare-webhook-relay/` | GitHub webhook ingestion + WebSocket fan-out |
| Evidence store | `infra/cloudflare-evidence-store/` | R2-backed screenshot/artifact uploads for PRs |

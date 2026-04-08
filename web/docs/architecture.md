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
| `vercel-sandbox` | Firecracker microVM | Yes (ephemeral) | Via ttyd relay |
| `cloudflare-sandbox` | Container | Yes (R2-backed) | Native PTY WebSocket |
| `daytona` | VM | No | — |
| `github-actions` | Runner | No | — |
| `mock` | In-process | Yes | — |

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

### Dual-mode connection

**ghostty-web** (WASM-compiled Ghostty) renders the terminal canvas. It connects via **WebSocket** to **ttyd** running inside the sandbox on port 7681. The WebSocket endpoint is path-protected: ttyd is started with `--base-path /<token>` where the token is `HMAC-SHA256(secret, sandboxId).hex.slice(0, 24)`. The status API derives the same token from the sandboxId, so the public sandbox URL alone (which can leak via screenshots, browser history, etc.) is not enough to connect — an attacker would need both the URL and the server-side secret.

The ttyd protocol itself uses the `tty` WebSocket subprotocol with binary frames: command-byte prefix (`0`=INPUT/OUTPUT, `1`=RESIZE) plus payload. Auth handshake on open is a JSON `{AuthToken: "", columns, rows}`.

### TerminalShare Proxy

`infra/terminalshare-proxy/` is a Cloudflare Worker + Durable Object that:

- Accepts WebSocket connections from the browser
- Proxies bidirectionally to the upstream sandbox PTY
- Maintains a 64KB ring buffer of recent output for reconnection replay
- Supports multiple browser clients on the same terminal session
- Abstracts away which sandbox provider backs the session

```
Browser (ghostty-web)
  │ WSS
  ▼
TerminalShare Proxy (Cloudflare Worker)
  │
  ├── Cloudflare Sandbox → sandbox.terminal() (native PTY)
  └── Vercel Sandbox → ttyd on published port (WebSocket PTY)
```

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
| Terminal proxy | `infra/terminalshare-proxy/` | WebSocket proxy for sandbox terminal sessions |

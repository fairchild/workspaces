---
priority: 1
relates_to: after:terminal-pty-relay-plan
description: Deploy TerminalShare Worker and wire Cloudflare Sandbox SDK for live terminal sessions
---

# Cloudflare Sandbox — Live Integration

## Problem Statement

PR #290 shipped the multi-provider terminal architecture with both Vercel (ttyd) and Cloudflare paths. The Cloudflare path is fully scaffolded — `CloudflareSandboxProvider`, TerminalShare Worker with Durable Object, session registration, WebSocket proxy — but the sandbox lifecycle routes return 501 placeholders. The Worker needs the Cloudflare Sandbox SDK (`@cloudflare/sandbox`) wired in to actually create containers, run commands, and expose native PTY terminals.

This is the highest-priority followup because Cloudflare's native terminal support (reconnection, output buffering, multi-client) is superior to the Vercel ttyd relay approach.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sandbox SDK binding | `@cloudflare/sandbox` via wrangler.toml | First-party SDK, Durable Object integration |
| Container base image | Custom Dockerfile with node22 + Claude Code CLI | Match Vercel snapshot contents |
| Terminal exposure | `sandbox.terminal(request)` in the DO | Native PTY, no ttyd needed |
| Agent runner | Same `run-agent.sh` pattern as Vercel | Reuse proven approach |
| Backup/restore | `createBackup()` / `restoreBackup()` to R2 | More durable than Vercel's expiring snapshots |
| DNS | `terminalshare.com` custom domain on Worker | Single endpoint for all terminal sessions |

## Implementation Phases

### Phase 1: Deploy Worker + wire Sandbox SDK

**Files to modify:**
- `infra/terminalshare-proxy/wrangler.toml` — add Sandbox binding, R2 bucket for backups, custom domain
- `infra/terminalshare-proxy/package.json` — add `@cloudflare/sandbox` dependency
- `infra/terminalshare-proxy/src/index.ts` — replace 501 placeholders with real Sandbox SDK calls

**Files to create:**
- `infra/terminalshare-proxy/Dockerfile` — base container image (node22 + claude CLI + ttyd fallback)
- `infra/terminalshare-proxy/src/sandbox-manager.ts` — Sandbox lifecycle (create, exec, stream, backup/restore)

**Acceptance criteria:**
- [ ] `wrangler deploy` succeeds
- [ ] `POST /sandbox/create` creates a real Cloudflare container
- [ ] `GET /sandbox/:id/stream` streams agent output via SSE
- [ ] `POST /sandbox/:id/snapshot` creates R2 backup
- [ ] `POST /sandbox/restore` restores from R2 backup

### Phase 2: Native terminal via sandbox.terminal()

**Files to modify:**
- `infra/terminalshare-proxy/src/session.ts` — for Cloudflare sessions, use `sandbox.terminal(request)` instead of upstream WebSocket proxy
- `infra/terminalshare-proxy/src/index.ts` — detect provider in WebSocket handler, route accordingly

**Acceptance criteria:**
- [ ] Browser connects to `wss://terminalshare.com/ws/:sessionId`
- [ ] Full interactive PTY works (tab completion, vim, top)
- [ ] Disconnecting and reconnecting replays buffered output
- [ ] Multiple browser tabs can connect to same session simultaneously

### Phase 3: End-to-end agent + terminal flow

**Files to modify:**
- `web/src/lib/agent-runtime/cloudflare-sandbox.ts` — point at deployed Worker URL
- `web/src/app/api/terminal/status/route.ts` — verify `terminalUrl` resolves correctly for live sessions

**Acceptance criteria:**
- [ ] Chat with @agent creates sandbox on Cloudflare
- [ ] Switch to Terminal tab → ghostty-web connects via WebSocket → live PTY
- [ ] Agent response streams in Chat tab while terminal is accessible
- [ ] Session persists across page reloads (backup/restore)

## Verification Commands

```bash
# Deploy Worker
cd infra/terminalshare-proxy && wrangler deploy

# Test health
curl https://terminalshare.com/health

# Test sandbox creation
curl -X POST https://terminalshare.com/sandbox/create \
  -H "Authorization: Bearer $PROXY_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"sessionId":"test","repo":"fairchild/workspaces","cloneUrl":"https://github.com/fairchild/workspaces.git"}'

# Test WebSocket terminal
node --experimental-websocket -e "
const ws = new WebSocket('wss://terminalshare.com/ws/test');
ws.onopen = () => console.log('CONNECTED');
ws.onmessage = (e) => process.stdout.write(e.data);
"

# Full E2E
CLOUDFLARE_SANDBOX_WORKER_URL=https://terminalshare.com mise run web:check
```

## Environment Setup Required

```bash
# Cloudflare account with Workers Paid plan ($5/month)
# Set in .env or wrangler.toml [vars]:
PROXY_SECRET=<generate with openssl rand -hex 32>

# In web app .env:
CLOUDFLARE_SANDBOX_WORKER_URL=https://terminalshare.com
CLOUDFLARE_SANDBOX_SECRET=<same as PROXY_SECRET>
```

## Rollback Plan

The Vercel path continues to work independently. If Cloudflare deployment fails, remove `CLOUDFLARE_SANDBOX_WORKER_URL` from the web app env and the registry falls back to Vercel automatically.

## References

- TerminalShare Worker scaffold: `infra/terminalshare-proxy/`
- CloudflareSandboxProvider: `web/src/lib/agent-runtime/cloudflare-sandbox.ts`
- Cloudflare Sandbox SDK docs: https://developers.cloudflare.com/sandbox/
- Cloudflare terminal API: https://developers.cloudflare.com/sandbox/api/terminal/
- Cloudflare sessions API: https://developers.cloudflare.com/sandbox/api/sessions/
- Cloudflare backup/restore: https://developers.cloudflare.com/sandbox/tutorials/persistent-storage/
- Verified locally: Worker health, session creation, WebSocket upgrade, auth — all working (PR #290 evidence)

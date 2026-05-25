---
status: done
issue: 529
completed: 2026-05-25
resolution: promoted-to-github-issue
priority: 2
description: Upgrade terminal tab from command-per-line SSE to Sandcastle-style PTY relay with persistent sessions and WebSocket reconnection
---

# Terminal PTY Relay Upgrade

## Problem Statement

The Terminal tab (shipped in `improve-webspace-chat`) uses a command-per-line model: each Enter keystroke POSTs to `/api/terminal/exec`, runs `bash -c <command>` in the sandbox, and streams output back via SSE. This works for basic inspection (ls, git status, cat) but lacks:

- **Session persistence on disconnect** — closing the tab loses all shell state
- **Interactive PTY features** — no tab completion, no Ctrl+R history search, no curses-based tools (vim, top, htop)
- **Continuous output** — can't stream from long-running processes between keystrokes
- **Working directory state** — tracked client-side with `cd` interception, fragile

The Sandcastle PoC (Vercel's own demo) solved this by running a **PTY relay service inside the sandbox** that exposes bash over WebSocket. The browser connects directly to the sandbox's published port, bypassing Vercel's serverless function limitations entirely.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| PTY relay binary | [ttyd](https://github.com/tsl0922/ttyd) | Single static binary, battle-tested, WebSocket protocol, supports reconnection. Alternative: custom relay like Sandcastle's, but ttyd is proven and zero-maintenance. |
| Terminal renderer | Keep xterm.js (already installed) | Sandcastle uses ghostty-web, but xterm.js is already integrated, widely used, and has the `attach` addon for WebSocket. Swap to ghostty-web later if desired. |
| Connection path | Browser connects directly to `sandbox.domain(port)` | Avoids Vercel serverless WebSocket limitation. The sandbox SDK's `domain(port)` returns a public `https://subdomain.vercel.run` URL. |
| Port number | 7681 (ttyd default) | Conventional, avoids conflicts with common dev server ports. |
| Reconnection | xterm-addon-attach + custom reconnect logic | ttyd serves a WebSocket endpoint; xterm attach addon pipes I/O. On disconnect, reconnect to same sandbox port — ttyd keeps the PTY alive. |
| Base snapshot | Install ttyd in the base snapshot | One-time cost. ttyd is ~3MB static binary. Add to `resolveBaseSnapshot()` alongside `claude` CLI install. |

## Architecture

```
Browser                    Vercel (serverless)              Sandbox (microVM)
+------------------+       +-------------------+            +-------------------+
| xterm.js         |       | /api/terminal/    |            | ttyd :7681        |
|  + attach addon  | <---> | status route      | <-- HTTP   |   \               |
|  + fit addon     |       | (sandbox lookup)  |            |    bash (PTY)     |
|                  |       +-------------------+            |                   |
|                  |                                        |                   |
|                  | <======= WSS (direct) ===============> | WebSocket server  |
|                  |   sandbox.domain(7681)                 |                   |
+------------------+                                        +-------------------+
```

Key insight: the WebSocket goes **directly** from browser to sandbox, not through the Next.js backend. The backend only provides the sandbox URL via the status API.

## Implementation Phases

### Phase 1: PTY relay in base snapshot

**Files to modify:**
- `src/lib/agent-runtime/vercel-sandbox.ts` — Add ttyd install to `resolveBaseSnapshot()`, add port 7681 to `Sandbox.create()` ports array, start ttyd in `createSandbox()`

**Acceptance criteria:**
- [ ] Base snapshot includes ttyd binary at `/usr/local/bin/ttyd`
- [ ] New sandboxes expose port 7681
- [ ] ttyd starts automatically as part of sandbox setup
- [ ] `sandbox.domain(7681)` returns a reachable URL

**Code sketch — snapshot setup:**
```typescript
// In resolveBaseSnapshot(), after npm install claude:
await sandbox.runCommand({
  cmd: "bash",
  args: ["-c", "curl -sL https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 -o /usr/local/bin/ttyd && chmod +x /usr/local/bin/ttyd"],
  sudo: true,
});
```

**Code sketch — sandbox creation:**
```typescript
const sandbox = await Sandbox.create({
  ...getCredentials(),
  source: { type: "snapshot", snapshotId: baseSnapshotId },
  ports: [7681],  // <-- expose ttyd port
  // ... rest of config
});

// Start ttyd in background after repo clone
await sandbox.runCommand({
  cmd: "ttyd",
  args: ["-W", "-p", "7681", "bash"],
  cwd: "/vercel/sandbox/repo",
  detached: true,
});
```

### Phase 2: Direct WebSocket terminal panel

**Files to modify:**
- `src/app/api/terminal/status/route.ts` — Return sandbox domain URL for port 7681 in addition to connection status
- `src/app/dashboard/components/terminal-panel.tsx` — Replace SSE command execution with WebSocket via xterm attach addon

**Files to create (maybe):**
- None — xterm-addon-attach may need to be installed: `pnpm add @xterm/addon-attach`

**Acceptance criteria:**
- [ ] Terminal tab connects via WebSocket directly to sandbox
- [ ] Full interactive PTY (tab completion, Ctrl+R, vim, top all work)
- [ ] Closing and reopening the Terminal tab reconnects to the same session
- [ ] Status bar shows connection state with reconnection attempts

**Code sketch — status route addition:**
```typescript
// In GET /api/terminal/status response:
return Response.json({
  connected: true,
  sandboxId: agentSession.computeInstanceId,
  agentName: agentSession.agentName,
  terminalUrl: `wss://${sandbox.domain(7681).replace('https://', '')}`,  // Direct WSS to sandbox
});
```

**Code sketch — terminal panel WebSocket:**
```typescript
import { AttachAddon } from "@xterm/addon-attach";

// Replace the SSE-based execCommand with:
const ws = new WebSocket(terminalUrl);
const attachAddon = new AttachAddon(ws);
term.loadAddon(attachAddon);

ws.onclose = () => {
  // Reconnect with backoff
  setTimeout(() => reconnect(), 1000);
};
```

### Phase 3: Reconnection and resilience

**Files to modify:**
- `src/app/dashboard/components/terminal-panel.tsx` — Add reconnection logic with exponential backoff, connection state UI

**Acceptance criteria:**
- [ ] Auto-reconnect on WebSocket close with exponential backoff (1s, 2s, 4s, max 30s)
- [ ] Terminal shows "Reconnecting..." overlay during reconnection
- [ ] Output history preserved on reconnect (ttyd handles this server-side)
- [ ] Clean disconnect when sandbox times out (show "Session ended" message)

### Phase 4: Cleanup

**Files to remove:**
- `src/app/api/terminal/exec/route.ts` — No longer needed (commands go over WebSocket)

**Files to modify:**
- `src/app/api/terminal/status/route.ts` — May simplify once exec route is gone

**Acceptance criteria:**
- [ ] No SSE-based command execution code remains
- [ ] Terminal works end-to-end with only WebSocket path

## Verification Commands

```bash
# After Phase 1 — verify ttyd is in snapshot and port is exposed:
# (from sandbox CLI or via runCommand)
sandbox exec <id> -- which ttyd
sandbox exec <id> -- curl -s http://localhost:7681

# After Phase 2 — verify WebSocket endpoint is reachable:
# (from browser console)
new WebSocket("wss://<sandbox-domain>")

# All phases — standard checks:
cd web && pnpm typecheck && pnpm lint && pnpm test
```

## Rollback Plan

The current command-per-line SSE implementation stays functional until Phase 4. Each phase is additive:
- Phase 1: Only changes sandbox setup, existing terminal still works
- Phase 2: New terminal code, but old API routes still exist
- Phase 3: Resilience layer, no breaking changes
- Phase 4: Remove old code only after new path is proven

If ttyd causes issues in the sandbox (resource usage, network policy conflicts), revert the snapshot setup and keep the SSE approach.

## Open Questions

- **ttyd vs custom relay**: ttyd is the simplest option. Sandcastle used a custom relay on port 14081. If ttyd doesn't meet needs (e.g., auth, multi-session), consider a minimal custom relay.
- **Network policy**: The current sandbox network policy restricts to `api.anthropic.com`, `github.com`, and `*.githubusercontent.com`. Port-published domains go through Vercel's proxy and may not be affected, but needs verification.
- **Sandbox timeout**: ttyd keeps bash alive, but the sandbox itself has a timeout (30min for full sessions). The Vercel CLI auto-extends in 5min increments — we may need similar logic via `sandbox.extendTimeout()`.
- **ghostty-web**: Sandcastle chose ghostty-web over xterm.js for better mobile support and reduced input lag. Consider swapping if terminal gets heavy use. See https://github.com/coder/ghostty-web.

## References

- Current implementation: `web/src/app/dashboard/components/terminal-panel.tsx`, `web/src/app/api/terminal/exec/route.ts`
- Sandbox creation: `web/src/lib/agent-runtime/vercel-sandbox.ts` (lines 98-122 for base snapshot, 154-258 for createSandbox)
- Sandbox SDK port publishing: `sandbox.domain(port)` returns `https://subdomain.vercel.run`
- Sandcastle architecture: https://maxleiter.com/blog/sandcastle — PTY relay on port 14081, ghostty-web frontend
- Sandcastle repo: https://github.com/vercel-labs/sandcastle
- ttyd (WebSocket PTY relay): https://github.com/tsl0922/ttyd
- Cloudflare Sandbox terminal (gold-standard reference): https://developers.cloudflare.com/sandbox/guides/browser-terminals/
- xterm-addon-attach: https://www.npmjs.com/package/@xterm/addon-attach
- ghostty-web: https://github.com/coder/ghostty-web

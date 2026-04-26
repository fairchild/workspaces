---
status: done
category: plan
resolution: scaffold-deleted
priority: 3
description: Design notes for a hypothetical Cloudflare Sandbox compute provider. Scaffold was deleted in PR #321; resurrect from git if we ever want a second provider.
---

# Cloudflare Sandbox Live Plan

> **Archived 2026-04-20.** Scaffold deleted in PR #321; no active path forward. Design notes preserved here as a reference for any future second-provider decision.

## Status

**Not implemented.** The scaffold (provider class, Worker, routes) was deleted in
PR #321 along with the rest of the `infra/terminalshare-proxy/` directory.
500 lines of dead code that nobody was going to get back to soon — the
multi-provider abstraction was validated, the routes were a useful design
exercise, but sitting in the runtime where future contributors trip over it
was worse than being gone.

If we ever want a second compute provider — Cloudflare Sandbox, Daytona,
Lume, GitHub Actions, whatever — resurrect the scaffolding from git history
(look up PR #321's revert) and finish the integration.

## Why Cloudflare Sandbox could be compelling

- Native PTY support via `sandbox.terminal(request)` (WebSocket) — no
  need to ship ttyd inside the sandbox
- Cheaper than Vercel Sandbox at scale
- Different failure mode — geographic diversity, different outage blast
  radius

## Rough original design

Compute provider (`CloudflareSandboxProvider`) that delegates sandbox
lifecycle to a Cloudflare Worker. The Worker uses the `@cloudflare/sandbox`
SDK internally; our Next.js backend calls the Worker's HTTP API.

```
Next.js API route
  → CloudflareSandboxProvider (web/src/lib/agent-runtime/cloudflare-sandbox.ts)
    → HTTP call to Cloudflare Worker
      → @cloudflare/sandbox SDK
        → actual sandbox with PTY
```

Terminal access: Worker exposes a WebSocket endpoint that pipes through
the sandbox's PTY. The web client's ghostty-web canvas connects to that
WebSocket directly (same shape as the ttyd WebSocket, different server).

## What was built before deletion

- `web/src/lib/agent-runtime/cloudflare-sandbox.ts` — provider class with
  placeholders that returned 501
- `infra/terminalshare-proxy/` — Worker scaffold (never deployed), with
  `src/index.ts` (HTTP router) and `src/session.ts` (Durable Object for
  session state)
- `wrangler.toml` configuration
- Type registration in `ComputeBackendId`
- Lazy import in `provider-registry.ts`
- Dynamic branch in `/api/terminal/status` to route to the Cloudflare
  `resolveSandboxState`

## What's missing to actually deploy

1. Wire `@cloudflare/sandbox` SDK into the Worker
2. Set up a Cloudflare account and bind secrets
3. Deploy via `wrangler deploy`
4. Implement real sandbox lifecycle in the Worker (create, stream, stop)
5. Wire the PTY WebSocket through to the client
6. Add a env var `CLOUDFLARE_SANDBOX_WORKER_URL` that makes the provider
   the default instead of Vercel
7. Smoke-test end-to-end with a real chat message and a real terminal

Estimated effort: ~2 days of focused work if the Cloudflare SDK behaves.

## Why defer

- Vercel Sandbox works. We just got tmux working on it. Agent chat is
  verified. Terminal tab is verified.
- Running a second provider adds operational surface (two deploy
  pipelines, two billing relationships, two failure modes to understand)
  for a capability the project doesn't need yet.
- The multi-provider abstraction is intact in the types and registry; if
  we need to add ANY other provider later (Daytona, Lume, GitHub Actions
  runner), we can do it without first un-deleting Cloudflare.

Resurrect this plan when one of:

- Vercel Sandbox has a material cost/reliability problem that a second
  provider would mitigate
- We want geographic distribution for lower-latency terminals
- Cloudflare ships a Sandbox pricing tier that's meaningfully cheaper

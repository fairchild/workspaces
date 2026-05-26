---
status: done
issue: 520
children: [521, 522, 523, 524, 525, 526, 527]
completed: 2026-05-25
resolution: promoted-to-github-issues
priority: 2
description: Larger terminal architecture items that need design discussion before implementation. Small polish items live in terminal-polish-followup.md.
---

# Terminal Architecture Follow-Ups

These are the items that don't fit in a single mechanical PR — each
has design tradeoffs worth thinking about before writing code. For
small UX polish items, see `terminal-polish-followup.md`.

## 1. Reconciliation cost: Sandbox.get per session per poll

`/api/terminal/status` does
`Promise.all(sessions.map(resolveSandboxState))`. With N agents per
repo, that's N HTTP calls to Vercel every 10s per active user.
Wasteful and adds latency to every status poll (~200ms for the
slowest call).

**Options**:

- **Cache server-side**: in-memory cache of sandbox state with 5s
  TTL. Survives across requests within the same warm function
  instance. Reduces Vercel API call volume by ~50% in practice.
- **Trust the DB more**: status route reads only from the DB. Add a
  background reconciliation job (cron) that runs every 60s and marks
  dead sandboxes completed. Status is up to 60s stale.
- **Decentralized**: status route trusts DB. The terminal panel's
  ghostty-web WebSocket reports back to a `/api/terminal/dead`
  endpoint when the WS fails to open or returns a known-dead error,
  which marks the session completed.

The decentralized option is the cleanest but requires the most
plumbing. The cache option is the smallest change for a big win.
Worth picking *one* and committing.

## 2. Delete or commit-to-deploy the Cloudflare provider scaffold

`infra/terminalshare-proxy/` and
`web/src/lib/agent-runtime/cloudflare-sandbox.ts` exist as ~500 lines
of unused code. The Worker isn't deployed and the provider returns
501 placeholders. The provider-registry has dynamic import paths for
it that never resolve to anything useful.

It's been valuable as scaffolding (validates the multi-provider
abstraction, the routes were a useful design exercise), but it's now
sitting in the runtime where future contributors will trip over it.

**Two paths**:

- **Deploy it**: wire `@cloudflare/sandbox` SDK into the Worker, set
  up a Cloudflare account, deploy. ~2 days of work. We get a real
  multi-provider system.
- **Delete it**: remove the provider, the routes, the Worker
  scaffold. Move the design notes to
  `backlog/cloudflare-sandbox-live-plan.md`. ~1 hour of work.
  Surface area drops by 500 lines.

Neither is wrong. Sitting in the middle is the worst place.

## 3. + button: agent picker

The `+` button in the sub-tab strip currently always calls
`startTerminal()` with no agent name, which uses
`DEFAULT_AGENT ?? "shell"`. If you already have a shell terminal
running, the start route returns the existing session (no-op
visually). The user has no way to start a terminal for a *different*
named agent from the UI.

**Fix**: open a picker on click:

- `[default shell]` (default agent or "shell" slot)
- `[pick agent]` → submenu populated from `availableAgents` prop
- `[ad-hoc shell with custom name]` → text input

Today users can only get to a named-agent terminal by sending a chat
message to that agent first. The terminal tab should be a first-class
entry point.

**Why architectural**: needs a popover/menu component, agent
discovery wiring, and decisions about how custom-named ad-hoc shells
interact with the agent_name column refactor below.

## 4. agent_name column refactor

`agent_name` in `agent_sessions` means three different things:

- Real persona slug (`april-clearwater`)
- Synthetic shell slot (`shell`)
- Whatever string the start route receives

This caused two bugs we already fixed (the `terminal` → `shell`
migration and the duplicate sub-tab issue) and will cause more.
Cleaner model:

```sql
ALTER TABLE agent_sessions
  ADD COLUMN session_kind TEXT NOT NULL DEFAULT 'agent';
-- 'agent' or 'shell'
-- For 'agent', agent_name is the persona slug
-- For 'shell', agent_name is a user-provided label or 'shell' default
```

Not urgent but worth doing before adding more session kinds (see + button
picker above which would benefit from this).

## 5. Cost awareness UI

Each running sandbox is ~$0.10/hr on Vercel. A user with 5 active
sandboxes for 8 hours/day spends ~$120/month without realizing.

Need:

- Header indicator: "● 3 active sandboxes" with a dropdown showing
  each one and an estimated cost
- A small affordance to stop all of them at once
- Optionally: hourly burn rate projection in the dropdown

**Why architectural**: requires aggregating across all repos for the
current user, adding a route for cross-repo session listing, and
deciding where the indicator lives in the global header.

## 6. Idle timeout / auto-stop / auto-snapshot

Standalone terminal sandboxes get the 30min default. User opens,
walks away, comes back to "no active terminal". Should:

- Show countdown when terminal is idle ("idle for 25m, will stop in
  5m unless used")
- Auto-snapshot before timeout so user can resume
- Configurable max idle minutes per sandbox

**Why architectural**: needs a server-side scheduler (cron or
Durable Object) to enforce timeouts, and decisions about how
auto-snapshot interacts with the existing snapshot/restore flow.
Pairs naturally with the cost awareness item — both are about not
silently burning money.

## 7. Shared filesystem volume across agents

By design, each sandbox has its own `/vercel/sandbox`. User clones a
branch in @april's terminal, switches to @plat's, the file isn't
there.

The polish-backlog version of this is "just add a UI hint." The
architectural version is to mount a shared `/workspace/shared`
volume that all agents see — Cloudflare R2 bucket via mountBucket,
or a Vercel-provided shared volume if/when that ships.

Pairs with the Cloudflare scaffold decision (item 2) — if we go
multi-provider, we want a portable shared-volume abstraction.

## References

- Reflection threads that surfaced these: see post-#299 / post-#302
  / post-#305 reflect outputs in session history
- Polish-scoped items: `backlog/terminal-polish-followup.md`
- Architecture overview: `web/docs/architecture.md`
- Cloudflare deploy plan: `backlog/cloudflare-sandbox-live-plan.md`

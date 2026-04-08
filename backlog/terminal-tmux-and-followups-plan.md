---
priority: 2
description: Larger architectural changes for the terminal — tmux for true session continuity, reconciliation cost fix, Cloudflare scaffold cleanup, claude CLI auth in sandboxes
---

# Terminal: tmux + larger followups

After PR #299 (resize fix + polish) and the security/correctness PR
addressing the small fixes, these are the architectural changes that
remain. They're each big enough to warrant their own PR and design
review rather than being slipped in.

## 1. Run tmux inside the sandbox

**Why**: The current Resume model restores the Vercel sandbox snapshot
(filesystem state) but the bash *process* is fresh. Users see the
disk state come back but their `cd somewhere`, `export VAR=...`,
command history, and any in-flight processes are gone. This
contradicts the intuition of "Resume".

A tmux server inside the sandbox solves this:

- Process state survives reconnect and snapshot/restore
- Multi-client (multiple browsers can attach to the same session)
- Splits/panes if we want them later
- Standard tmux UX users may already know

**Cost**: install tmux in the v3 base snapshot, change ttyd's command
from `bash` to `tmux new -A -s shell`, accept the slightly different
terminal model.

**Plan**:
1. Bump `BASE_SNAPSHOT_VERSION` to `v3-tmux`
2. Add tmux install to `resolveBaseSnapshot()` after the ttyd install
3. Change ttyd command in `createTerminalSandbox()` and
   `restoreSnapshot()` from `bash` to `tmux new-session -A -s shell`
   - `-A` attaches to existing session if present, creates if not
   - `-s shell` names the session for explicit re-attach
4. After Resume, re-attach the same tmux session and the user lands
   in the exact shell state they left
5. Document that the terminal is a tmux session — Ctrl-B prefix etc.

**Tradeoffs**:
- Slight learning curve for users who don't know tmux
- Mouse selection works differently inside tmux (could enable mouse
  mode)
- One more dependency in the base snapshot (~3MB)

The net is much better Resume UX. Worth it.

## 2. Reconciliation cost: Sandbox.get per session per poll

`/api/terminal/status` does `Promise.all(sessions.map(resolveSandboxState))`.
With N agents per repo, that's N HTTP calls to Vercel every 10s per
active user. Wasteful and adds latency to every status poll (~200ms
for the slowest call).

**Options**:

- **Cache server-side**: in-memory cache of sandbox state with 5s TTL.
  Survives across requests within the same warm function instance.
  Reduces Vercel API call volume by ~50% in practice.
- **Trust the DB more**: status route reads only from the DB. Add a
  background reconciliation job (cron) that runs every 60s and marks
  dead sandboxes completed. Status is up to 60s stale.
- **Decentralized**: status route trusts DB. The terminal panel's
  ghostty-web WebSocket reports back to a `/api/terminal/dead`
  endpoint when the WS fails to open or returns a known-dead error,
  which marks the session completed.

The decentralized option is the cleanest but requires the most
plumbing. The cache option is the smallest change for a big win.

## 3. Delete or commit-to-deploy the Cloudflare provider scaffold

`infra/terminalshare-proxy/` and `web/src/lib/agent-runtime/cloudflare-sandbox.ts`
exist as ~500 lines of unused code. The Worker isn't deployed and the
provider returns 501 placeholders. The provider-registry has dynamic
import paths for it that never resolve to anything useful.

It's been valuable as scaffolding (validates the multi-provider
abstraction, the routes were a useful design exercise), but it's now
sitting in the runtime where future contributors will trip over it.

**Two paths**:

- **Deploy it**: wire `@cloudflare/sandbox` SDK into the Worker, set
  up a Cloudflare account, deploy. ~2 days of work. We get a real
  multi-provider system.
- **Delete it**: remove the provider, the routes, the Worker scaffold.
  Move the design notes to `backlog/cloudflare-sandbox-live-plan.md`.
  ~1 hour of work. Surface area drops by 500 lines.

Neither is wrong. Sitting in the middle is the worst place.

## 4. Fix claude CLI "Not logged in · Please run /login" in sandboxes

When a user sends a chat message to an agent, the agent runs `claude`
CLI inside the sandbox. The CLI fails with "Not logged in · Please
run /login" because:

- ANTHROPIC_API_KEY is set in the sandbox env (we verified)
- But recent claude CLI versions need either an OAuth token or a
  config file that wasn't initialized
- The CLI is checking `~/.claude/credentials.json` or similar before
  falling back to env var auth

**Fix candidates**:

- Run `claude config set apiKey "$ANTHROPIC_API_KEY"` before the
  agent runner
- Or write `~/.claude/credentials.json` directly with the key
- Or pin the claude CLI to a version that respects the env var
  unconditionally
- Or use the Claude Agent SDK directly instead of the CLI

This isn't a terminal issue per se but it's a real bug in the agent
chat path. Users see the "Not logged in" message as the agent's
response. Captured from a screenshot in the polish session.

## 5. + button: agent picker

The `+` button in the sub-tab strip currently always calls
`startTerminal()` with no agent name, which uses `DEFAULT_AGENT ?? "shell"`.
If you already have a shell terminal running, the start route returns
the existing session (no-op visually). The user has no way to start a
terminal for a *different* named agent from the UI.

**Fix**: open a picker on click:

- `[default shell]` (default agent or "shell" slot)
- `[pick agent]` → submenu populated from `availableAgents` prop
- `[ad-hoc shell with custom name]` → text input

Today users can only get to a named-agent terminal by sending a chat
message to that agent first. The terminal tab should be a
first-class entry point.

## 6. agent_name column refactor

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

Not urgent but worth doing before adding more session kinds.

## 7. Cost awareness in the UI

Multiple sandboxes per repo across multiple repos can add up. Each
running sandbox is ~$0.10/hr on Vercel. A user with 5 active
sandboxes for 8 hours/day spends ~$120/month without realizing.

Need a header indicator: "● 3 active sandboxes" with a dropdown
showing each one and an estimated cost. A small affordance to stop
all of them at once.

## References

- Reflection thread that surfaced these: see the post-#299 reflect
  output in the session
- Architecture: `web/docs/architecture.md`
- Existing terminal polish backlog: `backlog/terminal-polish-followup.md`
- Cloudflare deploy plan: `backlog/cloudflare-sandbox-live-plan.md`

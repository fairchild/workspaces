# Agent Chat & Sandbox Architecture

The web app supports `@agent` chat: users type `@april-clearwater <message>` in the Spaces web chat, and the system spins up an isolated Vercel Sandbox microVM, clones the repo, runs Claude Code with the agent's persona, and streams the response back via SSE.

## Setup

### Environment Variables

```bash
# Vercel Sandbox (required for sandbox creation)
VERCEL_TOKEN=...
VERCEL_TEAM_ID=...
VERCEL_PROJECT_ID=...

# Anthropic (passed into sandbox for Claude CLI)
ANTHROPIC_API_KEY=...

# GitHub OAuth (for user auth + repo access)
GITHUB_WEB_WORKSPACES_CLIENT_ID=...
GITHUB_WEB_WORKSPACES_CLIENT_SECRET=...
```

On Vercel deployments, `VERCEL_OIDC_TOKEN` is used automatically instead of `VERCEL_TOKEN`.

### Local Development

```bash
# Copy env from main checkout (if working in a worktree)
cp ~/code/workspaces/web/.env.local web/.env.local
cp -r ~/code/workspaces/web/.vercel web/.vercel

# Run the dev server with auth bypass for testing
cd web && DEV_BYPASS_AUTH=1 pnpm dev
```

## Architecture

```
User: "@april-clearwater help me understand the sidebar code"
  │
  ▼
POST /api/chat/agent-stream
  │  Auth check (session + repo access + allowlist)
  ▼
SessionManager.handleMention()
  │
  ├─► resolvePersona()          — find .agents/skills/*/references/april-clearwater.md
  ├─► getActiveSessionForThread() — resume or create session
  ├─► getRegistry().getDefault() — get VercelSandboxProvider
  │
  ▼
VercelSandboxProvider.createSandbox()
  │
  ├─► getOrCreateBaseSnapshot()  — node22 + claude-code CLI (memoized, 30-day expiry)
  ├─► Sandbox.create()           — from base snapshot, 10m timeout
  ├─► git clone --depth 1        — target repo into /vercel/sandbox/repo
  ├─► writeFiles()               — system-prompt.txt, message.txt, run-agent.sh
  │
  ▼
VercelSandboxProvider.streamOutput()
  │  Executes: bash run-agent.sh (pipes message into claude CLI)
  │  Tools: Read, Glob, Grep, WebFetch (conversational = read-only)
  │
  ▼
SSE Response → Browser
  │  data: {"type":"status","content":"Agent is thinking..."}
  │  data: {"type":"text","content":"The sidebar is implemented in..."}
  │  data: {"type":"done","content":""}
  │
  ▼
persistAgentResponse()
  ├─► chat_messages table (SQLite)
  └─► GitHub Discussion comment (if discussionId provided)
```

## Key Components

| Component | File | Purpose |
|-----------|------|---------|
| Type definitions | `web/src/lib/agent-runtime/types.ts` | `ComputeProvider` interface, `StreamChunk`, `SandboxRequest` |
| Vercel Sandbox | `web/src/lib/agent-runtime/vercel-sandbox.ts` | Main provider: snapshot mgmt, sandbox lifecycle, streaming |
| Persona loader | `web/src/lib/agent-runtime/persona-loader.ts` | Discover + resolve agent personas from repo tree |
| Provider registry | `web/src/lib/agent-runtime/provider-registry.ts` | Registry of compute backends, lazy singleton |
| Session manager | `web/src/lib/agent-runtime/session-manager.ts` | Orchestrator: persona → sandbox → stream → persist |
| DB layer | `web/src/lib/agent-sessions.ts` | `agent_sessions` table CRUD (Kysely + libSQL) |
| SSE endpoint | `web/src/app/api/chat/agent-stream/route.ts` | HTTP handler with auth, allowlist, SSE streaming |
| Shared types | `web/src/lib/types.ts` | `AgentSession`, `AgentPersona`, `ChatMessage` |

## Compute Provider Abstraction

All sandbox backends implement `ComputeProvider`:

```typescript
interface ComputeProvider {
  descriptor: ComputeProviderDescriptor;
  checkAvailability(): Promise<ComputeProviderAvailability>;
  createSandbox(request: SandboxRequest): Promise<SandboxResult>;
  streamOutput(instanceId: string): AsyncGenerator<StreamChunk>;
  sendMessage(instanceId: string, message: string): Promise<void>;
  destroySandbox(instanceId: string): Promise<void>;
}
```

Currently implemented:
- **vercel-sandbox** — fully implemented (Firecracker microVMs via `@vercel/sandbox`)
- **daytona** — stub, returns unavailable
- **github-actions** — stub, returns unavailable

## Persona Files

Personas live at `.agents/skills/<skill>/references/<name>.md`. The filename slug becomes the `@` handle:

```
.agents/skills/cofounder-contributor/references/april-clearwater.md
→ @april-clearwater
```

Format: `# Display Name — Role` as the first heading, markdown body as system prompt.

The `buildConversationalPrompt()` function strips the `## Output Format` section (contributor-runtime-specific) and appends `## Conversational Mode` instructions that explain read-only constraints.

## Session Lifecycle

1. **starting** — session created in DB, sandbox being provisioned
2. **streaming** — sandbox ready, Claude CLI executing
3. **active** — response complete, sandbox alive for follow-up messages
4. **completed** — session ended, sandbox destroyed
5. **failed** — error during any phase

Sessions are keyed by `(repo, agentName, threadId)`. A follow-up message in the same thread resumes the existing sandbox instance via `sendMessage()` instead of creating a new one.

## Tool Restrictions

| Mode | Tools | Use Case |
|------|-------|----------|
| conversational | `Read, Glob, Grep, WebFetch` | Web chat (read-only) |
| full | `Read, Write, Edit, Bash, Glob, Grep, WebFetch` | Execution mode (future) |

## Network Policy

Sandboxes can only reach:
- `api.anthropic.com` — Claude API
- `github.com` — repo operations
- `*.githubusercontent.com` — raw file access

## Security

- **Shell injection prevention**: prompts and messages are written to files, not interpolated into shell commands
- **Auth chain**: OAuth session → repo access check → GitHub login allowlist
- **Allowlist**: only logins in `ALLOWED_GITHUB_LOGINS` can trigger agent sessions
- **Read-only default**: web chat sessions use conversational tools (no Write/Edit/Bash)

## Testing

```bash
# Unit tests only (no Vercel/Anthropic creds needed)
npx tsx web/scripts/test-sandbox-e2e.ts --unit-only

# Full E2E (needs all env vars)
npx tsx web/scripts/test-sandbox-e2e.ts

# Sandbox lifecycle only
npx tsx web/scripts/test-sandbox-e2e.ts --sandbox-only
```

The E2E script tests:
1. Provider registry — default provider, stubs unavailable
2. Persona resolution — discovery, matching, prompt building
3. Session persistence — CRUD operations, status transitions
4. Access control — allowlist presence, 403 responses
5. Sandbox lifecycle — create, stream, follow-up, destroy (requires creds)

## Base Snapshot Strategy

Creating a sandbox from scratch (install node, install claude-code) takes minutes. To avoid this on every request:

1. First request creates a **base snapshot**: node22 runtime + `@anthropic-ai/claude-code` globally installed + ttyd + tmux
2. The snapshot is promise-memoized — concurrent requests share the same creation
3. Subsequent sandboxes clone from the base snapshot (seconds, not minutes)
4. Base snapshots expire after 30 days; session snapshots after 7 days
5. Bump `BASE_SNAPSHOT_VERSION` in `vercel-sandbox.ts` when adding new tooling — old versions remain valid until manually deleted, which lets us roll back without rebuilding. Current version: `v3-tmux`.

## Session Continuity via tmux

`startTtyd` runs `tmux new-session -A -s shell` instead of bare bash. The `-A` flag attaches to an existing session if one is present, otherwise creates it. Combined with the Resume flow (snapshot the sandbox filesystem, restore later into a new sandbox), this means:

- Resume → restore snapshot → new sandbox → `startTtyd` → `tmux new-session -A -s shell` → tmux finds the existing `shell` session on disk → attaches → user lands in the exact shell state they left (`cd`, env, command history, running processes, whatever)

Without tmux, Resume only restored the filesystem; bash was a fresh process. With tmux, the shell process itself survives. This is what "Resume" should have meant all along.

Tradeoffs:
- Mouse selection behaves slightly differently inside tmux
- Users unfamiliar with tmux may be surprised by the Ctrl-B prefix
- Roughly 3 MB extra in the base snapshot

Net: much better Resume UX. Worth it.

## DB query volume (don't re-break this)

One dashboard tab open for a few hours a day generated enough read
volume to exhaust a Turso starter plan (500M rows/month) in a
single billing cycle. The dashboard went down one morning and the
culprit was a missing composite index on `webhook_events`.

### The hot-path contract

Any query invoked from a polling endpoint must use an index that
covers **both** the filter and the order. For
`WHERE repo = ? ORDER BY timestamp DESC LIMIT N`, that means a
composite `(repo, timestamp desc)` index — separate `(repo)` and
`(timestamp)` indexes are not sufficient. The planner picks one,
scans every matching row, sorts in memory, then takes N.

`chat_messages` has `idx_chat_messages_repo_ts`. `webhook_events`
now has `idx_webhook_events_repo_ts`. Verify any new polled table
has the same shape before shipping.

### Current polling cadences

| Endpoint | Component | Interval |
|---|---|---|
| `/api/chat/messages` | `chat-panel.tsx` | 10s (was 5s, bumped after the incident) |
| `/api/events` | `activity-feed.tsx` | 10s |
| `/api/terminal/status` | `use-terminal-sessions.ts` + `chat-panel.tsx` | 10s |

Any new polled endpoint should default to 10s or slower unless
there's a compelling UX reason. If you need faster refresh, prefer
SSE or a Durable Object over client polling.

### The cache for `getEventStats`

`getEventStats` does a `SELECT DISTINCT repo FROM webhook_events`
which is a full-table scan — no index can help it. It's called from
every `/api/chat/messages` POST (indirectly via
`handleBotCommand`). The function is module-level TTL-cached for
60s. **Don't remove the cache.** If you need fresher stats,
consider a counter table updated by triggers rather than scanning
the events table.

### Measuring read volume

```bash
turso db inspect spaces-web
```

shows rows-read for the current billing period. Expect <50M/month
on a single-user workload with the indexes in place. Anything
dramatically higher is a regression — check which endpoint is
newly-hot.

## Claude CLI Authentication (don't re-break this)

The runner invokes `claude -p` inside the sandbox. Claude CLI needs
credentials, and setting them up is NOT as simple as it looks.

### The gotcha

`Sandbox.create({env: {...}})` **does NOT propagate** env vars to
`sandbox.runCommand()` invocations. Every `runCommand` spawns with an
empty environment relative to the sandbox-level config. Passing
`ANTHROPIC_API_KEY` at sandbox creation and hoping `claude` sees it
in env was silently broken from whenever Vercel changed the env
behavior (maybe since day one — we just didn't notice because early
tests hit a cached snapshot response).

PR #306 and PR #307 both failed because they assumed env
propagation. PR #308 (a temporary diagnostic probe in the runner
script) revealed the actual state — all expected env vars were
length 0. PR #309 fixed it.

### The fix: source env.sh

The runner script starts with:

```bash
#!/bin/bash
set -e
source /vercel/sandbox/env.sh
```

`env.sh` is written alongside the runner by `buildEnvSource(apiKey)`:

```sh
# Sourced by /vercel/sandbox/run-agent.sh
export ANTHROPIC_API_KEY='<key>'
export CLAUDE_CONFIG_DIR='/vercel/sandbox/claude-config'
```

The API key value is single-quoted with apostrophe escaping
(`'\\''`) so a key containing a literal apostrophe won't break the
source. After sourcing, `ANTHROPIC_API_KEY` is in the bash env,
`claude` inherits it, and per the [docs](https://code.claude.com/docs/en/authentication)
the CLI uses it directly in non-interactive `-p` mode.

`CLAUDE_CONFIG_DIR` points the CLI at a known absolute path (no
HOME ambiguity between `root` and `vercel-sandbox` users), and a
`settings.json` in that dir provides an `apiKeyHelper` fallback in
case env-var auth ever stops working.

### If "Not logged in" comes back

1. Check the agent stream output for `"Not logged in · Please run /login"`
2. Temporarily re-add a diagnostic probe to `buildRunnerScript()` —
   the pattern is in git history on PR #308:
   ```bash
   echo "ANTHROPIC_API_KEY length: ${#ANTHROPIC_API_KEY}"
   echo "CLAUDE_CONFIG_DIR: $CLAUDE_CONFIG_DIR"
   ls -la "$CLAUDE_CONFIG_DIR"
   ```
3. Ship the probe, send one chat message, read the stream output.
   Four PRs of guesswork were replaced by one probe cycle in this arc.
4. Don't merge a fix without exercising the agent stream end-to-end
   in production. Green unit tests and lint are necessary but not
   sufficient — the test surface doesn't include the "does claude
   actually authenticate" path.

## Troubleshooting

| Symptom | Most likely cause | Fix |
|---------|------------------|-----|
| "Not logged in · Please run /login" in agent stream | env.sh not sourced, or ANTHROPIC_API_KEY missing | See "Claude CLI Authentication" section above |
| Agent stream hangs on "Agent is thinking..." | Base snapshot issue (old CLI version, network policy) | Bump `BASE_SNAPSHOT_VERSION`, recreate base |
| `Sandbox.create` throws "Missing credentials" | Dev env has no Vercel token | `.env.local` needs `VERCEL_TOKEN` + `VERCEL_TEAM_ID` + `VERCEL_PROJECT_ID`, or run on Vercel |
| ttyd WebSocket 404s | ttyd started without `-b /<token>` base path | All sandbox creation must go through `startTtyd(sandbox)` helper |
| Agent sub-tab can't connect to restored sandbox | `restoreSnapshot` didn't re-run `startTtyd` with a new token | Handled in `restoreSnapshot` — verify via `resolveSandboxState` returns a `terminalUrl` with the new sandbox ID's token |

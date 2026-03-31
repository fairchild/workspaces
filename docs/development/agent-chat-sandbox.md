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

1. First request creates a **base snapshot**: node22 runtime + `@anthropic-ai/claude-code` globally installed
2. The snapshot is promise-memoized — concurrent requests share the same creation
3. Subsequent sandboxes clone from the base snapshot (seconds, not minutes)
4. Base snapshots expire after 30 days; session snapshots after 7 days

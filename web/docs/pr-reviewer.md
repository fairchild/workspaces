# PR Reviewer — Managed Agent

Automated code review triggered by GitHub `pull_request.opened` webhooks. The agent runs on Anthropic's infrastructure, reads the diff, explores surrounding code, runs tests, and posts a review via GitHub MCP.

## Architecture

```
GitHub PR opened
  → Cloudflare webhook relay
    → web/api/webhooks/github (webhook route)
      → triggerPrReview() (fire-and-forget)
        → getOrCreateAgent/Environment (idempotent, DB-cached)
        → sessions.create (mounts repo at PR branch)
        → events.send (kickoff message)
        → Agent runs autonomously on Anthropic → posts review via GitHub MCP
```

## Key Files

| File | Purpose |
|------|---------|
| `web/src/lib/agent-runtime/pr-review.ts` | Agent config, session creation, kickoff |
| `web/src/lib/agent-runtime/managed-agents-cache.ts` | Idempotent agent/environment creation with DB cache |
| `web/src/app/api/webhooks/github/route.ts` | Webhook handler — triggers on `pull_request.opened` |
| `web/src/app/api/managed-agents/transcript/route.ts` | SSE endpoint for streaming session events to the UI |

## Environment Variables

| Var | Where | Purpose |
|-----|-------|---------|
| `ANTHROPIC_API_KEY` | Vercel | Anthropic API authentication |
| `GITHUB_TOKEN` | Vercel | PAT for cloning repos into the sandbox (needs `repo` scope) |
| `PR_REVIEWER_VAULT_ID` | Vercel | Vault containing GitHub MCP OAuth credentials |
| `PR_REVIEWER_MODEL` | Vercel (optional) | Override model (default: `claude-opus-4-6`) |

**Security:** Never print tokens to logs. Use pipes (`gh auth token | vercel env add ...`) or files, never standalone `echo`/`print` of credential values.

## Observing Sessions

### List recent sessions

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions?limit=5" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" | python3 -m json.tool
```

### Check a session's status and usage

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions/$SESSION_ID" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  | python3 -c "import sys,json; s=json.load(sys.stdin); print(f'status={s[\"status\"]} usage={json.dumps(s.get(\"usage\",{}))}')"
```

### Stream session events (tool calls + results)

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions/$SESSION_ID/events" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('data', []):
    t = e.get('type','')
    if t == 'agent.message':
        for b in e.get('content', []):
            if b.get('type') == 'text': print(f'[msg] {b[\"text\"][:300]}')
    elif t == 'agent.tool_use':
        print(f'[tool] {e.get(\"name\",\"\")}: {json.dumps(e.get(\"input\",{}))[:200]}')
    elif t == 'agent.tool_result':
        parts = [b.get('text','')[:150] for b in e.get('content',[]) if b.get('type')=='text']
        if parts: print(f'[result] {parts[0]}')
    elif t.startswith('session.'):
        print(f'[{t}] {json.dumps(e.get(\"stop_reason\",{}))}')
    elif t == 'session.error':
        print(f'[error] {json.dumps(e.get(\"error\",{}))}')
"
```

### Check Vercel production logs

```bash
vercel logs --environment production --no-branch --since 5m --expand --json --level error 2>&1 \
  | python3 -c "
import sys, json
for line in sys.stdin:
    if not line.strip().startswith('{'): continue
    try:
        obj = json.loads(line)
        for l in obj.get('logs', []):
            msg = l.get('message','')
            if msg: print(msg[:300])
    except: pass
"
```

## Debugging

### Session created but repo empty

The `GITHUB_TOKEN` likely expired. OAuth tokens (`gho_`) are short-lived. Fix:

```bash
# Rotate and set without printing the token value
gh auth refresh --hostname github.com
gh auth token | vercel env rm GITHUB_TOKEN production --yes 2>/dev/null
gh auth token | vercel env add GITHUB_TOKEN production
vercel deploy --prod
```

For durable auth, create a GitHub App via the `/gh-apps` skill.

### MCP server auth failed

The vault credential is empty or expired. Error looks like:
```
MCP server 'github' initialize failed: authorization token is invalid or expired
```

Add a credential to the vault — see `shared/managed-agents-tools.md` §Vaults for the OAuth shape.

### Webhook fires but no session created

Check Vercel error logs. Common causes:
- `ANTHROPIC_API_KEY` not set (only in production, not preview)
- `PR_REVIEWER_VAULT_ID` has a trailing newline (use `printf` not `echo` when setting)
- Webhook secret mismatch between GitHub and `GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET`

### Agent can't find the diff

The sandbox only checks out the PR branch. The agent needs to `git fetch origin main` before diffing. The system prompt instructs this, but if it fails, the git proxy may not have the base ref cached.

### `swift` not available in sandbox

Expected — the sandbox is Linux. The agent can still review Swift code (read, grep, explore) but can't compile or run tests. The web tests (TypeScript) work fine since Node.js is available.

## Evolving the Agent

### Change the system prompt

Edit `SYSTEM_PROMPT` in `web/src/lib/agent-runtime/pr-review.ts`. The hash-based cache means a new prompt automatically creates a new agent version — no manual cleanup needed.

### Add tools or MCP servers

Edit `TOOLS` or `MCP_SERVERS` arrays in `pr-review.ts`. Same cache behavior — config changes create a new agent.

### Change the trigger

Currently fires on `pull_request.opened` only. To also fire on `reopened` or `synchronize` (new commits pushed), edit the condition in `web/src/app/api/webhooks/github/route.ts`:

```ts
// Current: only new PRs
if (eventType === "pull_request" && action === "opened") {

// Also re-review on new commits:
if (eventType === "pull_request" && (action === "opened" || action === "synchronize")) {
```

### Filter by repo or label

Add conditions before `triggerPrReview()` in the webhook route:

```ts
// Only review PRs in specific repos
if (repoObj.full_name !== "fairchild/workspaces") return;

// Skip draft PRs
if (pr.draft) return;

// Only review PRs with a specific label
const labels = pr.labels as Array<{name: string}> | undefined;
if (!labels?.some(l => l.name === "review-wanted")) return;
```

### Cost control

Set `PR_REVIEWER_MODEL=claude-sonnet-4-6` for cheaper reviews on routine PRs. Use Opus for complex changes by checking diff size in the webhook handler.

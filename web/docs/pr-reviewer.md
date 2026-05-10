# PR Reviewer — Managed Agent

Automated code review triggered by GitHub `pull_request.opened` webhooks. The agent runs on Anthropic's infrastructure, reads the diff, explores surrounding code, runs tests, and posts a review via the GitHub API.

## Architecture

```
GitHub PR opened
  → Cloudflare webhook relay
    → web/api/webhooks/github (webhook route)
      → triggerPrReview() (fire-and-forget)
        → getOrCreateAgent/Environment (idempotent, DB-cached)
        → sessions.create (mounts repo at PR branch)
        → events.send (kickoff message)
        → Files API uploads GitHub token as mounted file
        → Agent runs autonomously on Anthropic → posts review via GitHub API (curl)
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
| `PR_REVIEWER_APP_ID` | Vercel | GitHub App ID for bot identity |
| `PR_REVIEWER_PRIVATE_KEY` | Vercel | GitHub App private key (PEM) |
| `PR_REVIEWER_INSTALLATION_ID` | Vercel | GitHub App installation ID for this repo |
| `GITHUB_TOKEN` | Vercel (fallback) | PAT fallback — used only if App credentials are missing |
| `PR_REVIEWER_VAULT_ID` | Vercel (optional) | Vault for MCP credentials (not currently used) |
| `PR_REVIEWER_MODEL` | Vercel (optional) | Override model (default: `claude-opus-4-6`) |

### GitHub App setup

Reviews are posted by the `workspaces-pr-reviewer` GitHub App, which gives them a dedicated bot identity instead of being attributed to a personal account. To set up:

1. Create a GitHub App at https://github.com/settings/apps with permissions: `contents:read`, `pull_requests:write`
2. Install the app on `fairchild/workspaces` and note the installation ID
3. Set `PR_REVIEWER_APP_ID`, `PR_REVIEWER_PRIVATE_KEY`, and `PR_REVIEWER_INSTALLATION_ID` in Vercel

The app generates short-lived installation tokens (1-hour TTL) on demand — no manual token rotation needed. If the App credentials are missing or token exchange fails, `triggerPrReview()` falls back to `GITHUB_TOKEN`.

**How the token reaches the agent:** `triggerPrReview()` calls `resolveGitHubToken()` which generates a short-lived installation token from the GitHub App credentials (or falls back to `GITHUB_TOKEN`). The token is uploaded as a file via the Files API and mounted at `/workspace/.github-token`. The agent reads it with `cat` and uses `curl` to post the review. The token never appears in the prompt or message stream.

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

If using the GitHub App: check that `PR_REVIEWER_APP_ID`, `PR_REVIEWER_PRIVATE_KEY`, and `PR_REVIEWER_INSTALLATION_ID` are set correctly. The private key PEM must have real newlines (Vercel handles this, but verify with `vercel env pull`).

If using the PAT fallback: the `GITHUB_TOKEN` likely expired. OAuth tokens (`gho_`) are short-lived. Fix:

```bash
# Rotate and set without printing the token value
gh auth refresh --hostname github.com
gh auth token | vercel env rm GITHUB_TOKEN production --yes 2>/dev/null
gh auth token | vercel env add GITHUB_TOKEN production
vercel deploy --prod
```

### Review not posted to GitHub

Check the session events for the `curl` call. Common causes:
- GitHub App token exchange failed — check Vercel logs for `[pr-review] GitHub App token failed`
- `GITHUB_TOKEN` expired (PAT fallback) — rotate with `gh auth refresh` then update Vercel
- Token file not mounted — check session resources for `/workspace/.github-token`
- API response `401` — App not installed on the repo, or PAT lacks `repo` scope
- API response `403` — App missing `pull_requests:write` permission
- API response `422` — review body has unescaped JSON characters

### Webhook fires but no session created

Check Vercel error logs. Common causes:
- `ANTHROPIC_API_KEY` not set (only in production, not preview)
- Env var has a trailing newline (use `printf` not `echo` when setting)
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

### Triggers

The reviewer is **continuous**: it reruns on meaningful PR updates and carries
its own prior review state into each rerun so it can revise (or approve) a
stale `REQUEST_CHANGES` instead of repeating itself.

`parsePrReviewTrigger()` in `web/src/app/api/webhooks/github/route.ts` accepts:

| Event | Action | Behavior |
|-------|--------|----------|
| `pull_request` | `opened` | Initial review (skip drafts) |
| `pull_request` | `reopened` | Rerun (skip drafts) |
| `pull_request` | `ready_for_review` | Rerun even when previous state was draft |
| `pull_request` | `synchronize` | Rerun on new head SHA (skip drafts) |
| `pull_request` | `edited` | Rerun only when `changes.body` is present (skip drafts) |
| `issue_comment` | `created` | Rerun when the comment is on a PR thread, the sender is a non-bot, and the body matches an evidence signal: `evidence.cloudcompute.com`, `Evidence:`, `swift test`, `playwright`, `screenshot`, `recording`, `validation` |

Loop guards skip events from any `*[bot]` sender (including the reviewer
itself) and from `Bot`-typed senders.

### Idempotency

Every dispatch computes a fingerprint over
`(repo, pr, headSha, triggerKind, triggerSourceId, reviewerConfigHash)` and
inserts a row into `managed_pr_review_runs` (created on first use). When the
insert is a no-op (duplicate fingerprint), the run is skipped. Effects:

- Webhook redeliveries for the same trigger are no-ops.
- A new commit changes `headSha` → new fingerprint → rerun.
- Distinct evidence comments on the same head produce distinct
  `triggerSourceId` values → each runs once.
- A reviewer prompt or model change rotates `reviewerConfigHash`, allowing a
  re-evaluation of the same head without manual intervention.

### Same-PR review history in the kickoff

For any rerun (`kind !== "opened"`), the runtime fetches the bot's prior
reviews on the current PR via `GET /repos/{owner}/{repo}/pulls/{pr}/reviews`,
keeps the newest 3, and includes them as untrusted context inside a
`<untrusted-content name="prior-managed-reviews">` block. A small trusted
instruction tells the reviewer to approve when a prior `REQUEST_CHANGES`
blocker is now resolved by the current body, comments, or commits.

### Filter by repo or label

Add conditions inside `parsePrReviewTrigger()` in the webhook route, e.g.:

```ts
// Only review PRs in specific repos
if (String(repoObj.full_name) !== "fairchild/workspaces") return null;

// Only review PRs with a specific label
const labels = pr.labels as Array<{name: string}> | undefined;
if (!labels?.some((l) => l.name === "review-wanted")) return null;
```

### Cost control

Set `PR_REVIEWER_MODEL=claude-sonnet-4-6` for cheaper reviews on routine PRs. Use Opus for complex changes by checking diff size in the webhook handler.

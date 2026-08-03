# QA: Spaces Web Chat Platform

> **2026-07-02 addendum:** this is a historical QA report from the March consolidation. The Chat SDK **bot path** described below (`bot.ts`, `@chat-adapter/*`, the `[platform]` webhook route, Slack adapter, AI streaming via `ai.ts`) was retired as dead code in PR #725 — see issue #540. The dashboard Chat tab, dispatch flow, and `/api/chat/*` routes remain live and never depended on the SDK.

## What was shipped

Six feature branches were consolidated and merged to main as PR #246, followed by bug fixes #248 and #249. The production site is at `https://spaces.cloudcompute.com`. PR #250 (GitHub token refresh) is pending merge.

### Features added

1. **Chat Tab** — Dashboard now has Dashboard/Chat tab navigation. Chat tab shows a mixed timeline of webhook events and chat messages with a compose bar for sending messages and @mentioning agents.
2. **AI Streaming** — When the bot is @mentioned in a GitHub Discussion and `ANTHROPIC_API_KEY` is set, it streams a response via the Claude API. Falls back to a status summary when no API key is configured.
3. **Slack Adapter** — Chat SDK Slack adapter configured when `SLACK_BOT_TOKEN` is set. Enables team notifications for build failures and PR reviews.
4. **Workspace Status Cards** — Bot responds to `status` messages with a GFM markdown table of workspace name, status, branch, and last activity.
5. **Agent Dispatch** — @mention an agent in chat to dispatch work. Shows a confirmation dialog, creates a GitHub Discussion, streams progress via webhooks. Dispatch cards show status (pending/running/complete/failed).
6. **Workspace Sync Endpoint** — POST `/api/workspaces/sync` accepts workspace state from the native macOS app. GET returns current state.
7. **Tab Bar Fix** (#248) — Tab bar was hidden on desktop via `display: none`. Now visible with accent underline active indicator.
8. **Env Var Fix** (#249) — `bot.ts` was using `GITHUB_APP_ID` etc. instead of the actual Vercel env var names `GITHUB_WEB_WORKSPACES_*`.
9. **Token Refresh** (#250, pending) — Expired GitHub OAuth tokens are now auto-refreshed. 401 errors show a clean "sign out and back in" prompt instead of raw error JSON.

### Architecture

- **Framework**: Next.js 15 on Vercel
- **Auth**: Better Auth with GitHub OAuth (`GITHUB_WEB_WORKSPACES_CLIENT_ID/SECRET`)
- **Database**: Turso (LibSQL) via Kysely — tables: `webhook_events`, `chat_messages`, `workspaces`
- **Chat SDK**: `chat` package with `@chat-adapter/github` and optional `@chat-adapter/slack`
- **AI**: `@anthropic-ai/sdk` for streaming responses (model: `claude-sonnet-4-6`)
- **Webhooks**: GitHub webhooks hit `/api/webhooks/github`, events stored in Turso and streamed to dashboard

### Env vars required in Vercel

| Var | Purpose |
|-----|---------|
| `GITHUB_WEB_WORKSPACES_APP_ID` | GitHub App ID for Chat SDK bot |
| `GITHUB_WEB_WORKSPACES_CLIENT_ID` | GitHub OAuth client ID (auth) |
| `GITHUB_WEB_WORKSPACES_CLIENT_SECRET` | GitHub OAuth client secret (auth) |
| `GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET` | Webhook signature verification |
| `GITHUB_WEB_WORKSPACES_PRIVATE_KEY` | GitHub App private key (Chat SDK bot) |
| `BETTER_AUTH_SECRET` | Session encryption secret |
| `TURSO_DATABASE_URL` | Turso DB URL |
| `TURSO_AUTH_TOKEN` | Turso auth token |
| `ANTHROPIC_API_KEY` | (Optional) Enables AI streaming responses |
| `SLACK_BOT_TOKEN` | (Optional) Enables Slack adapter |
| `SLACK_SIGNING_SECRET` | (Optional) Slack webhook verification |
| `WORKSPACE_SYNC_API_KEY` | (Optional) API key auth for native app sync |

## QA Validation Plan

### 1. Production smoke test (`spaces.cloudcompute.com`)

**Auth flow:**
- [ ] Landing page loads at `/`
- [ ] "Continue with GitHub" sign-in works
- [ ] Session persists across page reloads
- [ ] Sign out works and clears session

**Dashboard tab:**
- [ ] Sidebar shows added repos
- [ ] Clicking a repo loads the repo detail view
- [ ] Activity feed on the right shows live webhook events
- [ ] Activity feed updates in real-time (push a commit and watch it appear)
- [ ] Event cards show correct type badges (CI, PR, PUSH, ISSUE)
- [ ] After #250 merges: repo detail view loads agent data (no 401 error)

**Chat tab:**
- [ ] Tab bar is visible on desktop with Dashboard and Chat buttons
- [ ] Clicking Chat switches to chat view with accent underline on active tab
- [ ] Clicking Dashboard switches back
- [ ] URL updates with `?tab=chat` when switching
- [ ] Direct navigation to `?tab=chat` works
- [ ] Mixed timeline shows webhook events with type badges and timestamps
- [ ] Day separator headers appear between different days
- [ ] Compose bar visible at bottom: "Type a message or @mention an agent..."
- [ ] Helper text shows keyboard shortcuts

**Chat compose:**
- [ ] Typing in compose bar works
- [ ] Enter sends a message (appears in timeline)
- [ ] Shift+Enter creates a newline
- [ ] `@` triggers mention autocomplete (may be empty if no agents discovered due to 401)
- [ ] Sent message persists across page reload (stored in Turso)

### 2. API endpoint validation

Test these with curl or browser dev tools:

```bash
# Events API — should return webhook events array
curl -s https://spaces.cloudcompute.com/api/events | head -c 200

# Chat messages timeline — should return mixed events + messages
curl -s "https://spaces.cloudcompute.com/api/chat/messages?repo=fairchild/workspaces" | head -c 200

# Workspace sync GET — should return { workspaces: [] }
curl -s https://spaces.cloudcompute.com/api/workspaces/sync

# Workspace sync POST — should require auth
curl -s -X POST https://spaces.cloudcompute.com/api/workspaces/sync \
  -H "Content-Type: application/json" \
  -d '{"workspaces": []}' | head -c 200

# Webhook endpoint — should reject unsigned requests in production
curl -s -X POST https://spaces.cloudcompute.com/api/webhooks/github \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: ping" \
  -d '{}' | head -c 200
```

### 3. Webhook flow validation

- [ ] Push a commit to `fairchild/workspaces` — event appears in activity feed within 5 seconds
- [ ] Open/close a PR — event appears with correct type badge
- [ ] Create an issue — event appears
- [ ] Webhook signature verification works (reject tampered payloads)

### 4. Responsive layout

- [ ] Desktop (>960px): 3-column layout — sidebar, center (with tab bar), activity feed
- [ ] Tablet (640-960px): 2-column layout — sidebar, center. Activity feed hidden.
- [ ] Mobile (<640px): Single column with bottom tab bar

### 5. Edge cases and error handling

- [ ] No repos added: shows "Select a repo" placeholder
- [ ] Invalid repo URL: appropriate error message
- [ ] Network disconnection: events stop updating, reconnects when network returns
- [ ] Expired session: redirects to sign-in
- [ ] After #250: expired GitHub token auto-refreshes transparently
- [ ] After #250: if refresh fails, shows "sign out and back in" prompt

### 6. Code quality (already verified)

- [x] `pnpm biome check .` passes
- [x] `pnpm typecheck` passes
- [x] Web CI passes on all merged PRs
- [ ] No console errors in browser dev tools during normal usage
- [ ] No uncaught promise rejections

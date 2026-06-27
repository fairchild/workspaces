# Real-Time Notifications

GitHub webhook events are relayed to the app over WebSocket via a Cloudflare Worker.

## Architecture

```
GitHub (webhook) ──POST──▶ Cloudflare Worker ──▶ Durable Object (per org)
                              │                       │
                              │                   SQLite store
                              │                   (7-day retention)
                              │                       │
                              │                  per-client repo filtering
                              │                       │
                              │                  WebSocket broadcast
                              ▼                       │
                         /auth/session           ◀────┘
                         (JWT exchange)
                              │
macOS App                     │
  ├─ Settings: Device Flow auth ──▶ GitHub token ──▶ JWT
  ├─ NotificationCoordinator: owns auth state + stream lifecycle
  └─ EventStreamService: WebSocket client with reconnect
```

## Security Model

Three trust boundaries protect the system:

```
                    ┌─────────────────────────────────────┐
                    │         Trust Boundary 1            │
                    │     Webhook Ingress (GitHub→Worker)  │
                    │                                     │
                    │  HMAC-SHA256 signature verification  │
                    │  X-Hub-Signature-256 header          │
                    │  Shared secret: GITHUB_WEBHOOK_SECRET│
                    │  Timing-safe comparison              │
                    └─────────────────────────────────────┘
                                    │
                    ┌─────────────────────────────────────┐
                    │         Trust Boundary 2            │
                    │     Session Creation (App→Worker)    │
                    │                                     │
                    │  GitHub token verified against API   │
                    │  GitHub App installation confirmed   │
                    │  JWT issued: sub, login, orgs, 8h exp│
                    │  HMAC-SHA256 signed (JWT_SIGNING_SECRET)│
                    └─────────────────────────────────────┘
                                    │
                    ┌─────────────────────────────────────┐
                    │         Trust Boundary 3            │
                    │     WebSocket Connect (App→Worker)   │
                    │                                     │
                    │  Layer 1: JWT (Authorization header) │
                    │    → signature + expiry check        │
                    │  Layer 2: Org check (JWT orgs claim) │
                    │    → owner ∈ orgs                    │
                    │  Layer 3: Repo access (GitHub API)   │
                    │    → GET /orgs/{owner}/repos         │
                    │    → per-client filtering in DO      │
                    │    → X-GitHub-Token header (REQUIRED) │
                    └─────────────────────────────────────┘
```

### Why Three Layers

Org membership alone is insufficient — a user in `my-org` may not have access to `my-org/private-repo`. The three layers are:

1. **JWT validity** — proves the user authenticated via our auth flow (not forged)
2. **Org membership** (`orgs` claim) — fast check, avoids GitHub API call for unrelated orgs
3. **Repo access** (`GET /orgs/{owner}/repos` with user's token) — authoritative, respects GitHub's permission model. Accessible repos are stored as a per-client WebSocket attachment; the DO filters all broadcasts and catch-up by this set.

All three are **required**. The `X-GitHub-Token` header is mandatory.

### Token Storage

| Token | Storage | Lifetime |
|-------|---------|----------|
| GitHub OAuth token | macOS Keychain | Until revoked |
| JWT | macOS Keychain | 8 hours (server-enforced `exp` claim), silently refreshed 15 min before expiry |
| GitHub login | macOS Keychain | Until sign-out |

### Logging Privacy

Tokens, JWTs, email addresses, and IP addresses are **never logged**. Safe fields: `login`, `owner`, `repo`, `event_type`, `delivery_id`, HTTP status codes, counts.

### Crypto Implementation

All cryptographic operations use the Web Crypto API (`crypto.subtle`), not userland libraries:
- **Webhook signatures**: HMAC-SHA256 with timing-safe comparison (`github-verify.ts`)
- **JWT**: HMAC-SHA256 sign/verify with base64url encoding, `exp` claim enforcement
- **No custom crypto** — all primitives are platform-provided

## Authentication Flow

1. User enables notifications in Settings and clicks "Sign in with GitHub"
2. **Device Flow** (RFC 8628): App requests a device code, user authorizes at github.com
3. App exchanges the GitHub token for a **JWT** via `POST /auth/session`
4. JWT encodes: `sub` (GitHub user ID), `login`, `orgs` (installed GitHub App orgs), 8h expiry
5. JWT, login, and GitHub token stored in macOS Keychain

## WebSocket Connection

- URL: `wss://webhooks.cloudcompute.com/ws/{owner}`
- **Required headers**: `Authorization: Bearer {jwt}`, `X-GitHub-Token: {github_token}`
- One WebSocket per org — the app routes events locally by `repo` field
- On connect, Worker fetches accessible repos via `GET /orgs/{owner}/repos` (falls back to `/users/{owner}/repos` for personal accounts)
- Accessible repos stored as WebSocket attachment; broadcasts and catch-up filtered per-client
- On connect, receives catch-up batch of recent events (last 50, filtered by access)
- Live events: `{ type: "event", event: { id, type, action, summary, repo, timestamp } }`
- Client sends periodic pings (30s); Worker auto-responds with pong
- Reconnect: exponential backoff (1s → 30s cap), max 10 attempts

## Cloudflare Worker

Deployed at `webhooks.cloudcompute.com` (preview: `webhooks-preview.cloudcompute.com`).

```bash
cd infra/cloudflare-webhook-relay
bun run --bun wrangler deploy              # production
bun run --bun wrangler deploy --env preview # preview
```

**Secrets** (set via `wrangler secret put`):
- `GITHUB_WEBHOOK_SECRET` — shared secret for GitHub webhook signature verification
- `JWT_SIGNING_SECRET` — HMAC-SHA256 key for notification-session JWT
  signing/verification. This is a shared cross-worker secret: keep the same
  value on `webhook-relay`, `webhook-relay-preview`, `feedback-store`, and
  `feedback-store-preview`. Rotate all four together; mismatched values do not
  break anonymous feedback submission, but they do break signed-in feedback
  attribution and any other worker that verifies notification JWTs.
- `WORKSPACES_WEBHOOK_CANARY_SECRET` — canary-only shared secret used to prove
  the signed Cloudflare-to-Vercel reviewer ingress path without starting an
  agent

**Vars** (set in `wrangler.toml` or via Cloudflare):
- `WEBHOOK_FORWARD_URL` — optional web app webhook endpoint. Production uses
  `https://spaces.cloudcompute.com/api/webhooks/github` so managed PR review
  triggers reach the Next.js route after the relay verifies GitHub's signature.
  The relay accepts HTTPS URLs in production and local HTTP URLs only for tests.

**Routes:**
- `POST /webhook` — receives GitHub webhooks, verifies signature, forwards to org DO, and forwards managed-review trigger candidates to the web app
- `POST /canary/pr-review-ingress` — requires `WORKSPACES_WEBHOOK_CANARY_SECRET`, sends a signed dry-run PR-review webhook to the web app, and returns whether the web route would trigger the reviewer
- `POST /auth/session` — exchanges GitHub token for JWT
- `GET /ws/{owner}` — WebSocket upgrade with per-client repo filtering (requires JWT + GitHub token)
- `GET /health` — health check

### Worker Source Files

| File | Role |
|------|------|
| `src/index.ts` | Router — matches routes, handles auth/webhook/ws, delegates to Durable Object |
| `src/webhook-relay.ts` | `WebhookRelay` Durable Object — SQLite event storage, WebSocket lifecycle, broadcast |
| `src/github-verify.ts` | Crypto — HMAC-SHA256 signature verification, JWT sign/verify, timing-safe compare |
| `src/log.ts` | Structured JSON logging helper (`{ level, msg, ts, ...context }`) |
| `test/e2e.ts` | E2E test harness — orchestrates mock + wrangler dev + behavior-level scenarios |
| `test/mock-github.ts` | Mock GitHub API server with token-dependent behavior |

### Durable Object Lifecycle

One `WebhookRelay` DO per org, keyed by `idFromName("{owner}")`. Each DO:

1. **Creates** on first webhook or WebSocket request for the org
2. **Hibernates** when no WebSockets are connected (zero cost)
3. **Wakes** on next webhook POST or WebSocket upgrade
4. **Retains** SQLite state across hibernation cycles

WebSocket connections use the Hibernation API (`ctx.acceptWebSocket` + event handlers). Per-client allowed repos are stored via `serializeAttachment`/`deserializeAttachment` and survive hibernation.

### SQLite Schema

```sql
CREATE TABLE events (
  id           TEXT PRIMARY KEY,       -- UUIDv4
  type         TEXT NOT NULL,          -- GitHub event type (pull_request, check_run, etc.)
  action       TEXT NOT NULL,          -- Event action (opened, completed, etc.)
  summary      TEXT NOT NULL,          -- Human-readable summary
  repo         TEXT NOT NULL,          -- Full repo name (owner/repo)
  payload      TEXT,                   -- Full GitHub webhook payload (JSON)
  idempotency_key TEXT NOT NULL,       -- Canonical payload hash; suppresses duplicate deliveries
  delivery_id  TEXT,                   -- X-GitHub-Delivery header (for tracing)
  sender       TEXT,                   -- GitHub login of the actor
  clients_sent INTEGER NOT NULL DEFAULT 0,  -- WebSocket clients that received the broadcast
  created_at   INTEGER NOT NULL        -- Unix timestamp (ms)
);
CREATE INDEX idx_events_created ON events(created_at);
CREATE UNIQUE INDEX idx_events_idempotency_key ON events(idempotency_key);
```

**Retention**: Events older than 7 days are pruned on each webhook insert.

**Idempotency**: duplicate webhook payloads are ignored using a canonical payload hash, so retries and repeated deliveries do not appear twice in catch-up or live broadcasts.

**Migration**: Schema is forward-migrated via `PRAGMA table_info` introspection — new columns are added idempotently on DO construction, legacy rows are backfilled with idempotency keys, and existing duplicates are pruned before the unique index is enforced.

### Structured Logging

All logs are JSON with a consistent shape: `{ level, msg, ts, ...context }`.

**Privacy rule**: Never log tokens, JWTs, email addresses, or IP addresses. Safe to log: login, repo, owner, event_type, delivery_id, status codes, counts.

**Router logs** (`index.ts`):

| msg | When | Context |
|-----|------|---------|
| `auth_session_created` | JWT issued | login, orgs_count |
| `auth_session_*` | Auth failures | login (if available), status |
| `webhook_received` | Valid webhook forwarded to DO | delivery_id, event_type, repo |
| `webhook_*` | Webhook rejected | delivery_id, event_type |
| `ws_connect` | WebSocket connected | owner, login, repos_count |
| `ws_*` | WebSocket auth rejected | owner, login |

**Durable Object logs** (`webhook-relay.ts`):

| msg | When | Context |
|-----|------|---------|
| `do_event_stored` | Event inserted + broadcast | event_id, delivery_id, event_type, action, sender, repo, clients_sent, total_clients |
| `do_event_duplicate_ignored` | Duplicate payload dropped | delivery_id, event_type, action, repo |
| `do_event_duplicates_pruned` | Legacy duplicates removed during migration | count |
| `do_ws_connected` | New WebSocket accepted | catchup_count, total_clients |
| `do_ws_closed` | WebSocket disconnected | code, remaining_clients |
| `do_ws_error` | WebSocket error | detail |
| `do_events_pruned` | Old events deleted | count |

## Key Files

| File | Purpose |
|------|---------|
| `NotificationConstants.swift` | Single source of truth: base URL, client ID, keychain keys |
| `NotificationCoordinator.swift` | `@MainActor ObservableObject` — owns auth state machine + stream lifecycle |
| `EventStreamService.swift` | Actor — WebSocket client with reconnect logic |
| `GitHubDeviceAuth.swift` | Actor — GitHub Device Flow (RFC 8628) |
| `NotificationSessionService.swift` | Actor — exchanges GitHub token for JWT |
| `KeychainHelper.swift` | Keychain CRUD for secure token storage |
| `WebhookEvent.swift` | `Codable` + `Sendable` event model |
| `Protocols.swift` | `EventStreamServiceProtocol`, `NotificationCoordinatorProtocol`, `NotificationAuthState` |
| `infra/cloudflare-webhook-relay/` | Cloudflare Worker + Durable Object |

## JWT Refresh

The JWT expires after 8 hours. The coordinator silently refreshes it using the stored GitHub token:

1. `scheduleRefresh()` fires 15 minutes before expiry (parsed from the JWT `exp` claim)
2. `refreshJWT()` calls `POST /auth/session` with the stored GitHub token to get a new JWT
3. On success, the WebSocket reconnects with fresh credentials without clearing the event list
4. On failure, the user is signed out

The refresh-driven reconnect checks `NotificationConstants.enabledKey` before reconnecting, so disabling notifications in Settings prevents the socket from being re-established by a background refresh.

## Local Development & Testing

The notification pipeline can be tested entirely locally without hitting production GitHub.

### E2E Tests

```bash
cd infra/cloudflare-webhook-relay
bun install          # first time only
bun run test:e2e     # runs mock GitHub API + wrangler dev + 11 behavior-level scenarios
```

The harness automatically:
- Kills stale processes from previous runs on ports 8787/8788
- Starts a mock GitHub API on port 8788
- Starts `wrangler dev` on port 8787 (reads `.dev.vars` for secrets)
- Runs 11 behavior-level tests covering health, auth, catchup, live broadcast, duplicate suppression, payload-order invariance, distinct-event preservation, restart persistence, legacy duplicate cleanup, and per-client repo filtering
- Cleans up all processes on exit

### How It Works

The Worker's GitHub API calls are routed through a configurable base URL:

| Binding | Default | Local |
|---------|---------|-------|
| `GITHUB_API_BASE` | `https://api.github.com` (production) | `http://127.0.0.1:8788` (via `.dev.vars`) |

`.dev.vars` (gitignored) provides test secrets and the mock API URL:
```
GITHUB_WEBHOOK_SECRET=test-webhook-secret-e2e
JWT_SIGNING_SECRET=test-jwt-secret-e2e
GITHUB_API_BASE=http://127.0.0.1:8788
```

The mock GitHub API (`test/mock-github.ts`) responds to the 4 endpoints the Worker calls, with token-dependent behavior for testing different auth scenarios:

| Token | Behavior |
|-------|----------|
| (any) | Full access: 2 repos, valid installation |
| `ghp_no_install` | No GitHub App installation (triggers 403) |
| `ghp_repo_b_only` | Only sees `repo-b` (tests per-client filtering) |

### Testing Swift App Against Local Worker

```bash
cd infra/cloudflare-webhook-relay && bun run dev   # terminal 1
WORKSPACES_NOTIFICATION_URL=http://localhost:8787 ./scripts/launch-dev.sh --no-build  # terminal 2
```

`WORKSPACES_NOTIFICATION_URL` overrides `NotificationConstants.baseURL` — follows the existing `WORKSPACES_*` env var pattern.

## Known Gaps (Future Work)

1. **Org repo pagination**: `fetchAccessibleRepos` fetches one page (100 repos). Orgs with more repos need pagination support.

## GitHub App

- **App name**: WorkSpaces Notify
- **Client ID**: `Iv23liJBRgQoWIWjtRoO` (in `NotificationConstants.gitHubAppClientID`)
- **Subscribed events**: pull_request, discussion, discussion_comment, check_run, check_suite
- **Webhook URL**: `https://webhooks.cloudcompute.com/webhook`

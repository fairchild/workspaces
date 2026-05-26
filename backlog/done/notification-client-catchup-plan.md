---
status: done
issue: 547
completed: 2026-05-25
resolution: promoted-to-github-issue
category: plan
pr: null
branch: null
score: null
retro_summary: null
---

# Per-Client Notification Catch-Up

## Problem Statement

The notification pipeline currently stores events and tracks only aggregate fanout. The Durable Object keeps `clients_sent` on each event and filters live delivery by `allowedRepos`, but it does not know which specific client has already processed which event.

That is enough for the current "send recent 50 on connect" behavior, but it is not enough to resume cleanly after reconnects, app relaunches, or network drops. A reconnecting client can receive duplicates, and a fresh install is indistinguishable from a previously-connected client on the same machine.

We do not need a full per-event delivery audit table for this product. The target is a lighter catch-up model: each client keeps a durable cursor, the Worker sends only events newer than that cursor, and the client periodically acknowledges progress.

## Why We Explored This

- Current reconnect behavior is coarse and stateless.
- The org-level WebSocket model is already in place, so catch-up should fit that topology rather than adding a second delivery system.
- Per-client resume is useful for reliability, but a full delivery ledger would add more storage and protocol complexity than this app needs.

## Why Deferred

- This touches the Worker protocol, Durable Object schema, and the macOS client at the same time.
- The current aggregate approach works well enough for initial rollout.
- The simpler cursor design should be captured deliberately instead of folded into unrelated notification fixes.

## What We Learned

- Current event storage is in `infra/cloudflare-webhook-relay/src/webhook-relay.ts`.
  - `events` stores aggregate delivery via `clients_sent`.
  - `handleWebSocketUpgrade()` sends a recent catch-up batch immediately.
  - `webSocketMessage()` is currently a no-op, so the client has no ACK path.
- Current auth and per-client repo filtering are in `infra/cloudflare-webhook-relay/src/index.ts`.
  - The Worker already computes `allowedRepos` per connection and forwards that allowlist into the Durable Object.
- Current macOS stream handling is in `Sources/WorkspaceManagerCore/Services/EventStreamService.swift`.
  - The client only receives messages today.
  - There is no stable client identity and no outbound ACK message.
- `NotificationCoordinator` in `Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift` is the right orchestration point for persisted notification auth/session state.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Tracking goal | Resume/catch-up only | Exact delivery audit is not needed for this feature |
| Client identity | Persist a stable `client_id` per app install | Lets reconnects and relaunches resume from prior progress |
| Scope | Owner-scoped cursor | Matches the current `/ws/{owner}` Durable Object topology |
| Ordering key | Add a monotonic event sequence | Simpler and safer than relying on timestamps for resume |
| Server state | Store one cursor row per client | Avoids `events x clients` storage growth |
| ACK semantics | Client ACKs highest contiguous processed sequence | Idempotent, compact, and easy to batch |
| Fresh client behavior | Keep the current "recent N events" seed | Avoids replaying full retained history for a brand-new install |
| Repo filtering | Continue filtering by `allowedRepos` for both catch-up and live events | Preserves the current security model |

## Options Considered

| Option | Summary | Pros | Cons | Recommendation |
|--------|---------|------|------|----------------|
| Full delivery ledger | Persist one row per `event_id x client_id` and track ACKs | Exact audit trail and observability | Higher write volume, more schema and cleanup work | Reject |
| Client cursor catch-up | Persist only the highest acknowledged event sequence per client | Smallest state, enough for resume/dedupe | No exact audit trail | Chosen |

## Architecture

```text
GitHub webhook
  -> owner Durable Object
      -> store event(sequence, repo, payload...)
      -> send live event to connected sockets filtered by allowedRepos

macOS app
  -> persists stable client_id
  -> connects with Authorization + X-GitHub-Token + X-Client-ID

owner Durable Object on connect
  -> load last_acked_sequence for client_id
  -> query events newer than cursor and allowed for this client
  -> send catchup batch ordered by sequence ascending

macOS app after processing events
  -> send { type: "ack", sequence: highestProcessedSequence }

owner Durable Object on ack
  -> upsert client cursor
```

## Proposed Data Model

### Durable Object tables

Reuse the existing `events` table, but add a monotonic ordering column:

```text
events
- id TEXT UNIQUE
- sequence INTEGER UNIQUE NOT NULL
- type TEXT NOT NULL
- action TEXT NOT NULL
- summary TEXT NOT NULL
- repo TEXT NOT NULL
- payload TEXT
- delivery_id TEXT
- sender TEXT
- clients_sent INTEGER NOT NULL DEFAULT 0
- created_at INTEGER NOT NULL
```

Add one small cursor table per owner-scoped Durable Object:

```text
client_cursors
- client_id TEXT PRIMARY KEY
- last_acked_sequence INTEGER NOT NULL
- updated_at INTEGER NOT NULL
```

Notes:

- Because the Durable Object is already keyed by owner, `owner` does not need to be stored in `client_cursors`.
- `client_cursors` is intentionally compact. It tracks position, not a delivery ledger.
- If adding `sequence` to `events` is too invasive, an internal SQLite `rowid` cursor is a fallback, but an explicit sequence is easier to reason about and test.

## Protocol Shape

### Connect request

Headers:

- `Authorization: Bearer <jwt>`
- `X-GitHub-Token: <github-token>`
- `X-Client-ID: <stable-client-id>`

### Server -> client messages

Catch-up batch:

```json
{
  "type": "catchup",
  "events": [
    {
      "id": "uuid",
      "sequence": 1234,
      "type": "pull_request",
      "action": "opened",
      "summary": "PR #12 opened by alice: Fix auth",
      "repo": "owner/repo",
      "timestamp": 1741450000000
    }
  ],
  "historyTruncated": false
}
```

Live event:

```json
{
  "type": "event",
  "event": {
    "id": "uuid",
    "sequence": 1235,
    "type": "discussion",
    "action": "created",
    "summary": "Discussion #8 created by bob: Release plan",
    "repo": "owner/repo",
    "timestamp": 1741450001000
  }
}
```

### Client -> server messages

ACK:

```json
{
  "type": "ack",
  "sequence": 1235
}
```

Rules:

- ACKs must be monotonic per client.
- The client should ACK only after the event has been accepted into local app state.
- ACKs are idempotent: replaying the same or older sequence should be ignored safely.

## Behavior Rules

### New client

- If `client_id` has no cursor row, treat it as a fresh client.
- Send the existing recent catch-up window instead of replaying all retained events.
- Start tracking the cursor only after the first ACK arrives.

### Returning client

- Send events with `sequence > last_acked_sequence`, filtered by `allowedRepos`.
- Preserve ascending sequence order in catch-up so the app can process deterministically.

### Retention gaps

- If the stored cursor is older than the oldest retained event, send the available retained window and mark `historyTruncated = true`.
- Log the gap server-side for debugging.
- The app can optionally surface a low-priority "older activity unavailable" hint later, but that is not required for the initial implementation.

### Repo access changes

- Continue to apply the current `allowedRepos` filter to both catch-up and live delivery.
- If a client loses access to a repo, older events from that repo should no longer be replayed on reconnect.
- Cursor state remains owner-scoped. It should not be reset just because the repo allowlist changes.

## Implementation Phases

### Phase 1: Client Identity and Protocol Contract

**Files to modify:**

- `Sources/WorkspaceManagerCore/Services/NotificationConstants.swift` - add a key for persisted `client_id`
- `Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift` - load or create the stable client identity
- `Sources/WorkspaceManagerCore/Services/EventStreamService.swift` - send `X-Client-ID` during connect and support outbound ACK messages
- `infra/cloudflare-webhook-relay/src/index.ts` - validate and forward `X-Client-ID`

**Acceptance criteria:**

- [ ] Each app install has one stable `client_id`.
- [ ] Reconnects reuse the same `client_id`.
- [ ] Missing `X-Client-ID` is rejected clearly by the Worker.

### Phase 2: Durable Object Cursor Storage

**Files to modify:**

- `infra/cloudflare-webhook-relay/src/webhook-relay.ts` - add `client_cursors` table and event sequence handling

**Acceptance criteria:**

- [ ] The Durable Object can load and update a cursor per `client_id`.
- [ ] Event ordering for catch-up uses a monotonic key, not just timestamps.
- [ ] Catch-up queries remain filtered by `allowedRepos`.

### Phase 3: ACK Flow and Resume Logic

**Files to modify:**

- `Sources/WorkspaceManagerCore/Services/EventStreamService.swift` - send ACKs after accepted events
- `Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift` - decide ACK cadence and sequencing
- `infra/cloudflare-webhook-relay/src/webhook-relay.ts` - process ACK messages and upsert cursor rows

**Acceptance criteria:**

- [ ] A reconnecting client receives only events newer than its acknowledged cursor.
- [ ] Duplicate ACKs do not corrupt cursor state.
- [ ] A fresh client still gets a bounded recent catch-up window.

### Phase 4: Tests and Observability

**Files to create:**

- `infra/cloudflare-webhook-relay/test/client-catchup.test.ts` - Worker/DO catch-up behavior
- `Tests/WorkspaceManagerTests/EventStreamServiceCatchupTests.swift` - client wire protocol and ACK behavior

**Files to modify:**

- `infra/cloudflare-webhook-relay/src/log.ts` - add structured logging around cursor load, ACK update, and retention gaps

**Acceptance criteria:**

- [ ] Tests cover fresh-client connect, returning-client reconnect, and repo-filtered catch-up.
- [ ] Logs show `client_id`, cursor movement, and retention-gap cases without logging secret credentials.

## Verification Commands

```bash
swift test
cd infra/cloudflare-webhook-relay && bunx tsc --noEmit
```

Manual verification:

1. Sign in, connect, and receive live events for an org.
2. Disconnect the app, emit several webhook events, reconnect, and verify only unseen events are replayed.
3. Reconnect a second time without new events and verify the catch-up batch is empty.
4. Change the allowed repo set and verify both live and catch-up delivery still respect filtering.

## Rollback Plan

- Remove `X-Client-ID` enforcement and ACK handling from the Worker.
- Ignore `client_cursors` and fall back to the current "send recent 50 on connect" behavior.
- Keep `clients_sent` aggregate tracking unchanged so the existing stream remains operational during rollback.

## References

- `infra/cloudflare-webhook-relay/src/index.ts`
- `infra/cloudflare-webhook-relay/src/webhook-relay.ts`
- `Sources/WorkspaceManagerCore/Services/EventStreamService.swift`
- `Sources/WorkspaceManager/Views/MainWindow/NotificationCoordinator.swift`
- `docs/development/notifications.md`

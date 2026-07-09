# web-next local schema

The durable data foundation for sessions-first web. Fresh schema (no legacy
`chat_messages` compatibility); only the Kysely/libSQL *setup* is ported by copy
from the old `web/` app (idempotent append-only migrations, the libSQL dialect,
the Turso row-read discipline).

- **Engine:** libSQL / Turso (SQLite dialect) via Kysely.
- **Migrations:** ordered, append-only in `src/lib/db/migrations.ts`; applied by
  `ensureSchema()` (`src/lib/db/schema.ts`), which records each id in
  `schema_migrations`. Never edit a shipped migration — append a new one.
- **Row types:** the `Database` interface in `src/lib/db/client.ts`.
- **Store API:** `src/lib/db/sessions.ts` (create/read/list sessions,
  append/read events, project a transcript), `src/lib/db/repos.ts`
  (list/ensure connected repos), `src/lib/db/start-session.ts` (the
  new-session write path).

Keep this doc in sync with the migrations whenever tables, indexes, or persisted
meanings change.

## Tables

### `repos`

A connected GitHub repo a session can run against. Minimal by design — the
sessions home (#747) and lifecycle work extend it as needed.

| Column | Type | Meaning |
|---|---|---|
| `id` | text PK | Stable repo id (GitHub node id or `owner/name`); referenced by `sessions.repo_id`. |
| `full_name` | text | `owner/name`, the human-facing identifier. |
| `default_branch` | text? | Branch a new session checks out; null until known. |
| `created_at` | text | ISO-8601. |

### `sessions`

One coding session — the primary object of the app. A session owns an
append-only `session_events` log; its UIMessage transcript is **projected** from
that log, never stored here.

| Column | Type | Meaning |
|---|---|---|
| `id` | text PK | Session id. |
| `repo_id` | text? | `repos.id` this session runs against; null until bound. |
| `owner_login` | text? | GitHub login that created the session; null for legacy grandfathered rows (migration `0006_session_owner_login`). |
| `title` | text | Display title; `""` until named. Auto-titled from the first user message's first line at turn-start (`titleSessionIfEmpty`, `src/lib/agent-runtime/turn-ingest.ts`, #823) via a `WHERE title = ''` conditional update — idempotent, and skipped when that line has no usable text (session stays untitled for a later turn). User edits go through `PATCH /api/sessions/[id]` (`updateSession`, unconditional) and are never overwritten by the auto-titler once set. Derivation rules (cleaning, length cap) live in `src/lib/session-title.ts`, shared by both paths. |
| `first_user_message` | text? | First user-authored text chunk, projected from `session_events` by migration `0007_session_first_user_message` and maintained by `appendEvents`. Used for cheap sessions-home search without per-row event-log reads. |
| `provider` | text | Compute provider id — `mock` \| `vercel` \| `anthropic` \| … |
| `status` | text | Lifecycle — `active` \| `idle` \| `archived` (owned by #749/#750). |
| `claude_session_id` | text? | Harness/Claude session id for resume; null until a real turn parks one. |
| `resume_state` | text? | JSON harness resume payload from the last turn's `detach()` (migration `0003_session_resume_state`); null until a real turn parks, cleared when the parked sandbox expires. Session-row state, deliberately not in the event log. |
| `model` | text | Claude model id this session's turns run on (migration `0004_session_model`, #824); NOT NULL, defaulting to `DEFAULT_MODEL` (`src/lib/agent-runtime/models.ts` — the single source of truth for the selectable set). Threaded into `TurnRequest.model` on every turn; changed via the status line's picker (`PATCH /api/sessions/[id]`). |
| `approval_policy` | text | Tool approval posture for provider turns (migration `0008_turn_approvals`, #982): `auto` (default), `ask-writes`, or `ask-all`. Providers use `src/lib/agent-runtime/approval-policy.ts` to classify tool names; the mock approval scenario opens a real broker request regardless of this default so the round trip is testable without credentials. |
| `created_at` | text | ISO-8601. |
| `last_activity_at` | text | ISO-8601; bumped on every event append. |

Index `idx_sessions_last_activity` on `last_activity_at desc` — the sessions
home lists by recency.

### `session_events`

The append-only transcript log — **the single source of truth** for a session's
transcript. Each row is one provider `StreamChunk` tagged with its turn role and
a per-session monotonic `seq`.

| Column | Type | Meaning |
|---|---|---|
| `session_id` | text | Owning session. |
| `seq` | integer | Per-session monotonic position, starting at 1. |
| `role` | text | Whose turn — `user` \| `assistant`. |
| `kind` | text | The StreamChunk `type` (`text` \| `tool_use` \| …), denormalized for cheap filtering/debugging. |
| `payload` | text | JSON-serialized `StreamChunk`. |
| `created_at` | text | ISO-8601. |

Primary key `(session_id, seq)`. This composite PK does double duty: it enforces
the monotonic cursor **and** lets the resume/tail query
`WHERE session_id = ? AND seq > ? ORDER BY seq` seek the index instead of
scanning the table — the Turso row-read lesson carried over from `web/`.
`seq` is the resume cursor #749's tail route reads.

### `turn_approvals`

The bidirectional approval rendezvous (#982). The transcript still records
approval requests and resolutions as provider-native `StreamChunk`s in
`session_events`; this side table is the mutable answer surface providers await
and answer routes update. The answer endpoint never appends to `session_events`.

Migration: `0008_turn_approvals`.

| Column | Type | Meaning |
|---|---|---|
| `session_id` | text | Owning session. |
| `request_id` | text | Provider-generated approval id; unique within the session. |
| `tool_name` | text | Tool that wants permission, e.g. `Edit` or `Bash`. |
| `input_summary` | text | Human-readable summary of the proposed tool input. |
| `requested_at` | text | ISO-8601 time the broker row was opened. |
| `expires_at` | text | ISO-8601 deadline; unanswered requests deny on timeout. |
| `decision` | text? | `allow` or `deny`; null while pending. |
| `decided_at` | text? | ISO-8601 answer time; null while pending. |
| `decided_by` | text? | `user`, `timeout`, or `abort`; null while pending. |

Primary key `(session_id, request_id)`. Index
`idx_turn_approvals_pending_expiry` covers per-session pending/expiry checks.

### `queued_messages`

Durable mid-turn steering queue (#984). Rows here are pending user text, not
transcript events: the running turn's ingest loop stays the only writer to
`session_events`, and the queued text is appended there only when the row is
claimed for dispatch as the next turn.

Migration: `0009_queued_messages`, `0010_queued_message_dispatch_order`.

| Column | Type | Meaning |
|---|---|---|
| `id` | integer | Monotonic insertion order; the dispatcher's strict FIFO key. |
| `session_id` | text | Owning session. |
| `queue_id` | text | Stable id used by the client to cancel/reconcile the row. |
| `text` | text | User text to dispatch next. |
| `queued_at` | text | ISO-8601 enqueue time for display/debugging. |
| `dispatched_at` | text? | Set when claimed for `startTurn`; null while pending. |
| `canceled_at` | text? | Set when canceled before dispatch. |

Primary key `id`; unique `(session_id, queue_id)`. Index
`(session_id, id)` serves the oldest-first queue read.

### Better Auth tables (`user`, `session`, `account`, `verification`)

Migration `0002_auth_tables` (#747) creates Better Auth's default sqlite
tables — camelCase columns, queried by Better Auth's own adapter, so they are
deliberately **not** in the Kysely `Database` type. One addition: `user.githubLogin`
(text, nullable), persisted from the GitHub OAuth profile at sign-in — it is
what the `ALLOWED_LOGINS` allowlist checks (emails can be private). Only used
in real-OAuth mode; the test bypass never touches these tables.

## Payload shape decision: store StreamChunk-shaped, project at read time

`session_events.payload` stores **provider-native `StreamChunk`s** (the universal
streaming unit every compute provider emits), not pre-adapted `UIMessageChunk`s.
The `StreamChunk → UIMessage` adapter runs at **read** time, inside the
projection.

Why store the raw provider events rather than the adapted form:

- **The log stays the true source of truth.** The plan makes `session_events`
  the single source of truth for the transcript; the raw provider stream is the
  most faithful record. UIMessages are a *view*.
- **Replay stays stable across adapter versions.** Tool-call pairing and text
  bracketing are a moving target (they live in `chunk-adapter.ts` and will grow:
  reasoning parts, richer tool metadata). Storing the adapted output would freeze
  historical transcripts at the adapter version that wrote them; a bug fix or new
  part type could never reach old sessions. Storing raw chunks means any log
  re-projects correctly under the current adapter — projection is a pure function
  re-runnable at any version.
- **Ingest stays a dumb append.** #749 ingests provider `StreamChunk`s into this
  table as they arrive (detached in the sandbox / Managed Agents session). Writing
  them verbatim keeps ingest simple and fast — no adapter on the hot write path;
  the adapter/pairing logic lives in exactly one place, on the read side.
- **One adapter, both paths.** Live streaming and stored replay run through the
  *same* `toUIMessageChunks` adapter, so a turn looks identical whether it's
  streaming live or replayed after a reconnect.

The cost — running the adapter on every read — is bounded and measured: the
`projection_200` perf scenario projects a 200-event log in ~13ms (budget 40ms).
If projection ever gets hot, a materialized-projection cache can sit *in front*
of this log without changing the source of truth.

## Projection

`projectSessionEvents(sessionId, events)` (`src/lib/transcript/project-events.ts`)
turns the log into the `UIMessage[]` a transcript renders. It **composes** the
existing adapter with the AI SDK's `readUIMessageStream` reducer:

```
events → group by role/turn → StreamChunk[] → toUIMessageChunks (adapter)
       → readUIMessageStream (reduce)        → UIMessage
```

- Consecutive `user` events → one user message (text concatenated).
- Each `assistant` turn (a run up to and including a `done` chunk) replays
  through the adapter and reduces to one assistant message. Transient `status`
  chunks and stream `error`s never break projection (dropped / surfaced
  out-of-band, per the adapter contract); an assistant turn with no renderable
  parts is omitted.
- **Deterministic:** same log in → same `UIMessage[]` out. Message ids are
  `${sessionId}:${firstSeq}`; assistant part ids are seeded from the message id
  (`…:p0`, `…:p1`), never randomized — which is what lets #749 resume a
  transcript from the DB alone.

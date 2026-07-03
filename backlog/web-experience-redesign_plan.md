# Web Experience Redesign — Sessions-First Greenfield Rewrite

Status: **active** — direction confirmed with Michael (2026-07-03): greenfield
rewrite, sessions-first, single-user product. Phase 0 shipped. **Design locked:
"Refined Folio"** (`prototypes/web-session-redesign/refine-folio.html`).
Execution is an autonomous milestone run — operating contract in
`backlog/web-next-execution-brief.md`, work tracked in the GitHub milestone
**"Sessions-first web (web-next)"**.

## Intent

The web app becomes a place you **enter a coding session** — the same feeling as
working with Claude Code in the terminal, but in the browser: a first-class chat
with a coding agent that can read, write, and run code in a live sandbox, with a
real terminal into that same sandbox one keystroke away, and a transcript that
survives closing the laptop. Monitoring (agent teams, pipeline, PR reviews)
remains, but as the secondary surface; the session is the product.

Test for done: from a phone or a fresh browser, sign in, open a recent session
(or start one on any connected repo), ask the agent to make a change, watch it
edit files and run tests as structured tool events — not a wall of text — and
come back an hour later to a transcript that caught up without losing the thread.

## Why (diagnosis of the current `web/` app)

- The IA is repo-and-monitoring-first. The prime use case — a session — has no
  first-class home; Chat and Terminal are two disconnected tabs that sometimes
  point at the same sandbox.
- Chat renders a coding agent as one growing text bubble: `tool_use` becomes a
  transient status label, `tool_result` is discarded. Nothing rich is persisted
  (`chat_messages` is flat text), so nothing can be replayed.
- Web chat is hard-wired to read-only tools; the runner's `full` mode
  (Write/Edit/Bash) has no UI entry point. You cannot actually code via web chat.
- The turn model fights long sessions: one 300 s SSE request per turn, sandbox
  snapshotted+killed after every turn.
- Structural noise: orphaned review-runs page, unused DispatchDialog, silent
  `catch {}` failures, 10 s polling, agent-identity slug hacks in the UI.

## Decisions (confirmed 2026-07-03)

1. **Session-first IA.** Sessions are the primary object: a home screen of
   active/recent sessions; "new session" picks a repo; entering one gives a
   unified chat + terminal + context workspace.
2. **Provider-pluggable runtime.** The session UI is written against the
   existing `ComputeProvider` / `StreamChunk` seam, not one backend.
   Vercel Sandbox and Anthropic Managed Agents are the two launch providers;
   Lume/local later. Capability flags (PTY? snapshot? max duration?) drive
   which affordances a session shows.
3. **Vercel AI SDK + AI Elements** for the chat/transcript layer: `useChat`
   transport, UIMessage message-parts model, AI Elements-style components for
   messages/tool cards/code blocks, restyled to our design system.
4. **Greenfield rewrite.** A new app is built from scratch in `web-next/`
   (renamed to `web/` at cutover) with its own Vercel project. The old app
   keeps running untouched — including its webhook intake and the managed PR
   reviewer — until the new app reaches cutover. Organs are **ported by copy**
   from `web/src/lib/` where they encode paid-for lessons (agent-runtime
   providers, Claude CLI sandbox auth via `env.sh`, base snapshots, ttyd
   ticket/HMAC terminal security); everything UI, schema, and route-level is
   designed fresh.
5. **Single-user product.** Michael is the only user. Auth stays (the app is
   internet-facing and holds GitHub tokens + sandbox access) but collapses to
   GitHub OAuth + a login allowlist. No multi-tenant authz matrix, no
   onboarding polish, no cross-tenant test suite, no data migration — the new
   DB starts empty and the repo list is re-picked once.

## Design defaults (standing unless vetoed)

- **Visual identity: keep the Spaces aesthetic** — Instrument Serif +
  JetBrains Mono, mint `#a6ffdf` on `#0e1117` — mapped onto Tailwind theme
  variables; soften noise/scanlines inside the transcript for readability.
- **Session layout: chat primary, terminal on demand.** The session is a
  transcript; a real PTY (ghostty-web) into the same sandbox opens as a
  collapsible drawer. Desktop split-view can come later.
- **Monitoring: sessions first.** The old dashboard keeps serving monitoring
  until a slim mission-control view is rebuilt late in the new stack.

## Target architecture

### Information architecture

- `/` — sessions home: active + recent sessions across repos (status, repo,
  provider, last activity), "New session" (repo picker → provider/agent).
  Single-user: no marketing landing; unauthenticated → sign-in.
- `/sessions/[id]` — the workspace: transcript (message parts + tool cards),
  compose bar, session header (repo, branch, provider, sandbox state,
  stop/resume), terminal drawer (PTY providers only), context rail later
  (diff, PRs).

### Durable, resumable turns (the heart of the work)

- **`session_events` table** — append-only structured event log per session
  (seq, session_id, part payload). The single source of truth for the
  transcript; UIMessages are projected from it. Designed fresh — no legacy
  `chat_messages` compatibility.
- **Detached execution**: the agent turn runs detached inside the sandbox (or
  as a Managed Agents session) and its `StreamChunk`s are ingested into
  `session_events`; the browser-facing route only **tails** the log (SSE with
  seq-based resume, AI SDK resumable stream on the client). Closing the tab
  never kills a turn; reconnect catches up. Route duration caps stop mattering.
- **Adapter**: `StreamChunk → UIMessage stream parts` (text, tool-input,
  tool-output, status). One adapter serves both providers. De-risked first
  (Phase 0) as a pure module with unit tests.
- **Session lifecycle**: sandbox stays alive across turns within a session;
  idle timeout → snapshot+pause (existing snapshot path); explicit
  resume/stop controls. `full` tools (Write/Edit/Bash) on by default —
  single-user, repo-scoped, network-allowlisted sandboxes.

### Ported vs fresh vs left behind

- **Ported by copy (with their tests where they exist)**: agent-runtime
  (`types.ts`, provider registry, `vercel-sandbox.ts`, `managed-agents.ts` +
  event mapping), terminal ticket/HMAC + ttyd/tmux logic, Better Auth + GitHub
  OAuth config, Kysely/libSQL setup.
- **Fresh**: all UI (Tailwind v4 + AI Elements-style components), schema
  (`sessions`, `session_events`, minimal `repos`), API routes, session
  orchestration (long-lived lifecycle replaces snapshot-per-turn
  `session-manager.ts`).
- **Left running in old `web/` until late**: webhook intake, managed PR
  reviewer, activity feed, dashboard/monitoring. Ported or re-pointed at
  cutover; the PR reviewer is the largest port and is explicitly its own
  phase, not a blocker for sessions.

## Phased plan (each phase ships to the new app's preview URL)

- **Phase 0 — Skeleton + adapter spike.** `web-next/` scaffold (Next 15, AI
  SDK, Tailwind v4, design tokens ported), the `StreamChunk → UIMessage`
  adapter as a pure unit-tested module, and a spike page streaming mock
  provider chunks through the adapter into `useChat` with tool-part rendering.
  Exit: streamed tool cards render in the Spaces skin.
- **Phase 1 — Durable transcript backend.** `session_events` schema +
  UIMessage projection; detached-runner ingest for vercel-sandbox; Managed
  Agents event ingest; tail route with seq resume; auth (GitHub OAuth +
  allowlist). Exit: a turn survives tab close/reopen; transcript replays
  from DB.
- **Phase 2 — The session surface.** Sessions home + `/sessions/[id]` with
  full transcript UI, new-session flow, full tools on, sandbox alive across
  turns with idle snapshot. Exit: a real coding session (edit + run tests)
  completed entirely via the new app.
- **Phase 3 — Terminal + lifecycle polish.** Terminal drawer (PTY attach to
  the session sandbox via ported ticket flow), pause/resume/stop controls,
  first-class error surfaces, mobile pass for the transcript.
- **Phase 4 — Cutover.** Point the production domain at the new app; port or
  re-home webhook intake, PR reviewer, and a slim mission-control view;
  retire the old `web/` (delete or archive) and rename `web-next/` → `web/`;
  rebuild the test LEDGER around the new surface.

## Risks

- **AI SDK protocol fit**: both providers must express cleanly as UIMessage
  parts — de-risked in Phase 0 before any UI investment.
- **PR reviewer port** is the long tail of cutover; mitigated by keeping the
  old app deployed as the webhook/reviewer backend indefinitely until its
  port is proven. Nothing in Phases 0–3 touches it.
- **Two apps sharing sandbox/token secrets** during the transition: separate
  Vercel projects, separate DBs; only provider credentials are shared.
- **Long-lived sandboxes cost more** than snapshot-per-turn: idle timeout +
  visible sandbox state + stop button keep it bounded; single user caps blast
  radius.

# Web Experience Redesign — Sessions-First

Status: **proposed** — direction confirmed with Michael (2026-07-03); four secondary
decisions below are recommendations awaiting sign-off before Phase 1 starts.

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

## Why (diagnosis of today's confusion)

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

## Decisions (confirmed)

1. **Session-first IA.** Sessions are the primary object: a home screen of
   active/recent sessions; "new session" picks a repo; entering one gives a
   unified chat + terminal + context workspace.
2. **Provider-pluggable runtime.** The session UI is written against the
   existing `ComputeProvider` / `StreamChunk` seam, not one backend.
   Vercel Sandbox and Anthropic Managed Agents are the two launch providers;
   Lume/local later. Capability flags (PTY? snapshot? max duration?) drive
   which affordances a session shows.
3. **Vercel AI SDK + AI Elements** for the chat/transcript layer: `useChat`
   transport, UIMessage message-parts model, AI Elements components for
   messages/tool cards/code blocks, restyled to our design system.

## Open questions (recommended defaults — confirm or veto)

1. **Rewrite flavor** — recommended: **strangler-fig in-place**. Same Next.js
   app, auth, DB, deployment, and `src/lib/` runtime; the new `/sessions`
   surface is built fresh (Tailwind v4 + shadcn/AI Elements coexisting with
   CSS Modules during transition) and the old Dashboard/Chat/Terminal tabs are
   **deleted** in the final phase — replace, not co-exist forever. A true
   greenfield skeleton re-learns paid-for lessons (Claude CLI auth in
   sandboxes, Turso quota limits, ttyd ticket/HMAC model, cross-tenant authz)
   for zero product gain and adds a dark period.
2. **Visual identity** — recommended: **keep the Spaces aesthetic** (Instrument
   Serif + JetBrains Mono, mint `#a6ffdf` on `#0e1117`), mapped onto
   Tailwind/shadcn theme variables; consider softening noise/scanlines inside
   the transcript for readability. Past prototypes that ignored the identity
   "felt wrong immediately".
3. **Session layout** — recommended: **chat primary, terminal on demand**. The
   session is a transcript; a real PTY (ghostty-web) into the same sandbox
   opens as a collapsible drawer/panel. Split-view can come later for desktop.
4. **Monitoring** — recommended: **sessions first, port monitoring later**. The
   old dashboard keeps running untouched while `/sessions` is built; a slim
   mission-control view is rebuilt in the new stack afterwards (aligns with
   roadmap item #680).

## Target architecture

### Information architecture

- `/sessions` — home: active + recent sessions across repos (status, repo,
  provider, last activity), "New session" (repo picker → provider/agent).
- `/sessions/[id]` — the workspace: transcript (AI Elements), compose bar,
  session header (repo, branch, provider, sandbox state, stop/resume),
  terminal drawer (PTY providers only), context rail later (diff, PRs).
- Old `/dashboard/*` untouched until Phase 4, then slimmed to mission control.

### Backend: durable, resumable turns (the heart of the work)

Today: turn = one ≤300 s SSE request; sandbox snapshot+stop per turn.
Target:

- **`session_events` table** — append-only structured event log per session
  (seq, session_id, part type, payload). The single source of truth for the
  transcript; replaces flat `chat_messages` for sessions. UIMessages are
  projected from it.
- **Detached execution**: the agent turn runs detached inside the sandbox (or
  as a Managed Agents session) and its `StreamChunk`s are written to
  `session_events` by a lightweight ingest path; the browser-facing route only
  **tails** the log (SSE with `Last-Event-ID`/seq resume, AI SDK resumable
  stream on the client). Closing the tab never kills a turn; reconnect catches
  up. The 300 s route cap stops mattering.
- **Adapter**: `StreamChunk → UIMessage stream parts` (text, tool-input,
  tool-output, status). One adapter serves both providers; `TranscriptTerminal`
  logic informs the tool-part rendering.
- **Session lifecycle**: sandbox stays alive across turns within a session;
  idle timeout → snapshot+pause (existing snapshot path); explicit
  resume/stop controls. `full` tools enabled for sessions (per-session toggle,
  default on; the sandbox is already network-allowlisted and repo-scoped).

### What stays / what goes

- **Stays untouched**: Better Auth + GitHub OAuth, Kysely/libSQL, provider
  registry + both providers, terminal ticket/HMAC + ttyd/tmux, PR reviewer
  subsystem, webhook relay, setup flow.
- **Extended**: schema (`session_events`, session metadata), session-manager
  (long-lived lifecycle), agent-stream route (replaced by tail route).
- **Deleted (Phase 4)**: dashboard-shell tabs, chat-panel/streaming-bubble,
  terminal-panel tab (canvas component is reused in the drawer), DispatchDialog,
  old `chat_messages` write path for sessions.

## Phased plan (each phase ships)

- **Phase 0 — Foundation + spike.** Add `ai`, AI Elements, Tailwind v4
  (scoped so CSS Modules keep working); map design tokens; throwaway
  `/sessions/spike` page proving StreamChunk→UIMessage adapter end-to-end
  against the mock provider. Exit: streamed tool cards render in our skin.
- **Phase 1 — Durable transcript backend.** `session_events` schema +
  projection to UIMessages; detached runner ingest for vercel-sandbox;
  Managed Agents event ingest; tail route with resume. Exit: a turn survives
  tab close/reopen; transcript replays from DB.
- **Phase 2 — The session surface.** `/sessions` home + `/sessions/[id]`
  chat with AI Elements (tool cards, code blocks, status), new-session flow,
  full tools on, sandbox alive across turns with idle snapshot. Exit: real
  coding session (edit + run tests) completed entirely via web chat.
- **Phase 3 — Terminal + lifecycle polish.** Terminal drawer (PTY attach to
  the session sandbox), pause/resume/stop controls, error surfaces (no more
  silent `catch {}` in the new surface), mobile pass for the transcript.
- **Phase 4 — Cutover.** Route `/dashboard` chat/terminal users to sessions;
  delete old tabs/components; rebuild slim mission-control (agent grid,
  pipeline, activity, review-runs links) in the new stack; reconcile
  `web/tests/LEDGER.md` (old behaviors retired, new ones added).

## Risks

- **AI SDK protocol fit**: our two providers must both express cleanly as
  UIMessage parts — de-risked in Phase 0 with the adapter spike before any UI
  investment.
- **Tailwind/CSS-Modules coexistence**: scope Tailwind preflight to the new
  surface to avoid restyling the legacy dashboard accidentally.
- **Long-lived sandboxes cost more** than snapshot-per-turn: idle timeout +
  visible sandbox state + stop button keep it bounded.
- **Full tools on a web surface**: sandbox is already repo-scoped,
  network-allowlisted, token-scrubbed; keep the per-session toggle and audit
  trail via `session_events`.

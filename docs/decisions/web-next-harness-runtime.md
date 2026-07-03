# ADR: AI SDK Harnesses as the web-next session runtime

- Status: **Accepted** (2026-07-03)
- Scope: `web-next/` (the sessions-first web rewrite)
- Related: `backlog/web-experience-redesign_plan.md` (PRD), `backlog/web-next-execution-brief.md` (operating contract)

## Context

web-next is a browser coding-session experience: chat with an agent that reads,
writes, and runs code in a cloud sandbox, rendered in the Folio design system via
`useChat`. A stated goal is running **Claude Code, Codex, and Pi** through one
surface.

The original plan hand-built the runtime layer: a `StreamChunk → UIMessage`
adapter (Phase 0), a ported Vercel-Sandbox provider that parses
`claude -p --output-format stream-json`, bespoke durable/resumable turns, and a
re-solve of Claude Code CLI auth inside the sandbox (the last cost the current app
four PRs). Mid-plan, Vercel shipped **`@ai-sdk/harness`** — an official,
`ai@7`-native abstraction that provides exactly this layer, multi-runtime, with
sandbox auth handled. Verified 2026-07-03: the packages are real
(`@ai-sdk/harness`, `-claude-code`, `-codex`, `-pi`, `@ai-sdk/sandbox-vercel`),
pin `ai@7.0.14`, and forward host `ANTHROPIC_API_KEY`/gateway credentials into the
sandbox bridge for us. They are also explicitly **experimental** — ~4 weeks old,
tens of releases per month, a `1.0` label that overstates stability.

## Decision

Adopt `@ai-sdk/harness` as the web-next **session runtime**, **behind a thin,
app-owned `SessionRuntime` interface**, with **exact-pinned** versions.

- **The harness owns:** stream → UIMessage projection (`toUIMessageStream`),
  sandbox provisioning + Claude Code/Codex/Pi CLI auth, multi-runtime dispatch,
  between-turn resume (`detach()`/`resumeFrom`) and long-turn continuation
  (workflow slicing).
- **We own:** the `SessionRuntime` interface that wraps it; transcript
  persistence (stored UIMessages + the opaque `resumeFrom` blob, keyed by
  session) for reload replay; the reconnect policy; the terminal PTY drawer (run
  ttyd on a sandbox port via the shared-sandbox pattern — the harness provides no
  terminal, and `@ai-sdk/tui` is a Node dev renderer, not a browser PTY); the
  Folio UI; auth + allowlist.

The custom Phase 0 `StreamChunk → UIMessage` adapter is retired from the critical
path (kept only as a reference for adapting any future non-harness stream).
Managed Agents leaves web-next scope (it is not a harness).

### v1 scope decision — reconnect

The harness gives between-turn resume and server-side long-turn continuation, but
**no tail into an in-flight turn**. For v1 that is acceptable: a turn keeps
running server-side; on reconnect we re-attach or replay the completed transcript.
True mid-turn live tail is deferred until use shows it matters.

## Consequences

**Gains** — removes the two pieces that actually hurt (the custom adapter and
Claude Code sandbox auth), deletes the `stream-json` parsing risk, and delivers
Claude Code + Codex + Pi near-free (the three-runtime goal). The backend tickets
shrink and de-risk; we can stream a *real* provider from the first slice instead
of a long mock phase.

**Costs / risks** — a load-bearing dependency on an explicitly experimental,
fast-churning API. Mitigations: (1) the thin `SessionRuntime` interface keeps the
API from leaking app-wide and preserves an exit to a hand-rolled provider; (2)
exact-pin every `@ai-sdk/harness*` / `@ai-sdk/sandbox-*` version and upgrade
deliberately; (3) a harness spike de-risks it before the milestone commits; (4)
single-user means a breaking change is a controlled upgrade, not an incident.

**Not covered by the harness (stays ours):** renderable transcript store,
mid-turn live reconnect, terminal.

## Alternatives considered

- **Hand-roll providers + our own adapter** (full control, stable deps) —
  rejected: strictly more work, re-earns already-solved pain (sandbox auth), and
  still owes Codex/Pi from scratch.
- **Wait for the harness to stabilize** — rejected: the thin-interface + pin
  mitigates the risk, and the payoff (auth + three runtimes) is available now.
- **Build directly on the harness, no interface** — rejected: an experimental API
  would leak into every surface with no exit.

## Exit strategy

If the harness API breaks unacceptably, implement `SessionRuntime` with a
hand-rolled harness/provider (the original plan) without touching the UI,
persistence, or terminal layers.

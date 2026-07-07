# Terminal access model (#752)

The terminal drawer on `/sessions/[id]` puts a real shell into the **same
Vercel sandbox the session's turns run in** — the shared-sandbox pattern. This
doc is the security-relevant contract; the code lives in
`src/lib/terminal/` and `src/app/api/sessions/[id]/terminal/`.

## The three gates

A terminal connection passes three independent gates, in order:

1. **App auth.** Both terminal routes run the same `getAuthState()` allowlist
   verdict as the chat routes (middleware freshness alone is not enough for a
   sandbox-touching route). Signed out → 401/redirect at the edge; signed in
   but not allowlisted → 403.
2. **A single-use ticket.** `POST /api/sessions/[id]/terminal` mints 32
   random bytes (base64url) with a 30s TTL, stored as a SHA-256 digest
   (`terminal_tickets`) bound to the login, the session, and the sandbox name
   it was resolved against. `POST .../terminal/redeem` consumes it exactly
   once — an atomic UPDATE guard settles concurrent redeems to one winner —
   and re-checks all three bindings plus expiry. The ticket travels only in
   POST bodies; no URL (page, API, or asset) ever carries it.
3. **The ttyd path token.** The sandbox's shell is served by ttyd behind
   `--base-path /<token>`, where the token is 24 hex chars of
   HMAC-SHA256(secret, sandbox VM session id). Browsers can't attach headers
   to a WebSocket, so a path segment is the strongest gate ttyd offers; the
   token is derived (never stored), scoped to one VM (a new VM session under
   the same sandbox name gets a new token), and dies with the sandbox
   (≤ 30 min). Guessing a sandbox name reveals nothing connectable without
   the server-side secret.

Secret resolution: `TTYD_TOKEN_SECRET`, falling back to `BETTER_AUTH_SECRET`
(prod always has the latter — the #857 lesson), with a dev-only constant
outside production and a hard refusal in production when neither is set.

## Sandbox attachment

`resolveLiveSandbox` derives the sandbox name from the session's **own**
parked harness handle (`sessions.claude_session_id` →
`ai-sdk-harness-session-<id>`, the exact derivation the turn resume path
uses) — there is no request parameter that can point it at another session's
sandbox. The lookup is attach-only (`resume: false`): opening the drawer
never boots or resumes a VM. Sessions with no live sandbox (never ran a
turn, sandbox expired/stopped, or a sandbox from before `TERMINAL_PORT` was
declared) get a calm `no-sandbox` state; the honest affordance is starting a
turn, which boots the sandbox the terminal then attaches to.

The shell is `tmux new-session -A -s shell` in the session's workspace
clone, so disconnect/reconnect within one sandbox lands back in the same
shell state. ttyd + tmux are static binaries baked into the sandbox
template's bootstrap (best-effort, so a fetch failure never blocks the chat
path); the mint route re-runs the same idempotent install as a fallback for
sandboxes built from older templates.

## The mock PTY seam

Under `AUTH_BYPASS` (e2e, perf) the mint resolves mode `"mock"`: the full
ticket exchange still runs, but the client attaches a deterministic
in-browser PTY sim (`src/components/terminal/mock-pty.ts`) instead of a
WebSocket. Playwright and the `terminal_drawer_interactive` perf scenario
stay hermetic — no sandbox, no credentials — while exercising the real
drawer, terminal rendering, and both auth gates.

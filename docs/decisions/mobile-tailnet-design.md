# ADR: Mobile Variant over Tailnet — Direct-to-Node Control Plane

## Status

Accepted 2026-08-30, after a multi-day design session and an adversarial review
that verified every load-bearing claim against the tree. Nothing below is
implemented yet; issue #721 is rewritten as the umbrella tracking execution.

**Staleness test:** if `rg WEB_NEXT_EXTRA_LOCAL_ORIGINS web-next/src` matches,
Phase 1 has landed. If `HOST_ALLOWED_TOOLS` in
`web-next/src/lib/agent-runtime/host-provider.ts` includes a write tool,
Phase 3 has landed and the "read-only host lane" statements here are history.

- Scope: the WorkSpaces mobile variant, `web-next/` server changes it needs,
  and the agent-host contract both variants speak
- Supersedes: the approach described in issue #721 (predates host compute,
  targets maintenance-mode `web/`, assumes server-side ranking and a
  "desktop sync" that was never built)
- Related: `automation-operator-scope.md` (surface order and the verb-layer
  boundary), `../../web-next/docs/decisions/embedded-native-contract.md`
  (the desktop variant is already a client of the same server),
  `../../web-next/docs/decisions/host-compute-daily-driver.md`

## Context

The macOS app's control surfaces are deliberately local: the Automation API is
a `0600` Unix socket whose trust model is same-user filesystem permissions, and
web-next's owner-local mode binds `127.0.0.1` behind an exact-match loopback
Host gate. Both are meaningless or hostile off-device — which is correct for
what they are, and useless from a phone.

The product need: see and steer agent sessions from a phone, on any machine
that can run agents (Linux boxes included), for a self-hosted single owner —
with friends able to run their own stack. A live tailnet
(`tail3bb13.ts.net`, MagicDNS, HTTPS certs enabled) changes the shape of the
problem: the phone can talk **directly to the node running the turn**, which
dissolves the hazards a shared-cloud-database design would have had to solve
(false stale-turn closes across instances, steering misdirection,
non-functional stop) rather than solving them.

## Decision

**Invariant: no cloud in the control path.** Push notifications (APNs) are the
single deliberate exception and carry notifications only, never control.

The product presents as **one app — WorkSpaces, desktop and mobile variants** —
not a companion. Distribution cannot be unified: the desktop variant stays
Direct/notarized (the App Store sandbox forbids the shell execution the app is
built around), the mobile variant goes through TestFlight/App Store. Two App
Store Connect records agreeing on branding; never a universal purchase.

### Transport and authorization

- **Tailnet by default.** Each node fronts a loopback-bound service with
  `tailscale serve`. **LAN mode is the fallback** — an explicit, off-by-default
  mode that binds beyond loopback so someone without a tailnet can use it on
  shared wifi. Never a cloud relay; never bind `0.0.0.0` by default.
- **A per-node bearer token is always the gate** (the existing 32-byte
  `web-next` local sign-in token), transferred once by QR. ACL app-capability
  grants are a **second factor** where the tailnet supplies them — never the
  sole gate. Corollary, load-bearing: an identity header may be sole
  authorization **only** on a loopback-bound listener; anyone who can reach a
  non-loopback port can forge headers.
- **LAN mode ships HTTPS-pinned or not at all.** The QR carries
  `{url, token, cert fingerprint}` and the native client pins a self-minted
  certificate; LAN mode is therefore native-app-only (Safari cannot pin).
  Plain HTTP on shared wifi would expose a token that can run claude turns on
  the host, plus active JS injection into the served UI.
- The wide-open tailnet ACL (`src * / dst * / ip *` as of the 2026-07-10
  snapshot; admin console is source of truth) does **not** gate the MVP — the
  token authorizes. It gates the *grant* layer and must be tightened before
  grants mean anything. The tailnet is multi-user (other accounts, long-dead
  devices), so tightening scopes `src` to the owner and prunes stale nodes.
  Console work, owner-only.

### The agent-host contract

Nodes speak a small **agent-host contract** — identity, sessions, transcript,
steer, stop, start — with web-next as implementation one, defined as a
narrowed subset of what web-next already serves. `start` selects from repos
the node already knows, never an arbitrary filesystem path typed on a phone.
Two accidental webisms are excluded from the contract from day one:

1. **Auth is `Authorization: Bearer <token>` on every request.** The cookie
   dance (`/sign-in?token=` → redirect → cookie) remains as the browser
   convenience only.
2. **The stream vocabulary is an owned minimal enum** (seq, text, tool, error,
   done), not the ai-sdk `UIMessageChunk` union — with golden transcript
   fixtures that every implementation replays in its tests.

Capabilities are discovered via a new `/api/node` endpoint
(`{node, version, capabilities[]}`). `/api/healthz` stays exactly
`{ok, localMode}` — it is test-locked as the embedded-native readiness probe
and is never extended.

### Discovery, aggregation, clients

- **Discovery:** a manual node list bootstraps; the first reachable node
  serves the roster from `tailscale status --json` (shape already proven in
  `services/deploy/inventory/10_tailscale.py`); dedupe on FQDN. No public DNS.
- **Fleet** — an internal name, never user-facing — is a polling attention
  monitor on `orin` (`svc:fleet`; `svc:agents` is taken). It is an
  enhancement, never a dependency: the client degrades to a merged unranked
  list. `orin` is verified viable: Tailscale 1.102.2 (app-caps need ≥1.92),
  tagged `tag:server` — tags suppress `Tailscale-User-*` identity headers but
  not app-capability headers, which resolve from the packet filter by source
  IP.
- **Both variants are clients.** Shared DTOs live in a platform-neutral
  `WorkSpacesDomain` target in this repo; the iOS build is isolated from
  GhosttyKit (whose cache once poisoned the v0.23.0 release).
- **Session identity is namespaced by node from the first commit** — a
  client-side data-model choice (`(nodeURL, sessionId)` keys), free while one
  node exists, expensive to retrofit after two.
- Self-hosted client model: friends run their own node + tailnet. Multi-tenancy
  is never built (#829 stays parked). TestFlight, internal testers first; an
  in-app demo/mock node is required before the first **external** invite,
  because Beta App Review cannot reach a tailnet.
- Whether the mobile variant ever drives the desktop automation verb layer
  stays deliberately open; the capability model holds that door open at no
  cost, and `automation-operator-scope.md`'s boundary stands — no new verb
  semantics or trust surface from the mobile side.

### Security conditions that must hold from the first commit

1. Never let an identity header be the sole gate on a non-loopback listener.
2. Keep the Host allowlist **exact-match** (env-driven additions included) —
   never a wildcard on `.ts.net`.
3. Namespace session identity by node, even while one node exists.

## Sequence

1. **Phase 0 — record** (this ADR, #721 rewrite, child issues).
2. **Phase 1 — MVP, days:** streaming-through-`serve` probe first; Host-gate
   env hook (`WEB_NEXT_EXTRA_LOCAL_ORIGINS`, exact-match, inert unless set,
   honoring `X-Forwarded-Proto` — `loopbackHostOrigin` hardcodes `http://`
   today and the sign-in redirect builds from it); Read-tool jail probe (can
   the read-only host lane escape the workspace root under `--safe-mode` +
   `dontAsk`? verdict recorded here); runbook; verify from the phone.
3. **Phase 2 — tighten + contract:** ACL (owner, console), `/api/node`,
   bearer-header auth, contract doc + golden fixtures, roster endpoint.
4. **Phase 3 — host lane grows writes + approvals.** The host lane is
   read-only today (`--tools Read,LS,Glob,Grep,TodoRead --permission-mode
   dontAsk --safe-mode`) and never raises an approval; until this arc lands,
   the phone is a viewer with steering. "Approve from the couch" depends on
   this, not on the app.
5. **Phase 4 — native app:** `WorkSpacesDomain`, iOS shell, QR pairing,
   TestFlight internal; LAN mode (HTTPS, pinned) lands here, native-only.
6. **Phase 5 — slow burn:** Fleet on `orin`, APNs push, demo node, verb-layer
   decision from experience.

## Consequences

- The Mac must be awake and reachable for its sessions to be visible; that
  matches when its agents run at all.
- Token lifecycle is deliberately simple: one static token per node, `0600`
  on disk; rotation = delete the file and restart the server. Documented,
  not automated.
- The cloud lane (`folio.cloudcompute.com`, Vercel provider) is untouched and
  out of scope: it already has a URL a phone can reach.
- Every future node implementation inherits the contract's bearer auth and
  owned stream enum; web-next's cookie flow and ai-sdk internals stay
  implementation details behind it.

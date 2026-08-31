# Mobile pairing — isolation and disable contract

Mobile pairing (the QR window, tailnet reachability, and the pairing
handshake) is deliberately isolated so a deployment that does not want remote
connectivity can turn it off at three depths. With the feature off at any
depth, the embedded web-next server is loopback-only and the desktop app
exposes no pairing surface — byte-identical behavior to a build that never
had the feature.

**Enabled is not exposed.** The gate below controls whether the pairing
*surface* exists — not whether anything is reachable. The server binds
loopback either way; reaching it from another machine takes an operator act
the app never performs: running `tailscale serve` (or equivalent) in front of
that bind. A default-enabled build with no proxy in front is exactly as
reachable as a build compiled without the feature: not at all.

Once a proxy *is* configured, distinguish reachability from authorization. A
peer can then reach the unauthenticated surface — `/sign-in`, `/api/auth`,
`/api/healthz`, `/api/pairing/ack` — but every one of those either carries no
private data or authenticates itself with the minted token, and every other
path requires the session the token mints. Network position never authorizes;
a peer can send any `Host` header it likes, so no route may treat one as proof
of locality.

**Disabling is not revocation.** The gate is read when the app spawns its
web-next child, so flipping it (MDM, defaults, argument) applies to the next
launch. It does not tear down a running child or invalidate a phone already
holding the token — for that, stop the server and rotate the token by deleting
`local-sign-in-token` from the data dir.

**Staleness test:** `rg -l "MobilePairingFeature|WEB_NEXT_EXTRA_LOCAL_ORIGINS|parseExtraLocalOrigins|localRequestOrigin" Sources web-next scripts`
must list exactly the integration points named below; anything new must check
the same gates.

## Disable at runtime (operator / MDM)

Any one of, in precedence order:

1. Launch argument: `--disable-mobile-pairing`
2. Environment: `WORKSPACES_DISABLE_MOBILE_PAIRING=1`
3. Defaults (MDM-manageable): `defaults write <domain> mobilePairingEnabled -bool false`

All three feed `MobilePairingFeature.isEnabled`
(`Sources/WorkspaceManager/MobilePairing/MobilePairingFeature.swift`), the
single gate every desktop integration point checks.

Server-side, independently: the web-next child only ever accepts non-loopback
origins named in `WEB_NEXT_EXTRA_LOCAL_ORIGINS` (exact match, inert unless
set) — and the desktop app only sets it when the feature gate is on. No env
var, no remote reachability, regardless of what else runs.

## Disable in a fork (delete the code)

- `Sources/WorkspaceManager/MobilePairing/` — the whole desktop feature
- `web-next/src/app/api/pairing/` and `web-next/src/lib/pairing/` — the
  handshake routes and ack store
- `ios/` — the mobile client (a separate target; simply don't build it)

Integration points to unwind (each is a few lines, marked by the gate call):

- `Sources/WorkspaceManager/App/WorkspaceManagerApp.swift` — the
  `Window("Pair Mobile Device")` scene (SceneBuilder has no conditionals,
  so runtime-disabled shows a policy notice; forks delete the scene block)
- `Sources/WorkspaceManager/App/WebNextServerSettings.swift` — the
  `extraLocalOriginsProvider` closure (returns `[]` when gated off)
- `Sources/WorkspaceManagerCore/Services/WebNextServerService.swift` —
  `childEnvironment` (the sole authority: strips ambient
  `WEB_NEXT_EXTRA_LOCAL_ORIGINS` when the provider yields none, so an
  exported shell variable cannot re-enable the surface behind a disabled gate)
- `web-next/src/lib/auth/config.ts` — `parseExtraLocalOrigins` /
  `localRequestOrigin` (the gate itself; inert with the env var unset)
- `web-next/src/middleware.ts` — the extra-origins branch of
  `localRequestOrigin` and the sign-in bounce (both no-ops when
  `WEB_NEXT_EXTRA_LOCAL_ORIGINS` is unset)
- `web-next/scripts/start-local.ts` — the proxy sign-in printout (prints
  nothing when unset)

## What the feature never does

- Never binds beyond loopback — external reachability requires an operator
  running `tailscale serve` (or equivalent) themselves; the app does not
  configure the network.
- Never authorizes by network position — the minted bearer token is the gate
  on every path (docs/decisions/mobile-tailnet-design.md). The one unauthenticated
  route, `POST /api/pairing/ack`, authenticates itself with that same token; its
  `GET` companion answers loopback callers only.
- Never starts a second server: the app owns its child's port. To serve
  headlessly without the app (phone Safari, demos), run web-next's own
  `pnpm start:local` with `PORT`, `WEB_NEXT_DATA_DIR`, and
  `WEB_NEXT_EXTRA_LOCAL_ORIGINS` set to match — and don't run the app's
  embedded surface at the same time.
- Never persists the token-bearing QR (window snapshots disabled) or writes
  it to logs (the child's log reader redacts `token=`).

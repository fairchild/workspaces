# Mobile pairing — isolation and disable contract

Mobile pairing (the QR window, tailnet reachability, and the pairing
handshake) is deliberately isolated so a deployment that does not want remote
connectivity can turn it off at three depths. With the feature off at any
depth, the embedded web-next server is loopback-only and the desktop app
exposes no pairing surface — byte-identical behavior to a build that never
had the feature.

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
- `scripts/mobile-server.sh` + its `mise` task — headless convenience only

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
  on every path (docs/decisions/mobile-tailnet-design.md).
- Never persists the token-bearing QR (window snapshots disabled) or writes
  it to logs (the child's log reader redacts `token=`).

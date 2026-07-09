# Contract: native embedding of local-mode web-next (#987)

- Status: **Proposed** (2026-07-09; acceptance = owner merge)
- Parent decision: `host-compute-daily-driver.md` — this file makes its
  "boundary crossing via contract, not reach-in" concrete.
- Parties: the workspaces native app (consumer, `Sources/`) and web-next
  (provider, `web-next/`). Neither side imports from or writes into the other;
  everything below travels over process spawn, the filesystem token file, and
  loopback HTTP.

## 1. Spawn

The app launches web-next by running **`pnpm run start:local`** with:

- `cwd` = the web-next root, an app setting (Milestone 1 demo default:
  `~/code/workspaces/web-next`; packaging web-next into the app bundle is out
  of scope here).
- Env, set by the app: `PORT` (app-chosen loopback port, default **3140** —
  clear of dev 3100 and hero 3200) and `WEB_NEXT_DATA_DIR` (an app-managed
  directory, e.g. `~/Library/Application Support/WorkspaceManager/web-next/`).
- Everything else — provider credentials, DB location under the data dir —
  is web-next's own business: `start:local` loads `web-next/.env.local`
  itself. The app never reads or writes `.env.local` or the SQLite files.

Lifecycle is app-owned. `start:local` runs `next start` as a child without
signal forwarding, so the app spawns the entrypoint **in its own process
group and terminates the group** (SIGTERM, then SIGKILL after a grace
period) on quit or restart. Crash/restart policy is the app's choice; the
server holds no state that makes restarts unsafe (sessions live in the
SQLite DB under the data dir).

## 2. Readiness and auth handoff

- **Readiness**: the app polls `GET http://127.0.0.1:<port>/api/healthz`
  until it answers `200` with `{ "ok": true, "localMode": true }`. The
  endpoint is unauthenticated and constant — it reveals nothing beyond
  liveness. (Until healthz ships, any HTTP response on the port may be
  treated as "up"; healthz is the contract.)
- **Token**: after readiness, the app reads the minted bearer token from
  `<WEB_NEXT_DATA_DIR>/local-sign-in-token` (created `0600` by
  `src/lib/auth/local-token.ts`). The app holds it in memory only.
- **Sign-in**: the app navigates its WKWebView to
  `http://127.0.0.1:<port>/sign-in?token=<token>&redirect=<path>`.
  Middleware validates the token (constant-time), sets the httpOnly local
  session cookie, and 302s to `redirect` — which must be a relative path
  (`/…`, not `//…`, no scheme); anything else falls back to `/`.

## 3. Deep-link surface

One URL creates work; everything else is ordinary navigation.

- **`GET /new?repo=<owner>/<name>[&title=<text>]`** (authenticated):
  validates the repo the same way the UI's create-session action does,
  creates a session bound to it using the server's default compute provider,
  and 302s to `/sessions/<id>`. Validation failures return a readable
  4xx page, not a 500.
- **`POST /api/sessions`** additionally accepts an optional
  `repo: "<owner>/<name>"`, resolving it identically. Omitted → today's
  repo-less behavior.
- **Reserved for Milestone 2**: `path=<absolute working-copy path>` on both
  surfaces, binding a host-provider session to an app-managed
  workspace/worktree. Until implemented it is rejected with `400` and an
  explicit "not yet supported" message — never silently ignored.
- Existing per-session URLs (`/sessions/<id>`) are the app's re-entry points;
  the app may persist and deep-link to them freely.

## 4. Security invariants

- Serving stays loopback-bound by construction (`-H 127.0.0.1` plus the
  middleware Host-header check). The contract adds no listener and no new
  unauthenticated surface beyond `healthz`.
- The WKWebView allowlists navigation to `127.0.0.1:<port>` /
  `localhost:<port>`; external links open in the default browser.
- The token appears only in the initial sign-in navigation within the app's
  own webview; it is never logged, never placed in a persisted URL.

## 5. Milestone 1 scope notes

Milestone 1 (usable embedded demo, real draft PR out) runs the **vercel
provider** end to end: `/new?repo=…` → agent turn → the existing Open PR
affordance. The host provider's write/PR lane and `path=` binding are
Milestone 2 and change nothing above except un-reserving `path=`.

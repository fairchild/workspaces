# Deploying web-next

Deployment itself is a later issue; this documents the environment the app
expects in production. Single-user product: GitHub OAuth + a login allowlist.

## Required environment variables

| Variable | Purpose |
|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | GitHub OAuth app client id. Its presence is also the "real auth" switch: it hard-disables the test bypass (see below). |
| `GITHUB_OAUTH_CLIENT_SECRET` | GitHub OAuth app client secret. |
| `BETTER_AUTH_SECRET` | Session/cookie signing secret (e.g. `openssl rand -hex 32`). Required whenever `GITHUB_OAUTH_CLIENT_ID` is set — the server refuses to fall back to the dev secret. |
| `BETTER_AUTH_URL` | Canonical origin, e.g. `https://spaces.example.com`. |
| `ALLOWED_LOGINS` | Comma-separated GitHub logins allowed in (case-insensitive), e.g. `fairchild`. Anyone else who authenticates gets the polite refusal page and no data. |
| `SESSIONS_DATABASE_URL` | libSQL URL — a Turso `libsql://…` URL in production, or a `file:` path. Defaults to `file:.data/sessions.db` (fine for dev, not for serverless). |
| `SESSIONS_DATABASE_AUTH_TOKEN` | Turso auth token, when `SESSIONS_DATABASE_URL` is a remote URL. |

The GitHub OAuth app's authorization callback URL is
`<BETTER_AUTH_URL>/api/auth/callback/github`.

Database tables (session store + Better Auth's `user`/`session`/`account`/
`verification`) are created by the app's own migrations on first request —
no separate migration step.

## `AUTH_BYPASS` — never set this in production

`AUTH_BYPASS=1` enables the cookie-driven test sign-in used by e2e, evidence,
and perf runs (see `src/lib/auth/config.ts`). It is double-locked: it only
activates when `GITHUB_OAUTH_CLIENT_ID` is **unset**, so a production
deployment with real OAuth configured ignores it entirely. Still, treat it as
a test-harness knob: don't set it anywhere user-reachable.

## Local dev

```bash
AUTH_BYPASS=1 ALLOWED_LOGINS=<your-github-login> pnpm dev
```

Then use the "continue as … (test bypass)" button on `/sign-in`. The database
defaults to `file:.data/sessions.db` (gitignored); no other env is needed.

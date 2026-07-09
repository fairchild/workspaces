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
| `WEB_NEXT_DATA_DIR` | Local filesystem data directory for defaults. When `SESSIONS_DATABASE_URL` is unset, SQLite lives at `<dir>/sessions.db`; local serving mode also stores its minted token there. Defaults to `.data`. |

The GitHub OAuth app's authorization callback URL is
`<BETTER_AUTH_URL>/api/auth/callback/github`. Production uses the
`web-workspaces` **GitHub App** as the OAuth client (client id `Iv23…`) rather
than a standalone OAuth App: GitHub Apps accept multiple callback URLs, so the
canonical domain (`https://folio.cloudcompute.com`) and the vercel.app origin
are both registered. `BETTER_AUTH_URL` decides which one every sign-in
actually uses — Better Auth builds `redirect_uri` from it regardless of which
origin the user started on, so a `BETTER_AUTH_URL` value whose callback isn't
registered breaks sign-in on *all* origins at once.

## Shipping env-only changes (Vercel)

The project's ignored-build-step (`git diff --quiet HEAD^ HEAD -- .`, rooted at
`web-next/`) cancels any git-sourced deployment whose HEAD commit doesn't touch
`web-next/` — which is exactly the situation after changing only env vars. Two
working paths:

- **Redeploy-from-existing** (env-only): `POST /v13/deployments` with
  `{"deploymentId": <last READY prod deployment>, "target": "production"}` —
  copies the build, applies current env, skips the ignore step.
- **Fresh build when HEAD doesn't touch web-next**: same endpoint with
  `gitSource` plus `"projectSettings": {"commandForIgnoringBuildStep": ""}` to
  override the ignore step for that one deployment.

A CANCELED deployment leaves the previous build serving — env changes silently
don't apply, which presents as stale behavior (e.g. an old `BETTER_AUTH_URL`
generating the wrong `redirect_uri`). Check `readyState` of the deployment you
created, not just the alias.

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

## Owner-local `next start`

```bash
pnpm start:local
PORT=3183 WEB_NEXT_DATA_DIR=/path/to/spaces-data pnpm start:local
```

`WEB_NEXT_LOCAL_MODE=1` is the single-user local production-serving mode. It is
not GitHub OAuth and not the test bypass: startup fails if `AUTH_BYPASS=1` or
GitHub OAuth env vars are present. The wrapper mints a random token with Node
crypto, persists it under `WEB_NEXT_DATA_DIR` (default
`.data/local-sign-in-token`), exports it to middleware, and prints a usable
sign-in URL: `http://localhost:<port>/sign-in?token=…`. Visiting that URL sets
the local session cookie for `WEB_NEXT_LOCAL_LOGIN` (default `fairchild`).

The wrapper starts Next with `-H 127.0.0.1`; because Next owns the socket, the
app also hard-fails any local-mode request whose Host header is not loopback.
Use `pnpm validate --env local-mode` for the posture check: loopback Host
required, token cookie required, bypass cookie inert, and no OAuth door.

## Real-runtime credentials (#750+)

The auth/DB vars above run the app and its mock provider. The **real** agent
runtime (`@ai-sdk/harness` → Claude Code in a Vercel sandbox) needs three more
things, in three places. Copy `.env.local.example` → `.env.local` on the Mac; put
the same secrets in the Claude Code cloud-dev environment and the Vercel project.

| Variable | Mac (`.env.local`) | Cloud dev | Vercel prod | Source |
|---|---|---|---|---|
| `ANTHROPIC_API_KEY` **or** `AI_GATEWAY_API_KEY` | ✓ | ✓ | ✓ | Anthropic console / AI Gateway (gateway preferred: spend cap, one key for Claude/Codex/Pi) |
| `VERCEL_TOKEN` / `VERCEL_TEAM_ID` / `VERCEL_PROJECT_ID` | ✓ | ✓ | — (Vercel injects OIDC on-platform) | vercel.com/account/tokens, project settings |
| `GITHUB_WEB_WORKSPACES_APP_ID` + `GITHUB_APP_PRIVATE_KEY` | ✓ | ✓ | ✓ | existing GitHub App — mints short-lived, repo-scoped installation tokens for the sandbox clone |

Notes:

- **Local review needs none of these** — only `AUTH_BYPASS=1` + `ALLOWED_LOGINS`.
  These are exclusively for making a real agent turn run.
- **Vercel production doesn't need the `VERCEL_*` tokens**: running *on* Vercel,
  the Sandbox authenticates via the auto-injected `VERCEL_OIDC_TOKEN`. Those
  tokens are only needed *off*-Vercel (the Mac and cloud-dev).
- **Repo clone reuses the existing GitHub App** (installation tokens) rather than
  a personal token — scoped and short-lived. The App id + private key are the
  same credentials the `web/` managed PR reviewer already uses.
- **OAuth app callback:** whichever OAuth app backs production login, its callback
  list must include `<BETTER_AUTH_URL>/api/auth/callback/github`.
- Exact runtime var names are finalized when #750 lands; this is the canonical set
  to provision against.

## Validation identity (#814)

`scripts/validate.mjs` drives *deployed* environments with two credentials —
never committed, present in GitHub Actions secrets (for
`.github/workflows/web-next-validate.yml`) and the local `.env`. Full
rationale: `docs/decisions/web-next-validation-identity.md` (repo root).

| Variable | Purpose |
|---|---|
| `WEB_NEXT_VALIDATION_SESSION` | Pre-minted Better Auth session token for the allowlisted validation identity; replayed as the session cookie (`__Secure-better-auth.session_token` on https targets). Expiry degrades authed stages to `skipped: validation session expired — re-seed`. |
| `VERCEL_AUTOMATION_BYPASS_SECRET` | Vercel Protection Bypass for Automation (`x-vercel-protection-bypass` header) — clears deployment-protection SSO on previews; production is publicly reachable without it. |

A run missing either reports the affected stages as explicit skips — validation
never silently passes an environment it couldn't actually reach or sign into.

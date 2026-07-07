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

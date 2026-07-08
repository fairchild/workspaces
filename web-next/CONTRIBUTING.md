# Contributing / local development — web-next

How to run the sessions-first web app locally, from zero to a streaming mock
turn, plus the extra credentials that light up the real agent runtime. The
production environment matrix lives in [`docs/deploy.md`](docs/deploy.md);
design system in [`docs/design.md`](docs/design.md); the sequencing plan to a
usable product is [`docs/roadmap.md`](docs/roadmap.md).

## Prerequisites

- **Node 22** and **pnpm 10** (what CI pins — see `.github/workflows/web-next-ci.yml`).
  pnpm 11 currently breaks `pnpm run` here (its verify-deps prompt writes an
  invalid placeholder `pnpm-workspace.yaml` in no-TTY shells); if you see
  `ERR_PNPM_IGNORED_BUILDS` or a stray `web-next/pnpm-workspace.yaml`, delete
  that file and use pnpm 10 (`corepack prepare pnpm@10 --activate` or
  `npx pnpm@10`).

## Run it (no credentials needed)

```bash
cd web-next
cp .env.local.example .env.local   # defaults are already correct for local dev
pnpm install
pnpm dev                            # http://localhost:3100
```

Sign in via the **“continue as fairchild (test bypass)”** button on `/sign-in`.
That button is the `AUTH_BYPASS=1` test harness; it is hard-disabled the moment
`GITHUB_OAUTH_CLIENT_ID` is set, so it can never leak into a real deployment.

The database defaults to `file:.data/sessions.db` (gitignored, auto-migrated on
first request). Everything runs against the **mock provider** — a scripted
coding turn with reasoning, tool calls, a failing→passing test cycle, and a
diff. Try `/sessions/demo?scenario=adversarial` or `?scenario=long` to stress
the transcript.

## Quality gates (what CI runs)

```bash
pnpm test        # vitest unit suite
pnpm typecheck
pnpm lint
pnpm build       # production build — must stay clean (see #780 for the stale-.next trap)
pnpm test:e2e    # Playwright; builds + serves on :3100 in auth-bypass mode
pnpm evidence    # light+dark screenshot walk → output/evidence/
pnpm perf        # perf harness vs perf/contract.json budgets
pnpm validate    # env-targetable validation (--env local|prod, --url <origin>)
```

`pnpm evidence` only writes local files — the repo's evidence gate needs
uploaded URLs in the PR body (`docs/development/evidence.md`). Upload the
whole walk in one shot with `pnpm evidence:upload -- --pr <N>` (wraps
repo-root `scripts/evidence.sh` once per PNG, needs `EVIDENCE_UPLOAD_TOKEN`)
and paste the printed markdown summary into the PR.

`pnpm validate` also runs against real deployments — `pnpm validate --env prod`
probes reachability and auth/security posture with zero credentials, and
credential-gated stages report themselves skipped rather than passing silently
(see `docs/roadmap.md` Phase 2 / milestone #13). Two more stages gate on the
same `WEB_NEXT_VALIDATION_SESSION` (the pre-minted validation identity —
`docs/decisions/web-next-validation-identity.md`): a model sweep (#816) that
calls `/api/diag/gateway?model=<id>` once per selectable model
(`agent-runtime/models.ts`) to prove selection actually routes in the target,
and an e2e stage (#817) that replays the `@deployed-safe`-tagged specs in
`tests/e2e/` against the target through `playwright.config.ts`'s
`VALIDATE_TARGET_URL` seam — set by `validate.mjs` itself, not meant to be
set by hand. Both report `skipped: validation session expired — re-seed`
when the session cookie doesn't authenticate, matching the decision doc's
expiry wording, rather than failing.

## Cleaning up

```bash
pnpm run clean              # build + data + artifacts (the safe everyday trio)
pnpm run clean build        # just .next (clean-build reproduction)
pnpm run clean all --dry-run
```

One entrypoint for deleting build/test state — `.next`, throwaway e2e/perf
databases (`.data/`), and test artifacts (`output/`, reports, perf results).
Use it instead of ad-hoc `rm -rf`: the fixed target map is safe by
construction and the single command shape is shell-allowlistable, so
unattended agent sessions don't stall on permission prompts. `deps`
(node_modules) is only removed when named explicitly or via `all`.

## The feedback loop (owner review of in-flight work)

The product is steered by the owner looking at a running instance, not at
diffs. Three surfaces, cheapest first:

1. **Local instance** — `pnpm dev` on the latest `main` (mock provider,
   instant). For **real coding turns**, add `WEB_NEXT_COMPUTE_PROVIDER=vercel`
   to `.env.local` (the runtime keys above power it); new sessions then run
   real Claude Code in a sandbox.
2. **Per-PR preview** — every PR gets a Vercel preview URL in the bot comment;
   sign in through the SSO wall to try a change *before* it merges. Agent PR
   bodies carry a **"What to look at"** line naming the screen/flow the change
   affects.
3. **Anytime sanity** — `pnpm validate --url http://localhost:3100` (or
   `--env prod`) checks the instance you're looking at.

Agents: keep PRs issue-sized so each preview is one reviewable behavior, and
treat owner feedback from these surfaces as the tracker's input queue — file
what you hear as issues before it evaporates.

E2E notes:

- The web server for e2e is a **production** build (`e2e:server` script); the
  first `test:e2e` run builds it.
- If port 3100 is stuck, look for an orphaned `next-server` process — killing
  the `next start` wrapper does not always kill it.
- In remote/sandboxed sessions where Playwright’s CDN is unreachable, point the
  suite at a preinstalled browser:
  `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/opt/pw-browsers/chromium-*/chrome-linux/chrome pnpm test:e2e`
  (the config honors that variable; leave it unset on dev machines and CI).
- A clean `pnpm build` failing with `<Html> should not be imported…` on
  pages-router artifacts (`/404`, `/500`) means stale local state — this app
  never builds those pages. `rm -rf .next` and rebuild (#780).

## Extra keys — real agent runtime (#750+)

Local UI/dev work needs **none** of these. They exist to run a *real* Claude
Code turn in a Vercel sandbox instead of the mock. Copy each into `.env.local`
(all names and inline notes are in [`.env.local.example`](.env.local.example)):

| Key | Where to get it |
|---|---|
| `AI_GATEWAY_API_KEY` | `npx vercel ai-gateway api-keys create` (or Vercel dashboard → AI Gateway → API Keys). Preferred over a raw key: spend cap, one key for Claude/Codex/Pi. |
| `ANTHROPIC_API_KEY` | console.anthropic.com → API Keys — only if not using the gateway. |
| `VERCEL_TOKEN` | vercel.com/account/tokens (scope: the `cloudcompute` team). Off-Vercel only — production uses the auto-injected OIDC token. |
| `VERCEL_TEAM_ID` | `team_oGt9u60VkiPutA2CiKDDGQKV` (also in `.vercel/project.json` after `vercel link`). |
| `VERCEL_PROJECT_ID` | `prj_ucOY3JKR5BCrbtbfz8DTSFJe5U9m` (the `web-next` project). |
| `GITHUB_WEB_WORKSPACES_APP_ID` | github.com/settings/apps → **`workspace-agents`** app → App ID. |
| `GITHUB_APP_PRIVATE_KEY` | Same page → Generate a private key → store the `.pem` single-line: `base64 -i app.pem \| tr -d '\n'`. |

Why the GitHub **App** (not an OAuth app): the sandbox clones with short-lived,
repo-scoped *installation* tokens. An OAuth token would be user-scoped and
long-lived — the wrong credential to hand an agent-controlled environment. The
sign-in OAuth app and this App are separate identities doing separate jobs
(see `docs/development/github-app-identities.md` at the repo root).

The same credential set goes in the other two stores when relevant —
Claude Code cloud-dev (environment settings) and Vercel production (project
env vars) — per the matrix in [`docs/deploy.md`](docs/deploy.md).

## Deploying

The app is linked to Vercel project **`cloudcompute/web-next`**
(https://folio.cloudcompute.com):

```bash
npx vercel login            # device flow
npx vercel link --yes       # writes .vercel/ (gitignored)
npx vercel deploy --prod    # env vars apply per-deployment — redeploy after changing them
npx vercel env ls production
npx vercel logs <deployment-url>
```

Production keeps Vercel’s deployment protection (SSO) on top of the app’s own
GitHub OAuth + `ALLOWED_LOGINS` allowlist; only allowlisted GitHub logins get
past the sign-in page, everyone else gets a refusal page and 403s from the API.

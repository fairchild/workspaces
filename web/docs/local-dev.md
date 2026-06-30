# Web Dashboard Local Development

Canonical guide for running and verifying `web/` locally. `AGENTS.md` carries the
short rules; this doc holds the full task catalog, caveats, and auth plumbing.

## Mise tasks (use these, not raw pnpm chains)

Tasks live in `web/.mise.toml` and are **not** chain-loaded from the root
`.mise.toml`. Run them after `cd web/`, or with `-C web` from anywhere
(`mise -C web run web:check`). They are auto-allowed via `Bash(mise run web:*)`
and guarded by a hook that blocks execution if `.mise.toml` has uncommitted
changes.

```bash
mise run web:check                          # typecheck + lint + unit tests
mise run web:dev                            # seed DB + auth bypass + start dev server
mise run web:e2e                            # Playwright E2E (fast + full)
mise run web:e2e:deployment-smoke           # remote-safe smoke against local dev server (default port 3212)
mise run web:e2e:demo                       # Playwright demo with video recording
mise run web:e2e:explore                    # qa-explore project (video + trace + axe-core)
mise run web:preview:alias -- --pr <N>      # assign qa.spaces-preview.cloudcompute.com to this PR preview
mise run web:preview:smoke -- --pr <N>      # remote-safe smoke against the reusable QA alias
mise run web:preview:auth -- --pr <N>       # headed real-OAuth preview login + storage state
mise run web:preview:explore -- --pr <N>    # authenticated exploratory QA against the reusable QA alias
mise run web:qa:init-agents                 # one-shot: scaffold Playwright's agent-loop files
mise run web:qa:codegen                     # interactive Playwright codegen recorder
mise run web:evidence -- --pr <N> --name <slug>  # screenshot capture + evidence upload
mise run web:deps -- <pkg>                  # pnpm add + auto-fix package.json formatting
mise run web:deps:remove -- <pkg>           # pnpm remove + auto-fix formatting
```

### Anti-patterns (use the mise task instead)

- `pnpm typecheck && pnpm lint && pnpm test` → `mise run web:check`
- `pnpm add <pkg>` then `pnpm biome check --write package.json` → `mise run web:deps -- <pkg>`
- Manual DB seeding + `DEV_BYPASS_AUTH=1 pnpm dev` → `mise run web:dev`
- Ad-hoc Playwright screenshot scripts → `mise run web:evidence -- --pr <N>`

## Local vs CI caveats

- `fast/unauth-*` Playwright specs require `NODE_ENV=production` — they pass in
  CI (which uses `pnpm start`) and fail under `pnpm dev` (the auth bypass is
  active in development). Expected; not a regression.

## Dev-bypass token plumbing

`mise run web:dev` hardcodes `DEV_BYPASS_AUTH=1`, which creates a fake
"dev-user" session but gives routes a placeholder string in place of a real
GitHub PAT. Any call that hits the real GitHub API (agent discovery, pipeline,
webhook-status, login lookup) 401s and the UI prompts "sign out / sign in".

To light up GitHub-backed features without running the full OAuth flow, prefix
the task with a real token:

```bash
DEV_GH_TOKEN=$(gh auth token) mise run web:dev
```

`getDevBypassToken()` in `web/src/lib/auth-server.ts` prefers `DEV_GH_TOKEN`
over the placeholder when set. Setting `GITHUB_WEB_WORKSPACES_CLIENT_ID` vetoes
the bypass entirely and forces the real OAuth flow.

Screenshots without auth: start the dev server with `DEV_BYPASS_AUTH=1 pnpm dev`
(or just `mise run web:dev`).

## Preview QA

PR previews publish a raw Vercel deployment URL. When a PR needs authenticated
QA, assign the reusable OAuth-compatible alias to that raw preview:

```text
https://qa.spaces-preview.cloudcompute.com
```

Run the cheap deployed-app smoke first, then create or refresh the real-OAuth
storage state, then run exploratory QA:

```bash
mise run web:preview:alias -- --pr <N>
mise run web:preview:smoke -- --pr <N>
mise run web:preview:auth -- --pr <N>
mise run web:preview:explore -- --pr <N>
```

See `preview-qa.md` for the adversarial checklist and evidence flow.

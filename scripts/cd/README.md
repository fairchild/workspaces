# Preview → Validate → Promote CD

Continuous-deployment for the web dashboard (Vercel) and Cloudflare Workers, with a hard validation gate between "merged to main" and "live in production."

```
push to main ──► preview deploy ──► validate (Playwright + Lighthouse + worker /health)
                                          │
                       pass ──────────────┴─────────────► promote (alias swap, no rebuild)
                       fail ──────────────────────────► open/append rolling GitHub issue
```

## Why this exists

Before: pushing to `main` shipped straight to production. No gate, no validation, no rollback path other than a revert PR. A regression — bad bundle, perf cliff, broken auth flow — was already in production by the time anyone noticed.

After: every push to `main` produces a preview deployment, gets validated against budgets, and only the validated artifact is promoted. Validation failures open a structured GitHub issue with findings and a fix-or-explore template instead of paging anyone.

## Core concepts

**Preview = a fully-built, fully-deployed artifact at a real URL.** Not a CI ephemeral; the actual `*.vercel.app` and `*-preview.cloudcompute.com` deployments. Validators run against the same artifact that prod will receive.

**"Validated artifact ships" invariant.** `vercel promote <preview-url>` re-points the production alias to the existing preview deployment without rebuilding. The bytes you tested are the bytes that go live. This is the single most important property of the design — see [`backlog/`](../../backlog/) for the analysis of Deploy Hooks vs. CLI promote.

**Rolling failure issues, not per-failure issues.** One issue per validator (`CD: playwright failures on main`, `CD: lighthouse failures on main`), identified by hidden HTML markers. New failures append a comment; the issue auto-reopens if closed. Avoids issue-tracker flooding during a regression burst.

**Configuration as code.** The Vercel Git auto-deploy guard lives in `web/vercel.json` (`git.deploymentEnabled = false`), not in dashboard settings. Vercel stays connected for metadata, while GitHub Actions owns PR previews and production promotion.

**Targeted PR previews.** `.github/workflows/web-preview.yml` deploys Vercel previews only for PRs that touch `web/**`. Non-web PRs do not create Vercel deployments or preview comments.

## Architecture

```
                        push to main
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
      ┌──────────────┐  ┌──────────────┐    │  GitHub Actions
      │ preview-web  │  │preview-workers│   │  (cd.yml)
      │              │  │   (matrix)    │   │
      │ vercel build │  │ wrangler      │   │
      │ + deploy     │  │ deploy --env  │   │
      │ → URL        │  │ preview       │   │
      └──────┬───────┘  └──────┬───────┘    │
             │                 │            │
             ├─────────┬───────┘            │
             ▼         ▼                    │
      ┌──────────┐ ┌──────────┐             │
      │playwright│ │lighthouse│             │
      │  fast    │ │ 3 runs   │             │
      │  project │ │ desktop  │             │
      └────┬─────┘ └────┬─────┘             │
           │            │                   │
           └─────┬──────┘                   │
                 ▼                          │
         ┌──────────────┐                   │
   pass  │   promote    │  fail             │
    ┌────┤              ├────┐              │
    │    │              │    │              │
    │    └──────────────┘    │              │
    ▼                        ▼              │
 wrangler                 fail-notify       │
 deploy (prod)            (per-validator    │
 + vercel promote          rolling issue)   │
                                            │
                                            ▼
                              Cloudflare + Vercel + GitHub
```

**The promote step is intentionally atomic-per-target but not atomic-across-targets.** Workers deploy first (cheap, low-risk); Vercel promote runs last (alias flip, instantaneous). If wrangler fails, vercel promote is skipped → prod web stays on the previously-validated artifact. Documented trade-off in `cd.yml`.

## Key files

| File | What it does |
|---|---|
| `.github/workflows/cd.yml` | The 7-job CD pipeline: preview-web, preview-workers, playwright-validate, lighthouse, promote, fail-notify-{playwright,lighthouse}. |
| `.github/workflows/web-preview.yml` | Path-filtered PR preview deployment for `web/**`, with a single updated PR comment. |
| `scripts/cd/bootstrap-preview.py` | Interactive setup wizard for first-time configuration. Prompts for tokens, writes secrets to GitHub + Cloudflare, generates `web/vercel.json`. |
| `scripts/cd/config.toml` | Declarative manifest. Workers, preview health URLs, secret names, GitHub Actions secrets. **Add a worker = one TOML block.** |
| `scripts/cd/.env.bootstrap.example` | Template for the gitignored `.env.bootstrap` where the operator's tokens live locally. |
| `web/vercel.json` | Generated. Contains `git.deploymentEnabled = false` — disables Vercel's automatic Git deployments so Actions owns PR previews and production promotion. |
| `web/playwright.config.ts` | Honors `PLAYWRIGHT_BASE_URL` to target the preview URL; skips the local `webServer` block when set. |
| `web/lighthouserc.json` | Perf budgets: LCP ≤2500ms, CLS ≤0.1, TBT ≤200ms, perf score ≥0.9. Desktop preset, 3 runs, median assertions. URL passed at invocation via `--collect.url`. |
| `web/scripts/{playwright,lhci}-findings.mjs` | Render validator JSON output into markdown tables for the failure-issue body. |
| `infra/<worker>/wrangler.toml` | Each in-tree worker has an `[env.preview]` block with separate routes/bindings (e.g. `evidence-screenshots-preview` R2 bucket). |

## Bootstrap (first-time setup)

```bash
# 1. Walk through interactive setup. Prompts for tokens; writes to .env.bootstrap as you go.
uv run scripts/cd/bootstrap-preview.py

# 2. When dry-run looks right, apply for real:
uv run scripts/cd/bootstrap-preview.py --apply
```

When it's done, step 6 prints the exact `git commit` command for `web/vercel.json` (or offers to commit it interactively) and the `gh workflow run cd.yml` CLI for the first run.

What gets set up automatically:
- `web/vercel.json` — Git auto-deploy guard (offered-to-commit interactively)
- Cloudflare Worker preview secrets — per worker, per `wrangler secret put`
- GitHub Actions repo secrets — `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` — verified via `gh secret list` after push
- Vercel project link — runs `vercel link` if `web/.vercel/project.json` doesn't exist
- Preview worker custom-domain DNS — when a health URL is unreachable but dry-run passes, the script offers to run a real `wrangler deploy --env preview`. Wrangler provisions DNS for any `custom_domain = true` route automatically.

What still requires you (no API exists for these):
- Creating the Vercel token (dashboard)
- Creating the Cloudflare API token (dashboard)

## Adding a new worker to CD

1. Add `[env.preview]` block to the worker's `wrangler.toml` with its own bindings + route.
2. Append to `scripts/cd/config.toml`:
   ```toml
   [[workers]]
   dir = "infra/your-new-worker"
   preview_health_url = "https://your-new-preview.cloudcompute.com/health"
   preview_secrets = ["SOME_API_KEY"]
   preview_secret_hints.SOME_API_KEY = "Where does this come from? (One-line provenance — shown at the prompt so future operators know what to paste.)"
   ```
3. Add `PW_SOME_API_KEY=` to `.env.bootstrap`.
4. Re-run `uv run scripts/cd/bootstrap-preview.py --apply`.
5. Add the new worker name to the matrix in `.github/workflows/cd.yml` (`preview-workers` and `promote` jobs).

## Operational notes

**Re-run the bootstrap any time.** It's idempotent. Already-set secrets are detected and skipped (use `--force` to override).

**Non-interactive mode for CI.** `--non-interactive --apply` reads `.env.bootstrap`, warns on missing values, no prompts.

**`--only STEP`** runs a single phase (`prereq | vercel | cloudflare | github | validate`). Useful when one step fails and you want to retry just that one.

**Failure issue dedup.** Failures from the same validator update one rolling issue rather than spamming. Close the issue when you've handled it; the next failure reopens it.

**Workflow trigger.** `cd.yml` runs on `push: branches: [main]` and `workflow_dispatch:` (so you can dispatch test runs from the Actions tab without merging).

**Concurrency.** `concurrency.group: cd-main` with `cancel-in-progress: false` — never cancel a promote mid-flight; queue subsequent pushes.

**PR preview trigger.** `web-preview.yml` runs on non-draft, same-repo PRs that touch `web/**` or the preview workflow itself. Fork PRs are intentionally skipped because they cannot safely receive Vercel deployment secrets.

**Managed reviewer validation.** The pre-promotion gate runs the managed
reviewer ingress canary, broker, and monitor strictly. Post-promotion
`validate-prod` runs the ingress canary again, skips the mutating broker, and
treats monitor queue-health attention as advisory so a failed historical review
run does not block production Playwright smoke or release readiness. Use the
scheduled Managed Reviewer Broker/Health workflows and
`uv run --script scripts/pr-reviewer-runs.py` for operational reviewer failures.

## Design decisions worth understanding

- **Why monolithic `cd.yml` not split workflows.** Promote needs `needs:` semantics across web + workers. Splitting loses the "all validators must pass before any promote" atomicity.
- **Why `fast` Playwright project only.** `full` needs a seeded DB; preview targets Vercel's serverless DB which we can't seed from CI. Future: staging env with seeded Turso.
- **Why separate R2 bucket for evidence-store preview.** Preview test writes would otherwise pollute the prod keyspace and share the prod auth token's blast radius. 7-day lifecycle on `evidence-screenshots-preview` keeps storage cost ~$0.
- **Why `vercel.json` over dashboard branch flip.** Code-controlled, survives project recreation, visible in diffs. Vercel's deprecated `github.enabled` is the legacy form; `git.deploymentEnabled` is current.
- **Why Actions-owned PR previews.** Vercel's ignored-build path still creates canceled deployments; the path-filtered workflow avoids deployments entirely for non-web PRs.
- **Why pinned tool versions (`vercel@51`, `wrangler@4`, `@lhci/cli@0.14.x`).** CLI behavior changes silently break CD. Renovate/Dependabot surfaces upgrades through PR.

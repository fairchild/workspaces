---
status: done
issue: 543
completed: 2026-05-25
resolution: promoted-to-github-issue
topic: web-cd
priority: 2
description: Add a remote-safe, skippable Playwright smoke lane for CD preview and prod validation.
---

# Pre-Release Deployment Smoke

## Problem Statement

The CD pipeline currently runs the whole Playwright `fast` project against the
fresh Vercel preview before promotion. That caught real deployment-protection
issues, but it also couples deployed-app smoke validation to local integration
tests that seed runner-local databases and create synthetic Better Auth
sessions.

PR #433 added cross-tenant API authorization coverage in
`web/e2e/fast/api-authorization.spec.ts`. That suite is valuable in local CI,
but it cannot run against a deployed preview because the preview app cannot see
the runner-local `file:data/e2e-auth.db`, and the tests use synthetic cookies
signed with a local placeholder secret. The result was repeated CD failures on
main starting with run `25288822616`: `apiRequestContext.get: Max redirect count
exceeded` in the first authz test.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment validation lane | Add a dedicated Playwright project such as `deployment-smoke` | CD should run only tests that are meaningful against a deployed preview/prod app |
| Local integration lane | Keep seeded DB/authz tests in `fast` | They protect route wiring and cross-tenant authorization, but require local test data control |
| Skippability | Make smoke specs explicitly remote-safe and tag or isolate them by directory | Future local-only specs should not accidentally block deployment |
| CD command | Run `pnpm exec playwright test --project deployment-smoke` in preview and prod validators | The command communicates the validator's purpose better than running all `fast/**` specs |

## Architecture

```text
Pull Request / Web CI
  pnpm run test:e2e:fast
    ├── landing/auth redirect checks
    ├── local seeded-DB API authz checks
    └── other fast integration checks

Main CD
  preview-web deploys Vercel preview
  playwright-validate runs deployment-smoke against preview URL
  promote aliases validated artifact to prod
  validate-prod runs deployment-smoke against prod URL
```

## Implementation Phases

### Phase 1: Add the deployment-smoke project

**Files to modify:**
- `web/playwright.config.ts` - add a `deployment-smoke` project that matches a
  remote-safe test directory or tag, and keeps the existing Vercel deployment
  protection bypass headers.
- `.github/workflows/cd.yml` - change `playwright-validate` and `validate-prod`
  from `--project fast` to `--project deployment-smoke`.
- `web/package.json` - add `test:e2e:deployment-smoke` if useful for local
  reproduction.
- `web/tests/LEDGER.md` - add rows for the smoke behaviors that CD is expected
  to prove.

**Files to create:**
- `web/e2e/deployment-smoke/landing.spec.ts` - prove the deployed app serves the
  Spaces landing page and login link.
- `web/e2e/deployment-smoke/api.spec.ts` - prove representative public/unauth API
  behavior without depending on runner-local seeded data.

**Acceptance criteria:**
- [ ] CD preview validation runs only deployment-safe tests against the preview URL.
- [ ] CD prod validation runs the same deployment-safe tests against the prod URL.
- [ ] Local seeded-DB tests still run under Web CI's `fast` project.
- [ ] A new local-only Playwright spec cannot accidentally run in CD unless it is
  placed in the deployment-smoke project or tagged for it.

### Phase 2: Improve validator diagnostics

**Files to modify:**
- `web/scripts/playwright-findings.js` - include skipped counts and the project
  name in the summary so skipped local-only suites are visible without being
  noisy.
- `.github/workflows/cd.yml` - upload the JSON report or trace artifact for
  deployment-smoke failures, not only `findings.md`.

**Acceptance criteria:**
- [ ] A deployment-smoke failure artifact identifies the failing URL, project,
  spec, assertion, and any redirect target.
- [ ] Skipped tests are visible in the report but do not cause CD failure.

## Verification Commands

```bash
cd web
pnpm run test:e2e:fast
PLAYWRIGHT_BASE_URL=https://<preview-url> \
  PLAYWRIGHT_SKIP_WEB_SERVER=1 \
  VERCEL_AUTOMATION_BYPASS_SECRET=<secret> \
  pnpm exec playwright test --project deployment-smoke
```

## Rollback Plan

Revert the `deployment-smoke` project and CD workflow command changes, then run
CD with the previous `--project fast` command. Keep any local-only suite skips
that are already justified by runner-local fixture requirements.

## References

- `.github/workflows/cd.yml` - current preview, Playwright, promote, and prod
  validation pipeline.
- `web/playwright.config.ts` - current `fast`, `full`, `demo`, and `qa-explore`
  Playwright projects plus Vercel protection bypass headers.
- `web/e2e/fast/api-authorization.spec.ts` - local-only cross-tenant authz
  coverage that exposed the need for a separate deployment-smoke lane.
- GitHub issue #356 - rolling CD Playwright failure issue.
- GitHub Actions runs `25288822616`, `25289164169`, `25289267410`, and
  `25296406474` - repeated failures after PR #433 merged.

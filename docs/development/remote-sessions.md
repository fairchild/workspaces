# Remote (claude.ai) Session Conventions

How to work in the managed remote containers that claude.ai/code sessions run
in. These environments differ from dev machines and CI in three recurring ways;
this doc is the canonical workaround set so sessions stop rediscovering them.
Tracking issue for fixing the environment itself: [#734](https://github.com/fairchild/workspaces/issues/734).

## Evidence without `EVIDENCE_UPLOAD_TOKEN`

The token exists only as a GitHub Actions secret; remote containers have no
`.env` and no sibling worktree for `scripts/setup --env-only` to link from, so
`scripts/evidence.sh` cannot upload.

**Sanctioned convention:** a green CI run link on the exact branch/commit is
acceptable hosted evidence for remote sessions — cite it in the PR's Evidence
section as `[Web CI passed on this branch](<run url>)` and say the token was
unavailable. This satisfies the "no local-only proof" rule because the run is
hosted and verifiable. Established across PRs #725/#727/#731/#732 and accepted
in review.

Limits of the convention:

- **UI screenshots** have no CI equivalent. Capture them with Playwright from
  the exact commit, deliver them to the reviewer/owner through the session
  (they render inline), and describe each shot in the PR body so the Vercel
  preview can be checked against them. State explicitly that R2 upload was
  blocked. Do not commit screenshots (`output/` policy) and do not paste
  local paths as evidence links.
- **Suites CI doesn't run** (the Playwright `full` project) need explicit
  runs — say exactly what ran where. Two independent green runs (author +
  gate) is the bar this repo has used.

If the token lands in the environment config (#734), `evidence.sh` picks it up
from the plain environment and this section's workaround becomes obsolete —
delete it then.

## `mise` is not installed

Repo docs route web work through `mise run web:*`; remote containers don't have
mise. Raw equivalents (run from `web/`):

| mise task | raw equivalent |
|---|---|
| `mise run web:check` | `pnpm run typecheck && pnpm run lint && pnpm test` |
| `mise run web:e2e -- <filter>` | `pnpm exec playwright test --project fast <filter>` |
| `mise run web:deps -- <pkg>` | edit `package.json`, `pnpm install`, keep formatting biome-clean |

`pnpm install` first in a fresh worktree — `node_modules` is never present.

## Playwright browser pin mismatch

The container preinstalls Chromium under `/opt/pw-browsers` (rev may trail the
repo's `@playwright/test` pin) and the proxy blocks Playwright's CDN, so the
pinned browser cannot download. Never run `playwright install`. Instead:

```bash
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/opt/pw-browsers/chromium-*/chrome-linux/chrome \
  pnpm exec playwright test --project fast
```

`web/playwright.config.ts` honors that variable; leave it unset on dev machines
and CI. The `fast/unauth-*` specs still need production mode
(`NODE_ENV=production` via `pnpm start`) — see `web/docs/local-dev.md`.

## Session practices that earn their keep

- **File human-lane blockers as issues the moment you hit them** (labels
  `ops`/`human`), not at reflection time. On 2026-07-02 the evidence-token gap
  was confirmed in the first hour but filed six hours later — every agent in
  between paid the same workaround. An early issue gives the owner a chance to
  fix the environment mid-session.
- **Wait on PR checks with `scripts/pr-wait.sh <sha>`** (blocks until check
  runs are terminal; exits 0 only if all latest runs are green/skipped). Webhook subscription + a per-SHA wait beats a
  recurring cron for PR babysitting — and beats hand-rolled poll loops, one of
  which shipped with an early-exit bug before this script existed.
- **Capture full command output to a file first, filter second.** A flaky test's
  identity was lost in this repo once because grep pipelines ate the failure
  name before anyone saved raw output. `cmd > log 2>&1` then grep the log.
- **Pre-check merges with `git merge-tree --write-tree`** (the new-style form).
  The legacy three-argument `merge-tree` under-reports conflicts and produced a
  false "clean" on a real LEDGER.md conflict (PR #732).
- **`web/tests/LEDGER.md` is a designed-in merge hotspot** — parallel PRs that
  both add behavior rows will conflict there. The conflicts are additive (keep
  both blocks); either serialize the PRs or budget a trivial resolution.

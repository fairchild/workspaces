---
status: decided
date: 2026-08-02
decision: managed-reviewer-retirement
related:
  - docs/decisions/factory-label-control-plane.md
  - docs/development/agent-factory-v2-plan.md
---

# The managed PR reviewer is retired; the Factory review lane succeeds it

## Decision

**The managed PR reviewer is deleted from the tree.** Its three workflows, five
operator scripts, ingress canary, `web/` runtime and routes, dashboard detail
view, and `docs/pr-review/` are gone. The Agent Factory review lane is the
successor: PR review now happens through the label control plane and directed
agent reviews rather than a dedicated always-on service.

Recovery pointer: **`9ccced8e6568f202ff2a631902a28300364fb250`** is the last
commit containing the complete system. To read or resurrect any of it:

```bash
git show 9ccced8e:web/src/lib/agent-runtime/pr-review.ts
git checkout 9ccced8e -- web/src/lib/agent-runtime/ docs/pr-review/
```

## What it was

Shipped 2026-04-18 (`9c4beaf1`, #345) as automated PR review on Anthropic
Managed Agents. GitHub delivered `pull_request` and evidence-comment webhooks to
the Cloudflare relay, which forwarded trigger candidates to a Next.js ingress
route. That route recorded a **ReviewRun** — a fingerprint over
(repo, PR, head SHA, trigger, reviewer config hash) that made retriggering
idempotent — and a scheduled broker workflow claimed pending runs, drove a
Managed Agents session with a repo-scoped GitHub App token, and projected the
result back to GitHub as a review plus a status check. A separate health
workflow audited queue depth and projection drift every 30 minutes, and an
ingress canary gated production promotion in `cd.yml`.

The interesting parts, for anyone mining it later: the fingerprint/coalescing
scheme in `pr-review-runs.ts`, the desired-state projection table that made
GitHub writes retryable without double-posting, and the review-only GitHub App
identity (`workspaces-claude-pr-reviewer`, deliberately without
`contents:write`) documented in `docs/development/github-app-identities.md`.

## Why retired

It was paused on 2026-07-06 by setting `PR_REVIEWER_ENABLED=0`, with a recorded
intent to revisit around 07-20. That revisit lapsed. By the 2026-08-02 health
audit the system was the single largest cruft mass in the repo — this deletion
removes ~19.6k lines across 63 files — and it was not merely idle but actively
noisy: the health workflow failed every 30 minutes on the pause itself, and the
broker's bare `status:` trigger logged 100 of 100 runs skipped over 30 days.

Paused infrastructure that still runs on a schedule costs attention on every
audit and every CI triage pass, and a reviewer nobody reads is worse than no
reviewer. The Factory review lane covers the need with less standing surface.

## Trade-off accepted

Restarting managed review means restoring from git rather than flipping a flag.
That is the intended cost: the flag pretended the system was one decision away
from useful, when reviving it would really mean re-validating the Managed Agents
integration, the App installation, and the projection logic against a codebase
that has moved on. A `git checkout` forces that re-validation to be explicit.

## Residual state

Not removed by this retirement, deliberately:

- **The `managed_pr_review_runs` and `managed_pr_review_projections` tables**
  still exist in production and in `web/src/lib/schema/migrations.ts`.
  Migrations are append-only history — deleting them would break replay against
  any existing database. The tables are unreferenced by application code after
  this change; dropping them is a separate, data-destructive decision.
- **The `workspaces-claude-pr-reviewer` GitHub App** still exists and stays
  documented in `docs/development/github-app-identities.md`. It remains
  review-only and its posture assertions still apply while it is installed.
  Uninstalling it is an owner action outside this change.
- **Live Vercel env vars** (`PR_REVIEWER_*`, `WORKSPACES_WEBHOOK_CANARY_SECRET`)
  are dropped from `config/vercel/spaces-web.json` so config-as-code stops
  asserting them, but remain set on the project. Nothing reads them.
- **The webhook relay's forward filter** (`shouldForwardToWebApp`) still uses
  the reviewer-era trigger shape — reviewable PR actions plus evidence comments.
  Those forwards now feed only the event stream and dispatch-card updates. The
  filter is worth revisiting on its own terms, not as reviewer cleanup.

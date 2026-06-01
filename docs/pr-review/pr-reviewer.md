# PR Reviewer — Managed Agent

Automated code review triggered by GitHub PR webhooks. The managed agent runs
on Anthropic's infrastructure, reads the diff, explores surrounding code, runs
tests, and returns a structured review intent. The web server validates that
intent and posts the GitHub review with the PR reviewer GitHub App token.

For the current ReviewRun architecture, lifecycle vocabulary, diagrams, and
operator triage surfaces, start with [`architecture.md`](architecture.md). This
file is the runtime and operations reference: configuration, ingress canaries,
broker scheduling, and debugging commands.

## Key Files

| File | Purpose |
|------|---------|
| `web/src/lib/agent-runtime/pr-review.ts` | Agent config, session creation, kickoff |
| `web/src/lib/agent-runtime/managed-agents-cache.ts` | Idempotent agent/environment creation with DB cache |
| `web/src/app/api/webhooks/github/route.ts` | Webhook handler — starts reviewer sessions and returns after kickoff |
| `web/src/app/api/webhooks/github/pr-reviewer-broker/route.ts` | Protected broker route — processes completed sessions from `managed_pr_review_runs` and posts reviews |
| `web/src/app/api/managed-agents/transcript/route.ts` | SSE endpoint for streaming session events to the UI |

## Environment Variables

| Var | Where | Purpose |
|-----|-------|---------|
| `ANTHROPIC_API_KEY` | Vercel | Anthropic API authentication |
| `PR_REVIEWER_APP_ID` | Vercel | GitHub App ID for bot identity |
| `PR_REVIEWER_PRIVATE_KEY` | Vercel | GitHub App private key (PEM) |
| `PR_REVIEWER_INSTALLATION_ID` | Vercel | GitHub App installation ID for this repo |
| `PR_REVIEWER_ENABLED` | Vercel (optional) | `0` disables the reviewer; `1` enables it explicitly. If omitted, complete App credentials enable it. |
| `PR_REVIEWER_VAULT_ID` | Vercel (optional) | Vault for MCP credentials (not currently used) |
| `PR_REVIEWER_MODEL` | Vercel (optional) | Override model (default: `claude-opus-4-6`) |
| `GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET` | Vercel | Same GitHub webhook secret used by the Cloudflare relay; verifies the forwarded raw payload |
| `WEBHOOK_FORWARD_URL` | Cloudflare Worker | HTTPS web app webhook endpoint, currently `https://spaces.cloudcompute.com/api/webhooks/github` |
| `WORKSPACES_WEBHOOK_CANARY_SECRET` | Cloudflare Worker, Vercel, GitHub Actions | Shared canary-only secret for the dry-run ingress probe. It is separate from the GitHub webhook HMAC secret. |

### GitHub App setup

Reviews are posted by the `workspaces-pr-reviewer` GitHub App, which gives them a dedicated bot identity instead of being attributed to a personal account. To set up:

1. Create a GitHub App at https://github.com/settings/apps with permissions:
   `contents:read`, `pull_requests:write`, `statuses:write`; add
   `issues:write` if you want the broker to apply validated label suggestions
2. Install the app on `fairchild/workspaces` and note the installation ID
3. Set `PR_REVIEWER_APP_ID`, `PR_REVIEWER_PRIVATE_KEY`, and `PR_REVIEWER_INSTALLATION_ID` in Vercel
4. Confirm the Cloudflare relay has `WEBHOOK_FORWARD_URL` configured and that
   `GITHUB_WEBHOOK_SECRET` in Cloudflare matches
   `GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET` in Vercel

The app generates short-lived installation tokens (1-hour TTL) on demand. If
the App credentials are missing or token exchange fails, `triggerPrReview()`
skips the run and records/logs the failure instead of falling back to a PAT.

**How the token is used:** `triggerPrReview()` calls `resolveGitHubToken()`
which generates a short-lived installation token from the GitHub App
credentials. The token is passed to the Managed Agents `github_repository`
resource as `authorization_token` so Anthropic can clone the repository. It is
not written into the prompt or a filesystem token path for the agent to
discover. The token must be least-privilege and repo-scoped; the reviewer prompt
still forbids GitHub write APIs, and the server-side broker remains the only
component that posts reviews or labels.

**Security:** Never print App private keys or installation tokens to logs. Use
files or secret-manager flows, never standalone `echo`/`print` of credential
values.

### PR progress status

After the webhook route records a new reviewer run, it posts a pending commit
status named `WorkSpaces Managed Review` to the PR head SHA. This is the first
visible PR signal that the managed reviewer picked up the run. When the broker
posts the final GitHub review, it updates the same status context to `success`;
if broker processing fails before a review is posted, it updates the context to
`failure`.

The status details URL points to `/dashboard/review-runs/<fingerprint>`. That
authenticated page authorizes access to the stored repo, shows run metadata, and
streams the managed-agent transcript once the run records a session id.

The status is best-effort: a status API failure is logged but does not block the
review session or broker. A `403` on this request means the GitHub App is missing
the `statuses:write` permission.

### Health monitoring

ReviewRun rows are the source of truth for managed-reviewer health. Start with
`scripts/pr-reviewer-runs.py` or the protected
`/api/webhooks/github/pr-reviewer-monitor` route when diagnosing the queue. The
report groups rows into `starting`, `stuckStarting`, `running`,
`runningTooLong`, `completedAwaitingProjection`, `failedExecution`,
`projectionFailed`, `superseded`, and `published`, and includes pickup,
execution, and projection latency signals where the row has enough timestamps.

Interpret the ReviewRun report as:

- `healthy`: no missing coalesced ReviewRun keys and no row has breached an SLO
  or stored a failure.
- `degraded`: ReviewRuns are present and within SLO, but at least one completed
  run is awaiting GitHub projection.
- `unhealthy`: a coalesced ReviewRun key is missing, pickup/execution/projection
  SLOs have been breached, or an execution/projection failure is stored.

`.github/workflows/managed-reviewer-health.yml` runs the same split on a
schedule and can be dispatched manually. Its first job calls
`scripts/pr-reviewer-runs.py` with the protected canary secret and fails on
ReviewRun attention-needed state. Its second job calls
`scripts/pr-review-health.py` to audit GitHub-facing projection drift.

The projection audit checks recent open PRs for the `WorkSpaces Managed Review`
status, stale pending status, failure statuses, and success statuses that do not
have a current-head managed review. Older or draft PRs are reported but skipped
by default so pre-indicator branches do not keep the projection-audit job red
forever. Do not treat a green projection audit as proof that ReviewRun
ingestion, session execution, or broker projection is healthy.

The Cloudflare relay forwards only managed-review trigger candidates:
`pull_request.opened`, `reopened`, `ready_for_review`, `synchronize`, eligible
`edited` events, and evidence-bearing PR comments. It preserves the original
GitHub HMAC signature and raw body; the Vercel route independently verifies the
signature before creating any managed-agent session.

### Broker reconciliation

Completed managed-agent sessions are projected to GitHub by
`.github/workflows/managed-reviewer-broker.yml`, which runs
`scripts/pr-reviewer-broker.py` every five minutes. This workflow calls only the
protected broker route; it does not run the ingress canary or fail because the
monitor has unrelated historical attention items. A broker failure means a
completed ReviewRun could not be published or marked superseded.

## Ingress Contract And Canary

Reviewer ingress is covered by `.github/workflows/managed-reviewer-ingress.yml`.
The workflow runs when either side of the Cloudflare-to-Vercel contract changes:
the Worker relay, the web webhook route, the reviewer trigger parser, the shared
trigger fixtures, the ingress canary script, or the workflow itself. It runs:

- `pnpm exec vitest run src/app/api/webhooks/github/route.test.ts`
- `cd infra/cloudflare-webhook-relay && bun run test:e2e`
- `cd infra/cloudflare-webhook-relay && bun run --bun wrangler deploy --dry-run`
- `python3 scripts/managed-reviewer-ingress-canary.py --help`

The shared trigger fixture matrix lives in
`web/src/lib/agent-runtime/__tests__/pr-review-trigger-fixtures.ts` and is
imported by both the Vercel route tests and the Cloudflare relay e2e harness.
This is the regression guard for drift between "forward this webhook" and
"start the reviewer".

Production CD requires `WORKSPACES_WEBHOOK_CANARY_SECRET`, runs the ingress
canary before promotion, then repeats it in `validate-prod` after promotion
before the production Playwright smoke. That canary proves only relay delivery,
route HMAC validation, canary-secret validation, and dry-run trigger selection.
It does not broker completed runs or report queue health; the scheduled broker
and health workflows own live reviewer reconciliation failures.

The scheduled ingress workflow is a contract probe. It does not reconcile
completed runs and does not report queue health.

Production canary:

```bash
curl --fail-with-body -sS -X POST \
  https://webhooks.cloudcompute.com/canary/pr-review-ingress \
  -H "X-Workspace-Webhook-Canary: $WORKSPACES_WEBHOOK_CANARY_SECRET"
```

Broker reconciliation:

```bash
uv run --script scripts/pr-reviewer-broker.py --limit 5
```

Operator run report:

```bash
uv run --script scripts/pr-reviewer-runs.py
```

Use the report as the first read of production health. `missingRuns` means a
coalesced reviewer-eligible key did not create a `managed_pr_review_runs` row.
`running` means the managed-agent session has been created and remains inside
the execution SLO. `runningTooLong` means the session exceeded the execution
SLO. `completedAwaitingProjection` means the broker still needs to publish or
repair GitHub projection for a completed run. `failedExecution` and
`projectionFailed` separate managed-agent failures from GitHub projection
failures. Actionable run rows include details URLs for inspecting the stored
metadata and transcript.

The Worker requires `WORKSPACES_WEBHOOK_CANARY_SECRET`, signs a canonical
reviewer-eligible PR payload with `GITHUB_WEBHOOK_SECRET`, forwards it to the
Vercel webhook route with the canary header, and expects Vercel to return
`{ "canary": true, "wouldTrigger": true, "triggerKind": "opened" }`. The Vercel
route verifies the GitHub-style HMAC and the canary secret before returning the
dry-run result, and returns before `pushEvent()` or `triggerPrReview()` so no
managed-agent session or GitHub review is created.

The broker inspects `started` rows in `managed_pr_review_runs`, skips sessions
that are still running, validates completed review-intent JSON, and posts the
review with the GitHub App token. The row keeps two lifecycle fields: `status`
for the managed-agent run and `projection_status` for the GitHub-facing review
or failure projection. Before posting, the broker re-checks current managed
reviews on the PR; if another managed review was submitted after the session
started, the stale session is marked `superseded`. If a newer PR update was
coalesced into the active run, the broker suppresses the older completed output,
marks that run `superseded`, and starts exactly one follow-up session against the
latest PR state. If the superseding review is for an older head, the broker
starts a fresh follow-up session so the newer-head review includes the prior
review context. The run report compares recent
reviewer-eligible rows in `webhook_events` with coalesced ReviewRun keys from
`managed_pr_review_runs` records and classifies rows into source-of-truth health
buckets. Broker and report routes return only run metadata, details URLs, stored
failure reasons, and missing event identifiers, not raw payloads or secrets.

## Observing Sessions

### List recent sessions

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions?limit=5" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" | python3 -m json.tool
```

### Check a session's status and usage

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions/$SESSION_ID" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  | python3 -c "import sys,json; s=json.load(sys.stdin); print(f'status={s[\"status\"]} usage={json.dumps(s.get(\"usage\",{}))}')"
```

### Stream session events (tool calls + results)

```bash
source ~/.env && curl -s "https://api.anthropic.com/v1/sessions/$SESSION_ID/events" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: managed-agents-2026-04-01" \
  | python3 -c "
import sys, json
for e in json.load(sys.stdin).get('data', []):
    t = e.get('type','')
    if t == 'agent.message':
        for b in e.get('content', []):
            if b.get('type') == 'text': print(f'[msg] {b[\"text\"][:300]}')
    elif t == 'agent.tool_use':
        print(f'[tool] {e.get(\"name\",\"\")}: {json.dumps(e.get(\"input\",{}))[:200]}')
    elif t == 'agent.tool_result':
        parts = [b.get('text','')[:150] for b in e.get('content',[]) if b.get('type')=='text']
        if parts: print(f'[result] {parts[0]}')
    elif t.startswith('session.'):
        print(f'[{t}] {json.dumps(e.get(\"stop_reason\",{}))}')
    elif t == 'session.error':
        print(f'[error] {json.dumps(e.get(\"error\",{}))}')
"
```

### Check Vercel production logs

```bash
vercel logs --environment production --no-branch --since 5m --expand --json --level error 2>&1 \
  | python3 -c "
import sys, json
for line in sys.stdin:
    if not line.strip().startswith('{'): continue
    try:
        obj = json.loads(line)
        for l in obj.get('logs', []):
            msg = l.get('message','')
            if msg: print(msg[:300])
    except: pass
"
```

## Debugging

### Session created but repo empty

If using the GitHub App: check that `PR_REVIEWER_APP_ID`, `PR_REVIEWER_PRIVATE_KEY`, and `PR_REVIEWER_INSTALLATION_ID` are set correctly. The private key PEM must have real newlines (Vercel handles this, but verify with `vercel env pull`).

### Review not posted to GitHub

Check the session events for the final fenced `json` review intent, then check
Vercel logs for `[pr-review] broker failed`. Common causes:
- `WORKSPACES_WEBHOOK_CANARY_SECRET` is missing, so scheduled broker calls are not authenticated
- GitHub App token exchange failed — check Vercel logs for `[pr-review] GitHub App token failed`
- `PR_REVIEWER_ENABLED=0` is set
- the managed agent did not return valid fenced JSON with `event`, `body`, and `labels`
- API response `401` — App not installed on the repo, or installation token invalid
- API response `403` — App missing `pull_requests:write` permission
- API response `422` — review event/body was rejected by GitHub
- label application failures are logged as warnings and do not block posting the review

### Webhook fires but no session created

Check Vercel error logs. Common causes:
- `ANTHROPIC_API_KEY` not set (only in production, not preview)
- GitHub App credentials are missing or partial (`PR_REVIEWER_APP_ID`, `PR_REVIEWER_PRIVATE_KEY`, `PR_REVIEWER_INSTALLATION_ID`)
- Env var has a trailing newline (use `printf` not `echo` when setting)
- Webhook secret mismatch between GitHub and `GITHUB_WEB_WORKSPACES_WEBHOOK_SECRET`
- Anthropic returns `resources.0.authorization_token: Field required` — the
  `github_repository` session resource is missing the short-lived App
  installation token required for repository cloning

### Agent can't find the diff

The sandbox only checks out the PR branch. The agent needs to `git fetch origin main` before diffing. The system prompt instructs this, but if it fails, the git proxy may not have the base ref cached.

### `swift` not available in sandbox

Expected — the sandbox is Linux. The agent can still review Swift code (read, grep, explore) but can't compile or run tests. The web tests (TypeScript) work fine since Node.js is available.

## Evolving the Agent

### Change the system prompt

Edit `SYSTEM_PROMPT` in `web/src/lib/agent-runtime/pr-review.ts`. The hash-based cache means a new prompt automatically creates a new agent version — no manual cleanup needed.

### Add tools or MCP servers

Edit `TOOLS` or `MCP_SERVERS` arrays in `pr-review.ts`. Same cache behavior — config changes create a new agent.

### Triggers

The reviewer is **continuous**: it reruns on meaningful PR updates and carries
its own prior review state into each rerun so it can revise (or approve) a
stale `REQUEST_CHANGES` instead of repeating itself.

`classifyPrReviewTrigger()` in
`web/src/lib/agent-runtime/pr-review-trigger.ts` classifies webhook activity
before any ReviewRun claim or active-run coalescing happens. Only material
classifications become `parsePrReviewTrigger()` results and start or coalesce a
managed review run:

| Event | Action | Behavior |
|-------|--------|----------|
| `pull_request` | `opened` | Initial review (skip drafts) |
| `pull_request` | `reopened` | Rerun (skip drafts) |
| `pull_request` | `ready_for_review` | Rerun even when previous state was draft |
| `pull_request` | `synchronize` | Rerun on new head SHA (skip drafts) |
| `pull_request` | `edited` | Rerun when `changes.body` or `changes.base` is present; title-only and other metadata edits do not start sessions |
| `pull_request` | `labeled`, `unlabeled` | Metadata only; no managed-review session |
| `pull_request` | `closed` | Terminal PR activity; no managed-review session |
| `issue_comment` | `created` with evidence | Rerun when the comment is on a PR thread, the sender is a non-bot, and the body matches an evidence signal: `evidence.cloudcompute.com`, `Evidence:`, `swift test`, `playwright`, `screenshot`, `recording`, `validation` |
| `issue_comment` | `created` without evidence | Metadata only; no managed-review session |
| `pull_request_review_comment`, `pull_request_review` | any | Metadata only; no managed-review session |

Loop guards skip events from any `*[bot]` sender (including the reviewer
itself) and from `Bot`-typed senders.

### Idempotency

Every dispatch computes a fingerprint over
`(repo, pr, headSha, triggerKind, triggerSourceId, reviewerConfigHash)` and
inserts a row into `managed_pr_review_runs` (created on first use). The exact
fingerprint is still the idempotency key. Automatic triggers also claim one
active slot per `(repo, pr, reviewerConfigHash)` so body edits, evidence
comments, or new commits arriving while a same-config session is already active
update the active row's coalesced trigger fields instead of creating another
managed-agent session. The row is the source of truth for both lifecycles:
`status` tracks the managed agent, while `projection_status` tracks whether the
broker has projected the result back to GitHub. The skip decision honors the
prior run's agent status so failed/crashed dispatches stay retriable:

- `completed` → skip; the previous run already produced a review.
- `superseded` → skip; a later managed review intentionally covered this run.
- `failed` → reset and proceed; lets a redelivery (or a follow-on event with
  the same fingerprint) recover from a transient session-create failure.
- fresh `started` → skip (in-flight).
- stale `started` (older than 15 minutes) → reset and proceed; the prior
  process likely crashed before recording a result.

Effects:

- Webhook redeliveries for the same trigger are no-ops.
- A new commit changes `headSha` → new fingerprint → rerun.
- Distinct body edits and evidence comments on the same head produce distinct
  `triggerSourceId` values. If no same-config run is active, each material
  trigger runs once. If a run is active, material triggers coalesce into that
  run and the broker starts one follow-up against the latest PR state.
- Metadata-only activity such as title edits, label changes, non-evidence
  comments, review comments, and PR closure does not create or coalesce managed
  review runs.
- A reviewer prompt or model change rotates `reviewerConfigHash`, allowing a
  re-evaluation of the same head without manual intervention.

### Same-PR review history in the kickoff

For any rerun (`kind !== "opened"`), the runtime fetches the bot's prior
reviews on the current PR via `GET /repos/{owner}/{repo}/pulls/{pr}/reviews`,
keeps the newest 3, and includes them as untrusted context inside a
`<untrusted-content name="prior-managed-reviews">` block. A small trusted
instruction tells the reviewer to approve when a prior `REQUEST_CHANGES`
blocker is now resolved by the current body, comments, or commits.

### Follow-up kickoff shape

On reruns the kickoff is shaped so the agent behaves like a human reviewer
returning to a PR they've already touched, not like a fresh reviewer:

- **Stance** — opens with "You reviewed this PR before. New activity has
  landed since your last review. Your job is to check whether the author
  addressed your prior blockers and to surface anything new the new activity
  introduces."
- **Anchor commit** — when the most recent prior review's `commit_id` differs
  from the current head, the kickoff names it as the anchor and gives
  concrete commands: `git fetch origin <anchor>`, `git log --oneline
  <anchor>..HEAD`, `git diff <anchor>..HEAD`. The agent runs these itself —
  no diff blob is shipped in the prompt.
- **Output format** — a `## Follow-up review format` trailer overrides the
  base format on these points:
  - Decision banner uses follow-up phrasing (e.g. `✅ **Approve** — Prior
    blockers addressed; nothing new of concern.`,
    `🛑 **Request changes** — Prior blocker on file:line still
    unaddressed.`).
  - Add a `## Changes Since Last Review` section under `## Summary` with
    `**Resolved:**` and `**New:**` sub-bullets.
  - `## Project Thread` is optional on reruns — the thread is already
    established.
  - If the prior review's only blocker was missing evidence and the new
    activity supplies it, approve and credit the evidence URL.
- **Session naming** — `sessions.create` uses a `Re-review PR #N: <title>`
  title and stamps `metadata.run_kind = "follow-up"` so operator tooling can
  distinguish initial from follow-up sessions at a glance.

When `kind !== "opened"` but the prior-review fetch returns no managed
reviews (e.g. GitHub API failure, or the bot crashed before posting),
the kickoff still applies the follow-up output trailer but skips the
anchor block — the run identifies itself as "a rerun without a recoverable
prior review on this PR" so the agent reviews defensively rather than
inventing a fake anchor.

### Filter by repo or label

Add conditions inside `parsePrReviewTrigger()` in the webhook route, e.g.:

```ts
// Only review PRs in specific repos
if (String(repoObj.full_name) !== "fairchild/workspaces") return null;

// Only review PRs with a specific label
const labels = pr.labels as Array<{name: string}> | undefined;
if (!labels?.some((l) => l.name === "review-wanted")) return null;
```

### Cost control

Set `PR_REVIEWER_MODEL=claude-sonnet-4-6` for cheaper reviews on routine PRs. Use Opus for complex changes by checking diff size in the webhook handler.

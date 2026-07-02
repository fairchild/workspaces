---
status: proposed
category: plan
---

# Web Next Cycle Plan — 2026-07

Execution plan for the next round of `web/` work, grounded in a 2026-07-02 read of
the roadmap, milestone #7, the open `web`-labeled issues, and the actual `web/` tree.
Each workstream is scoped so a cold session or subagent can pick it up: context,
files, steps, acceptance, and verification are inline. Follow the repo's standing
merge gates (evidence via `./scripts/evidence.sh`, `mise run web:check`, LEDGER
updates for new behaviors).

## Grounding: issue state vs code state

The tracker is staler than the code. Three open issues are already implemented;
the real gaps are narrower than the open-issue list suggests.

| Issue | Tracker state | Code reality (verified 2026-07-02) | Action |
|---|---|---|---|
| [#543](https://github.com/fairchild/workspaces/issues/543) CD deployment-smoke lane | open, needs-triage | **Shipped.** `deployment-smoke` Playwright project (`web/playwright.config.ts:38`), specs in `web/e2e/deployment-smoke/`, wired into `cd.yml` `playwright-validate` (line 184) + `validate-prod` (line 393) + `web-preview.yml` (line 185), findings artifact + `fail-notify-playwright` | Verify + close (W0) |
| [#535](https://github.com/fairchild/workspaces/issues/535) cross-tenant authz E2E | open, needs-triage | **Shipped.** `web/e2e/fast/api-authorization.spec.ts` covers all 8 cases from the issue table; LEDGER rows dated 2026-05-03 | Verify + close (W0) |
| [#545](https://github.com/fairchild/workspaces/issues/545) PR reviewer continuous reruns | open, P1 | **Phases 1–3 shipped.** `pr-review-trigger.ts` classifies opened/reopened/ready_for_review/synchronize/body_edit/evidence_comment with bot-sender + draft guards; `pr-review-runs.ts` owns durable fingerprinted run state; `fetchCurrentPrReviewHistory` (`pr-review.ts:467`) injects prior reviews. Residue to confirm: manual rerun command (phase 4), `PR_REVIEWER_RERUNS_ENABLED` flag posture (phase 5) | Verify residue, close or split (W0) |
| [#522](https://github.com/fairchild/workspaces/issues/522) Cloudflare provider scaffold | open | **Resolved.** Scaffold deleted in PR #321 (`web/docs/architecture.md` records it) | Close (W0) |
| [#541](https://github.com/fairchild/workspaces/issues/541) middleware session freshness | open, P1 · ms7 | **Real.** `web/src/middleware.ts:43-50` gates only on cookie presence; expired tokens pass middleware and bounce at layout `getSession()` | Implement (W1) |
| [#536](https://github.com/fairchild/workspaces/issues/536) DOM component test harness | open, needs-triage | **Real.** `web/vitest.config.ts` is `environment: "node"` only; no DOM harness, no component tests anywhere | Implement (W2) |
| [#540](https://github.com/fairchild/workspaces/issues/540) Chat SDK keep-or-retire | open, decision · ms7 | **Decision ready — see brief below.** The SDK is a dead island: `bot.ts` + `ai.ts` + `slack-notifications.ts` are reachable only via the 501-stubbed `api/webhooks/[platform]` route (the sole TODO in all of `web/src`). The live dashboard Chat tab (`chat-panel.tsx`, `api/chat/*`, 16 LEDGER rows) does **not** use the SDK | Decide + execute (W3) |
| [#539](https://github.com/fairchild/workspaces/issues/539) responsive layout | open, P2 · ms7 | **Real.** Sidebar `display: none` <640px, activity feed <960px, no escape hatch | Implement (W4) |
| [#521](https://github.com/fairchild/workspaces/issues/521) / [#524](https://github.com/fairchild/workspaces/issues/524) terminal quality | open | Not re-verified this pass | Groom in W5 |

Also in scope: correct the three stale rows in `backlog/ROADMAP.md` (done in the PR
that lands this plan) and refresh `web/tests/LEDGER.md` verified dates as suites run.

---

## Workstream 0 — Ledger reconciliation (close shipped work)

*Size: S. Parallelizable. No product code changes. Highest information-per-token: it
shrinks the apparent backlog by four issues and stops future sessions re-planning
shipped work.*

Per issue:

1. **#535** — run `cd web && pnpm run test:e2e:fast -- api-authorization` (or
   `mise run web:e2e -- api-authorization`). All 8 cases green → upload the run
   output via `evidence.sh`, comment the evidence link + file/spec mapping on the
   issue, close as completed. Update LEDGER `Verified` dates.
2. **#543** — confirm the acceptance items against `cd.yml`/`web-preview.yml`
   (project exists, validators use `--project deployment-smoke`, JSON report +
   findings artifact on failure). Run the smoke against prod
   (`PLAYWRIGHT_BASE_URL=… PLAYWRIGHT_SKIP_WEB_SERVER=1 PLAYWRIGHT_SKIP_DB_FIXTURES=1 pnpm exec playwright test --project deployment-smoke`)
   if a base URL + bypass secret are available; otherwise cite the latest green
   `cd.yml` run. Comment + close. Any diagnostics residue from phase 2 of the issue
   (skipped counts in `playwright-findings.js`) that's genuinely missing becomes a
   small follow-up issue, not a reason to hold #543 open.
3. **#545** — grep-verify phases 4–5: is there a trusted manual-rerun path
   (`/pr-reviewer rerun` comment command or protected route)? Is
   `PR_REVIEWER_RERUNS_ENABLED` (or equivalent) checked anywhere, and what is the
   current default? If both exist, close with a mapping comment (phase → file:line).
   If only 4 or 5 is missing, close #545 as substantially-shipped and file a narrow
   follow-up for the missing phase. Do not reopen design questions the shipped code
   already answered.
4. **#522** — comment that the scaffold was deleted in PR #321 (link the PR and
   `web/docs/architecture.md` note), close as completed.

Acceptance: four issues closed (or narrowly re-filed), LEDGER dates refreshed,
no code changes beyond LEDGER/docs.

---

## Workstream 1 — #541: middleware session freshness (P1, security)

*Size: M. The top open milestone-7 item. Do this before W4 UI work.*

**Problem.** `web/src/middleware.ts` redirects on missing cookie only. An expired or
garbage session token passes middleware, renders the app shell, then bounces at
layout `getSession()` — an extra load cycle, and middleware provides no real gate.

**Approach (investigate in order, pick the first that holds):**

1. **Better Auth cookie cache** — Better Auth 1.6.x supports a signed, short-TTL
   `session_data` cookie (`session.cookieCache`). Middleware can verify
   signature + `expiresAt` edge-side without a DB read via
   `getCookieCache(request)`. Confirm the installed version exposes an
   edge-compatible helper and that enabling the cache doesn't change session
   semantics elsewhere (sign-out revocation latency ≤ cache TTL is the known
   trade-off — keep TTL ≤ 5 min).
2. **Fallback** — verify the session token's HMAC signature + expiry directly in
   middleware using `better-auth`'s cookie utilities (edge-safe, no Node crypto
   dependency issues under the Edge runtime).
3. **Last resort** — `auth.api.getSession` in middleware is a full DB round-trip
   per request; only acceptable if scoped to page navigations (skip static/API
   paths) and measured. Prefer 1 or 2.

**Constraints.**

- Preserve existing behavior: `PUBLIC_PATHS`, `/docs` rewrite, `DEV_BYPASS_AUTH`
  gate, `callbackUrl` param on redirect.
- Fail-open on verification *errors* (malformed cookie → redirect to sign-in;
  transient verification failure → let layout `getSession()` decide) — middleware
  must never take the whole app down.
- Keep the middleware edge-runtime compatible (no Node-only imports).

**Files.** `web/src/middleware.ts`, possibly `web/src/lib/auth.ts` (cookie-cache
option), tests.

**Tests.**

- Unit: extract the freshness check into a pure helper
  (`web/src/lib/session-cookie.ts` or similar) and cover: valid+fresh passes,
  expired redirects, bad signature redirects, absent redirects, malformed
  redirects.
- E2E (`e2e/fast/`): a spec seeding an expired/forged session cookie asserting the
  redirect happens *from middleware* (assert on the redirect response of the
  document request — no dashboard HTML flash). Extend
  `unauth-redirect.spec.ts` rather than adding a new file if it fits.
- LEDGER rows for the new behaviors.

**Acceptance.** Expired token → single redirect at middleware; fresh token →
unchanged; `mise run web:check` + `test:e2e:fast` green; evidence uploaded.

---

## Workstream 2 — #536: DOM component regression lane

*Size: M. Independent of W1; safe to run in parallel in a separate worktree.*

**Problem.** Two real dashboard bugs (MainPanel hook-order violation, stale
repo-switch fetches) had no automatable home: Vitest runs node-only and Playwright
is too coarse for effect/race behavior.

**Steps.**

1. Split `web/vitest.config.ts` into two projects: `unit` (node, existing globs
   unchanged) and `component` (`environment: "jsdom"` — or `happy-dom` if jsdom
   fights Next 15/React 19; decide once, note in config comment), scoped to
   `src/**/__tests__/*.test.tsx`.
2. Add dev deps via `mise run web:deps -- <pkg>`: `jsdom`,
   `@testing-library/react`, `@testing-library/user-event` (skip
   `@testing-library/jest-dom` unless matchers are genuinely needed).
3. `web/src/test/` helpers: render wrapper with any required providers, fetch/mock
   utilities for repo-scoped endpoints, a `deferred()` helper for race tests.
4. Three initial tests (from the issue, they map to real past bugs):
   - `main-panel.test.tsx` — loading/error/empty → loaded transition renders
     without hook-order errors (assert no React warning via console spy).
   - `dashboard-shell.test.tsx` — switch repo while a fetch is in flight; the
     newest repo's data wins.
   - `activity-feed.test.tsx` — `filterRepo` change prevents a stale poll result
     from rendering.
5. Wire `pnpm test` to run both projects; confirm `web-ci.yml` picks them up with
   no workflow change (it runs `pnpm test`).

**Acceptance.** Both lanes green in one `pnpm test` run; deliberately re-breaking
one covered bug (e.g. reorder the MainPanel early-return) fails the matching test;
LEDGER rows added; existing node tests untouched.

---

## Workstream 3 — #540: Chat SDK decision (needs Michael) + execution

*Size: decision + S/M execution. The decision is Michael's; the brief below is the
prepared input. Blocked-on-human is the only gate.*

**Decision brief.** The June grooming comment corrected itself once already
(unbuilt → built). The precise current state is between those readings:

- **Live and SDK-free:** the dashboard Chat tab — `chat-panel.tsx`,
  `api/chat/{messages,dispatch,agent-stream}`, GitHub Discussion bridge,
  `chat_messages` table, 16 LEDGER rows of e2e coverage. None of it imports the
  Chat SDK.
- **Dead island (SDK-dependent):** `src/lib/bot.ts` (GitHub/Slack adapters),
  `src/lib/ai.ts` (only imported by bot.ts; type-only SDK import),
  `src/lib/slack-notifications.ts` (imports bot.ts; itself has **zero**
  importers), and `api/webhooks/[platform]/route.ts` which returns 501 with the
  repo's only TODO ("re-enable chat bot integration in next PR").
- **Cost of the island:** 4 deps (`chat`, `@chat-adapter/{github,slack,state-memory}`),
  ~3 modules + a route of reviewer surface, and a recurring source of planning
  confusion (this is the third session to re-litigate it).

**Recommendation: retire the island, keep the Chat tab.** The product converged on
agent runtime + managed reviewer + terminal; multi-platform bot intake has been
501-stubbed for months with no demand signal. Removal is small and reversible via
git history.

**Ask Michael:** "Chat SDK: retire the disabled bot path (bot.ts, ai.ts,
slack-notifications.ts, `[platform]` route, 4 deps — dashboard Chat tab unaffected),
or is Slack/GitHub bot intake still on the product path?" If retire:

1. Delete `bot.ts`, `slack-notifications.ts`, `api/webhooks/[platform]/`; delete
   `ai.ts` or inline its `AiMessage` type if anything still wants `streamResponse`
   (nothing does today).
2. Remove the 4 deps from `web/package.json` (via `mise run web:deps` conventions),
   refresh lockfile.
3. Sweep docs: `web/docs/architecture.md` chat section, root `CLAUDE.md` tech-stack
   line if it names Chat SDK, LEDGER (Chat tab rows stay — they cover the surviving
   surface).
4. Close #540 with the removal PR; also close the March `stale`-tagged chat-bot
   cluster (#174 etc.) referencing the decision.

If build-on-it instead: re-scope #174 (wire GitHub adapter) as the first slice and
pull it into ms7 — but that's a product bet, not debt cleanup, and should displace
something.

**Verification (retire path).** `mise run web:check`, full e2e (`fast` + `full`
chat specs stay green), bundle diff noted in PR body (deps removed), grep proves
no dangling imports.

---

## Workstream 4 — #539: responsive layout (P2)

*Size: M. UI change → screenshot evidence required. Do after W2 exists so new
layout behavior gets component/e2e coverage, and after #541 so the security P1
isn't queued behind polish.*

**Pick option 1 from the issue (hamburger drawer + reachable activity feed),
stacked-column fallback where simpler.** Discoverability over polish, per the issue.

- Sidebar <640px: hamburger in the top bar → overlay drawer (focus-trapped,
  Escape closes, `aria-expanded`).
- Activity feed <960px: reachable via a toggle/tab rather than `display: none`
  (bottom bar or segmented control — smallest native-feeling option; propose in
  the PR with screenshots at 375×667 and 768×1024).
- CSS Modules + existing custom properties; no new styling system.
- Tests: component tests for drawer open/close/focus (W2 lane); e2e viewport spec
  covering "sidebar reachable at 375px"; retire the LEDGER P2 mobile-viewport gap
  rows.

**Acceptance.** No horizontal scroll at 375px; sidebar + feed both reachable;
desktop ≥960px pixel-unchanged (spot-check screenshots); evidence uploaded.

---

## Workstream 5 — Terminal/runtime quality grooming (opportunistic)

*Size: S per item. Not milestone work; pick up when a session has spare capacity.*

- **#521** (Sandbox.get per session per poll): measure first — count reconciliation
  calls per dashboard-minute at one active session; only optimize if the number is
  real. Route the finding through the issue before coding.
- **#524** (`agent_name` → `session_kind` discriminator): schema + call-site
  refactor; needs `web/docs/schema-management.md` review and a migration story.
  Re-scope on the issue before implementing.
- **LEDGER P1 gaps** (error states: sandbox-provisioning failure, SSE disconnect
  reconnection; dashboard color-contrast): run `/qa author` for the two error-state
  behaviors; the contrast fix is a small CSS change + axe re-run.
- The `idea`-labeled terminal cluster (#523/#525/#526/#527/#528/#529) stays parked.

---

## Sequencing

| Wave | Work | Parallelism |
|---|---|---|
| 1 (now) | W0 issue reconciliation + ROADMAP row corrections | 4 independent subagent tasks, no worktree needed (comments/closures only) |
| 2 | W1 (#541) and W2 (#536) | 2 subagents, separate worktrees — zero file overlap (middleware/auth vs vitest/components) |
| 3 | W3 decision → execution; W4 (#539) after the ask | W3-execute and W4 can run in parallel (deps/bot files vs dashboard CSS/components) |
| 4 | W5 grooming | fill-in |

Standing rules for every implementing agent: work from a fresh worktree branch;
`mise run web:check` before any PR; evidence uploaded via `evidence.sh` (test
output always, screenshots for W4); update `web/tests/LEDGER.md` when behavior
coverage changes; PR bodies follow `.github/pull_request_template.md` with the
Mergeability section filled honestly.

## Explicitly out of scope this cycle

- Daytona / GitHub Actions providers (deliberate stubs; no demand signal).
- Terminal `idea` cluster (#523–#529 except the two groomed above).
- New agent-automation surfaces (roadmap gate unchanged: prove throughput first).
- Desktop tile-tree P6 "web through the seam" — that's desktop-milestone work even
  though it touches web views.

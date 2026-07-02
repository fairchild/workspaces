# Test Ledger — web/

A behavior → test mapping. The `qa-web-agent` reads this at the start of every run to know what's covered, and updates it at the end.

**Measure coverage by the column labeled "Behaviors verified this week," not by line-coverage %.** Line coverage says nothing about whether users can do what they need to do.

## How to read this file

Each row is a *user-visible behavior*. Columns:

- **Behavior** — the oracle, stated in plain English (what a user can do or observe).
- **Layer** — `unit` (Vitest, `web/src/**/__tests__/*.test.ts`), `e2e-deployment-smoke`, `e2e-fast`, `e2e-full`, `e2e-demo`, `e2e-explore`, or `manual`.
- **Test** — file path + test name, or `—` if not yet automated.
- **Verified** — ISO date the test last ran green in CI. `—` if not automated.
- **Owner** — who cares if this breaks. `qa-web-agent` is allowed as an owner, meaning the agent is responsible for keeping it green.

Add a `[gap]` row for behaviors you know matter but aren't yet tested. `qa-web-agent` prioritizes these during Phase 1 and Phase 2.

## Automated behaviors (seeded from existing suite — 2026-04-17)

### Landing & auth

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| Landing page loads with Spaces branding | e2e-fast | `fast/landing.spec.ts :: loads with Spaces branding` | 2026-04-17 | qa-web-agent |
| Deployed app serves landing, sign-in, docs, auth redirect, and unauth sync boundary | e2e-deployment-smoke | `deployment-smoke/app.spec.ts :: Deployment smoke` | 2026-06-27 | qa-web-agent |
| `POST /api/workspaces/sync` rejects unauthenticated requests | e2e-fast | `fast/unauth-api.spec.ts :: POST /api/workspaces/sync without auth returns unauthorized` | 2026-04-17 | qa-web-agent |
| `GET /dashboard` redirects unauthenticated users to sign-in | e2e-fast | `fast/unauth-redirect.spec.ts :: GET /dashboard without auth redirects to sign-in` | 2026-04-17 | qa-web-agent |

### API authorization

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| `GET /api/events?repo=...` rejects a repo owned by another user | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/events?repo rejects another user's repo` | 2026-07-02 | qa-web-agent |
| `GET /api/events/:id` rejects an event from another user's repo | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/events/:id rejects an event from another user's repo` | 2026-07-02 | qa-web-agent |
| `GET /api/events` rejects requests without a valid session | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/events without a valid session returns unauthorized` | 2026-07-02 | qa-web-agent |
| `GET /api/events/stats` rejects requests without a valid session | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/events/stats without a valid session returns unauthorized` | 2026-07-02 | qa-web-agent |
| `GET /api/chat/messages?repo=...` rejects a repo owned by another user | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/chat/messages rejects another user's repo` | 2026-07-02 | qa-web-agent |
| `GET /api/repos/:owner/:repo/agents` rejects a repo owned by another user | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/repos/:owner/:repo/agents rejects another user's repo` | 2026-07-02 | qa-web-agent |
| `GET /api/repos/:owner/:repo/webhook-status` rejects a repo owned by another user | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/repos/:owner/:repo/webhook-status rejects another user's repo` | 2026-07-02 | qa-web-agent |
| `GET /api/managed-agents/transcript` rejects a managed-agent session for an unauthorized repo | e2e-fast | `fast/api-authorization.spec.ts :: GET /api/managed-agents/transcript rejects a session for an unauthorized repo` | 2026-07-02 | qa-web-agent |

### Dashboard

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| Dashboard loads with tab bar for authenticated user | e2e-full | `full/dashboard.spec.ts :: loads dashboard page with tab bar` | 2026-04-17 | qa-web-agent |
| Sidebar shows seeded repo | e2e-full | `full/dashboard.spec.ts :: shows sidebar with seeded repo` | 2026-04-17 | qa-web-agent |
| Clicking a repo navigates to repo detail | e2e-full | `full/dashboard.spec.ts :: navigates to repo detail` | 2026-04-17 | qa-web-agent |

### Chat tab

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| Tab switching updates URL and returns correctly | e2e-full | `full/chat.spec.ts :: tab switching updates URL and returns` | 2026-04-17 | qa-web-agent |
| Chat tab autofocuses the compose input | e2e-full | `full/chat.spec.ts :: chat tab autofocuses compose input` | 2026-04-17 | qa-web-agent |
| Direct navigation to chat tab works | e2e-full | `full/chat.spec.ts :: direct navigation to chat tab works` | 2026-04-17 | qa-web-agent |
| Placeholder and send button render | e2e-full | `full/chat.spec.ts :: shows placeholder and send button` | 2026-04-17 | qa-web-agent |
| Helper text renders | e2e-full | `full/chat.spec.ts :: shows helper text` | 2026-04-17 | qa-web-agent |
| Send button disabled when input empty | e2e-full | `full/chat.spec.ts :: send button is disabled when input is empty` | 2026-04-17 | qa-web-agent |
| Typing enables the send button | e2e-full | `full/chat.spec.ts :: typing enables send button` | 2026-04-17 | qa-web-agent |
| Shift+Enter inserts newline instead of sending | e2e-full | `full/chat.spec.ts :: shift+enter adds newline instead of sending` | 2026-04-17 | qa-web-agent |
| Timeline shows day separators between days | e2e-full | `full/chat.spec.ts :: shows day separators between different days` | 2026-04-17 | qa-web-agent |
| Messages show author + content | e2e-full | `full/chat.spec.ts :: shows chat messages with author and content` | 2026-04-17 | qa-web-agent |
| Agent messages use accent styling | e2e-full | `full/chat.spec.ts :: agent messages have accent styling` | 2026-04-17 | qa-web-agent |
| Agent author name styled differently from user | e2e-full | `full/chat.spec.ts :: agent author name is styled differently from user` | 2026-04-17 | qa-web-agent |

### Agent chat (mock provider)

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| @agent message returns a mock response | e2e-full | `full/agent-chat.spec.ts :: sends @agent message and receives mock response` | 2026-04-17 | qa-web-agent |
| Follow-up message reuses same threadId | e2e-full | `full/agent-chat.spec.ts :: follow-up message sends same threadId` | 2026-04-17 | qa-web-agent |
| Second message restores from snapshot | e2e-full | `full/agent-chat.spec.ts :: second message restores from snapshot (same session)` | 2026-04-17 | qa-web-agent |
| Agent response persists across reload | e2e-full | `full/agent-chat.spec.ts :: agent response persists in timeline after page reload` | 2026-04-17 | qa-web-agent |

### Terminal tab

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| Terminal tab present in tab bar | e2e-full | `full/terminal.spec.ts :: tab bar shows Terminal tab` | 2026-04-17 | qa-web-agent |
| Clicking Terminal tab updates URL | e2e-full | `full/terminal.spec.ts :: clicking Terminal tab updates URL` | 2026-04-17 | qa-web-agent |
| Direct navigation to terminal tab works | e2e-full | `full/terminal.spec.ts :: direct navigation to terminal tab works` | 2026-04-17 | qa-web-agent |
| Tab-switch round trip preserves state | e2e-full | `full/terminal.spec.ts :: tab switching round-trip preserves state` | 2026-04-17 | qa-web-agent |
| Cmd+3 switches to Terminal tab | e2e-full | `full/terminal.spec.ts :: Cmd+3 switches to Terminal tab` | 2026-04-17 | qa-web-agent |
| Start button shown when no sandbox active | e2e-full | `full/terminal.spec.ts :: shows start button when no sandbox active for selected agent` | 2026-04-17 | qa-web-agent |
| Select-repo message when no repo selected | e2e-full | `full/terminal.spec.ts :: shows select-repo message when no repo selected` | 2026-04-17 | qa-web-agent |
| Paused session appears as sub-tab with Resume | e2e-full | `full/terminal.spec.ts :: paused session from seed appears as sub-tab with Resume button` | 2026-04-17 | qa-web-agent |
| Sub-tab click updates `?agent=` URL param | e2e-full | `full/terminal.spec.ts :: clicking sub-tab updates ?agent= URL param` | 2026-04-17 | qa-web-agent |
| Agent param persists Terminal → Chat | e2e-full | `full/terminal.spec.ts :: agent param persists across Terminal → Chat tab switch` | 2026-04-17 | qa-web-agent |
| Chat tab shows agent sub-tabs incl. `all` | e2e-full | `full/terminal.spec.ts :: chat tab shows agent sub-tabs and includes 'all'` | 2026-04-17 | qa-web-agent |
| Chat `all` sub-tab clears agent URL param | e2e-full | `full/terminal.spec.ts :: chat 'all' sub-tab clears the agent URL param` | 2026-04-17 | qa-web-agent |

### Unit-level invariants (selected)

| Behavior | Layer | Test | Verified | Owner |
|---|---|---|---|---|
| Chat timeline utilities group events correctly | unit | `src/lib/__tests__/timeline-utils.test.ts` | 2026-04-17 | qa-web-agent |
| Stream JSON parser handles partial frames | unit | `src/lib/__tests__/stream-json-parser.test.ts` | 2026-04-17 | qa-web-agent |
| Managed-agents session manager honors lifecycle | unit | `src/lib/agent-runtime/__tests__/session-manager.test.ts` | 2026-04-17 | qa-web-agent |
| Vercel sandbox adapter provisions and restores | unit | `src/lib/agent-runtime/__tests__/vercel-sandbox.test.ts` | 2026-04-17 | qa-web-agent |
| GitHub token plumbing rejects expired tokens | unit | `src/lib/__tests__/github-token.test.ts` | 2026-04-17 | qa-web-agent |

## Known gaps (candidates for qa-web-agent to address)

| Behavior | Why it matters | Priority |
|---|---|---|
| `[gap]` Accessibility: every primary page has zero axe-critical violations | a11y is user-blocking for AT users; `@axe-core/playwright` can catch ~30–40% automatically | P1 |
| `[gap]` Dashboard has zero *serious* a11y violations (found 3 color-contrast on 2026-04-18) | color-contrast blocks low-vision users from reading critical instructions; see `output/qa-agent/2026-04-18/dashboard-a11y/finding.md` | P1 |
| `[gap]` Error states: agent-chat when sandbox provisioning fails | current tests only cover happy path via mock provider | P1 |
| `[gap]` Error states: terminal when SSE stream disconnects mid-session | reconnection behavior is unverified | P1 |
| `[gap]` Mobile viewport (375×667) for dashboard, chat, terminal | no mobile tests exist yet | P2 |
| `[gap]` Slow-network / timeout behavior for chat compose | user expectation unclear when send hangs | P2 |
| `[gap]` Visual regression baseline for dashboard + chat + terminal | catches accidental CSS regressions; deferred until Explore/Author loop is stable | P3 |
| `[gap]` Keyboard navigation end-to-end (Tab, Escape, Enter) on dashboard | a11y-adjacent, not covered | P2 |
| `[gap]` Empty-state copy is accurate when no repos are connected | copy drift breaks first-run UX | P2 |

## Weekly rollup (append below, one line per week)

_Format: `YYYY-MM-DD — behaviors verified: N — new gaps: M — escaped defects: K (list)`_

- 2026-04-17 — ledger seeded from existing suite — behaviors verified: 37 — new gaps logged: 8 — escaped defects: 0
- 2026-04-18 — first `/qa` run (bare, on `qa-web-agent` branch) — behaviors verified: +2 (landing + dashboard zero axe-critical) — new gaps logged: 1 (dashboard color-contrast, 3 elements) — escaped defects: 0

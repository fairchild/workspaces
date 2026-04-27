---
status: in-progress
category: plan
---

# Workspaces Roadmap

## Vision

Build the best Mac-native control surface for terminal-based coding agents:

- select the right repo or workspace quickly
- keep long-lived terminal context intact
- attach the minimum useful chrome around that terminal
- add remote runtimes and activity feeds only when they make that workflow more reliable

This roadmap is grounded in the current codebase and recent releases, not older MVP assumptions.

---

## Current State

Workspaces now spans three surfaces — a Mac-native app, a web dashboard, and an agent-automation track. Each surface carries its own complexity and its own hardening agenda.

**Desktop app.** Terminal-first main window with repo overview and persistent repo/workspace terminals. Calmer repo-first sidebar with explicit sorting and per-window last-surface restoration. Ghostty-backed terminal with split/focus/resize/equalize and working shortcut routing. Local workspaces plus Lume and Daytona provider tracks, including host-side validation and setup flows for Lume. Notification/auth/activity infrastructure, workspace process monitoring, and agent-awareness in repo overview cards. A canonical performance system (`workspaces-performance-system` skill + `config/performance/contract.json`) enforces scenario budgets across debug, installed, release, and CI environments.

**Web dashboard** (`web/`). Next.js 15 on Vercel with GitHub OAuth (Better Auth) and LibSQL+Kysely persistence. A ghostty-web terminal tab and a TerminalShare Cloudflare Worker proxy. A multi-provider agent runtime now covering Vercel Sandbox, Cloudflare Sandbox, Daytona, GitHub Actions, and Anthropic Managed Agents (#332). Persistent-sandbox snapshot/restore for conversation continuity (#277); tmux inside the sandbox for real resume continuity (#311/#312/#315, clarified in #324). Automated PR review posted by Managed Agents (#345). Preview → validate → promote CD pipeline with a bootstrap orchestrator (#344). PostHog telemetry (#336). A `qa-web` skill + subagent (#343) covers black-box exploratory testing, author-mode spec generation, and heal-mode regression-vs-selector-drift triage.

**Agent automation.** The `.agents/skills/` library (`workspaces-performance-system`, `workspaces-optimization`, `drive`, `peter-planner`, `gh-discuss`, and others). April agent workflow runs on a Lume self-hosted runner. Most autonomous automations are currently gated off behind `AGENT_AUTOMATIONS_ENABLED`, pending runner policy and prompt-injection defense hardening.

**Shipping cadence.** Weekly-ish releases. Latest release `v0.10.0`.

What this means for planning.

- The product is three surfaces, not one, and they do not age at the same rate.
- The highest risk is now complexity management and determinism across surfaces, not raw feature absence.
- Terminal-first remains the product's core promise; everything else is in service of that, including the web and agent surfaces.
- Performance has moved from crisis to system. Ongoing measurement via the canonical contract is the norm, not a fire drill.

---

## Shipped Baseline

Treat these as baseline capabilities. They may need hardening, but they are not net-new scope.

Desktop:

- repo overview as the primary repo surface; scoped web views at global, repo, and workspace levels
- persistent repo/workspace terminal sessions
- Ghostty split/focus/resize/equalize for the two-pane model
- open-in-editor hardening and launch metrics
- workspace provider registry with active Lume and Daytona tracks
- release/signing/notarization via the `signing-host` runner
- canonical performance system with scenario budgets and installed-build parity

Web:

- dashboard with repo browsing, workspace/agent activity feeds, and terminal attachment
- ghostty-web terminal tab; TerminalShare Cloudflare Worker proxy
- multi-provider agent runtime (Vercel Sandbox, Cloudflare Sandbox, Daytona, GitHub Actions, Anthropic Managed Agents)
- persistent sandbox snapshot/restore; tmux-in-sandbox for resume continuity
- automated PR review via Managed Agents
- preview → validate → promote CD pipeline with bootstrap orchestrator
- PostHog telemetry
- qa-web skill + subagent (explore/author/heal phases)
- GitHub OAuth via Better Auth; LibSQL+Kysely persistence

Agent automation:

- shared `.agents/skills/` library
- April agent on a Lume self-hosted runner
- evidence workflow via Cloudflare R2 + `scripts/evidence.sh`
- notification relay via Cloudflare Worker + Durable Object

---

## Product Goals

### Goal 1: Keep the core loop excellent

The core loop is: choose context, get a ready terminal, inspect files/changes, continue work without surprise.

Success means:

- launch/restore is boring and predictable
- session reuse and focus stay correct under rapid switching
- sidebar and repo overview stay calm as capabilities grow

### Goal 2: Make remote runtimes trustworthy

Remote and VM-backed workspaces are part of the product direction, but only if they feel as dependable as local.

Success means:

- provider identity/state is explicit and not leaky
- provisioning and attach flows are understandable
- architecture stays small enough to evolve safely

### Goal 3: Make notifications and automation useful without adding noise

Activity, GitHub auth, and agent automation should help coordination, not create a second product with its own complexity tax.

Success means:

- reconnect/catch-up behavior is reliable
- auth/session churn stays low
- UI entrypoints reflect the actual value of the activity system

### Goal 4: Preserve evidence-driven delivery

Verification loops matter more than usual because changes cross desktop, web, and sandboxed runtimes.

Success means:

- shared-desktop validation is less disruptive
- remote/runtime smoke checks are repeatable
- refactors come with deterministic proof, not hand-waving

---

## Priority Rule

Priority is driven by three filters, in this order:

- Protect the core promise first — select context, get a dependable terminal, keep working.
- Fix dependency debt before adding breadth — work that reduces regression risk outranks adjacent feature growth.
- Expand side systems only after they are trustworthy enough not to drag on the core.

---

## Priority Bands

### Now (P0)

#### 1. Workspace creation hang root cause

`backlog/workspace-creation-hang-root-cause_followup.md`

Diagnostics shipped in PR #190 (`os.Logger` signposts + a 30-second watchdog). Regression net for the PR #190 guard added in PR #372. Root cause still uncertain. Reliability blocker — hangs in the creation path erode core-loop trust the fastest.

**Gate: live repro.** The hang has not been reproduced with the current diagnostics. In-vitro investigation has gone as far as it can — `WorkspaceCreationRaceTests` rules out a basic deadlock under in-memory SwiftData, and code reading shows the MainActor-serialized save path can't deadlock without an external factor (slow disk, vanished store path, SwiftData internal locks under WAL pressure). Tackle this after a deliberate interactive session at the keyboard, not as the first reach for an autonomous session.

#### 2. Main-window + Ghostty boundaries maintainability

Two parallel sub-tracks under one P0 theme. Either can move independently; pick by time/risk appetite.

- **2a. Main-window + sidebar maintainability** (structural). `backlog/main-window-sidebar-maintainability_followup.md`. Sidebar Phase 1 landed (PR #36). Remaining sidebar scope + Ghostty boundary cleanup is the deeper structural work; high-leverage but high-blast-radius. Start here when you have a focused session and accept the surface area.
- **2b. Ghostty appearance hardening** (narrow). `backlog/ghostty-appearance-hardening_followup.md`. Doc parity and smoke verification remain; split-routing controller coverage shipped in PR #379. Smaller scope, lower risk, can ship in a single session. Start here when 2a is too large for the session shape.

P0 because the AppKit bridge is still the riskiest surface to change as remote/activity work continues to land.

#### 3. Shared-desktop + evidence-loop reliability — Phase 1 done; Phase 2 deferred to P2

`backlog/shared-desktop-focus-contention-followup.md`

Phase 1 complete: `AppActivationPolicy` (PR #374) gates all `NSApp.activate` calls — launch *and* runtime — behind `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` / `CI`. `scripts/capture-window.sh` provides window-id capture without activation. Remaining items (capture handshake, separate-user execution lane, VM-backed CI lane) drop to P2 — promote back when a concrete daily-driver scenario forces the issue.

### Next (P1)

#### 4. Terminal continuity — tmux + cross-session

`backlog/tmux-support_plan.md` (multiplexing implementation), `backlog/desktop-continuity_plan.md` (across-session restore)

Decided 2026-04-23 (`docs/decisions/terminal-multiplexing.md`): tmux primary; pane-tree deferred indefinitely. Two paired plans now sit under one theme. Tmux delivers reattach within a session. The continuity plan addresses the gap tmux does not close (close laptop, reopen, pick up where you left off). Implement tmux first; promote continuity to active when the gap is reproducible against the new model.

#### 5. Lume runtime architecture cleanup

`backlog/lume-runtime-architecture-followups_followup.md`

Contract proven (PR #54). Reduce reviewer friction and maintenance cost.

#### 6. Notification client catch-up + reconnect correctness

`backlog/notification-client-catchup-plan.md`

Stable client identity, ACK cadence, duplicate/replay behavior. Reliability step before richer activity UX.

### Later (P2)

#### 7. Strategic isolation backend direction

`backlog/vz-tahoe-execution-brief-plan.md`

Current native-backend direction. Lume and Daytona already ship; VZ/Tahoe stays P2 until earlier quality debt is materially lower. `backlog/done/isolation-strategies.md` holds the long-form option tradeoff history.

### Icebox (P3)

- Sparkle auto-update: `backlog/sparkle-autoupdate-plan.md`
- Swift dev skills task list: `backlog/swift-dev-skills-task-list.md`
- Dev-build warning cleanup + mise task migration: `backlog/dev-build-warning-cleanup-and-mise-tasks_plan.md`

---

## Milestone Alignment

Roadmap and GitHub milestones play different roles:

- roadmap = strategic order and promotion rules
- GitHub milestone = live execution contract for one promoted theme
- backlog plan = design/support detail for work not yet promoted

Default execution policy:

- only `Now` items and explicitly pulled-forward `Next` items should become milestones
- default to one active product milestone at a time unless a second lane is clearly independent
- milestone names come from the approved planning discussion title; the roadmap tracks themes

Theme-to-milestone map:

| Roadmap theme | Milestone posture |
|------|----------|
| Core reliability and maintainability | Active P0 theme |
| Lume runtime hardening | Queued after the current P0 theme clears |
| Notification catch-up and reconnect correctness | Standalone after Lume unless activity work becomes urgent |
| Terminal continuity (tmux + cross-session) | Decided 2026-04-23 (tmux primary). Implementation milestone after Lume runtime hardening unless continuity gap forces it sooner. |
| Strategic isolation backend direction | Backlog/research until promoted by a fresh approved discussion |

---

## Backlog Index

**Index policy** — one comprehensive index, tagged by Scope. Priority Bands above stay strategic-product-only. Quality, ops, and tooling items live in this index so nothing becomes an orphan, but they do not clutter the bands. Priority values match the bands; items not yet promoted show `—` (awaiting promotion or awaiting a dependent decision).

Scope tags:

- `product` — strategic capability or feature
- `quality` — test coverage, reliability, or regression safety net for already-shipped work
- `ops` — infrastructure, runners, release plumbing
- `tooling` — dev productivity, build/CI, internal skills

| Item | Scope | Priority | Pointer |
|------|-------|----------|---------|
| Workspace creation hang root cause | product | P0 | `backlog/workspace-creation-hang-root-cause_followup.md` |
| Main-window + sidebar maintainability | product | P0 | `backlog/main-window-sidebar-maintainability_followup.md` |
| Ghostty appearance hardening | product | P0 | `backlog/ghostty-appearance-hardening_followup.md` |
| Tmux per-worktree implementation | product | P1 | `backlog/tmux-support_plan.md` (chosen 2026-04-23 — `docs/decisions/terminal-multiplexing.md`) |
| Desktop continuity (across-session restore) | product | P1 | `backlog/desktop-continuity_plan.md` (paired with tmux implementation) |
| Lume runtime architecture follow-ups | product | P1 | `backlog/lume-runtime-architecture-followups_followup.md` |
| Notification client catch-up | product | P1 | `backlog/notification-client-catchup-plan.md` |
| Daytona native Swift API | product | — | `backlog/daytona-native-swift-api-plan.md` |
| Remote runtime expansion plan | product | — | `backlog/remote-runtime-expansion-plan.md` |
| Terminal PTY relay (sandbox) | product | — | `backlog/terminal-pty-relay-plan.md` |
| Terminal architecture follow-ups | product | — | `backlog/terminal-architecture-followups.md` |
| Terminal polish follow-ups | product | — | `backlog/terminal-polish-followup.md` |
| Web API authorization hardening (tests) | quality | — | `backlog/web-api-authorization-hardening-followup.md` |
| Web dashboard component regression tests | quality | — | `backlog/web-dashboard-component-regression-tests_followup.md` |
| Shared-desktop focus contention Phase 2 | quality | P2 | `backlog/shared-desktop-focus-contention-followup.md` |
| Tahoe VZ backend execution brief | product | P2 | `backlog/vz-tahoe-execution-brief-plan.md` |
| Web dashboard Phase 3 follow-ups | product | P2 | `backlog/web-dashboard-phase3-followups.md` |
| Spaces agent discovery dashboard | product | P2 | `backlog/spaces-agent-discovery-dashboard-plan.md` |
| Sparkle auto-update | product | P3 | `backlog/sparkle-autoupdate-plan.md` |
| Dev-build warning cleanup + mise tasks | tooling | P3 | `backlog/dev-build-warning-cleanup-and-mise-tasks_plan.md` |
| Swift dev skills task list | tooling | P3 | `backlog/swift-dev-skills-task-list.md` |
| Signing-host runner provisioning | ops | — | `backlog/signing-host-runner_followup.md` |

Archived (in `backlog/done/`):

- Pane-tree terminal tiling model — not chosen; see `docs/decisions/terminal-multiplexing.md` (2026-04-23)
- Terminal multiplexing decision session — resolved by `docs/decisions/terminal-multiplexing.md` (2026-04-23)
- Isolation strategies (research) — superseded by Tahoe VZ execution brief
- Cloudflare Sandbox live plan — scaffold deleted in PR #321
- Landing page plan — shipped in PR #188
- Persistent sandbox conversation continuity — shipped in PR #277
- Main window composition and inspector tests — shipped
- Repo overview (initial plan) — shipped
- Workspace create progress follow-up — shipped
- Workspaces code-review follow-up — shipped
- Apple-native main window redesign — shipped
- Refinement performance follow-up — shipped
- Prek / githooks consolidation — shipped in PR #364
- Agent Peter refactor follow-up — shipped
- Remote workspace identity + sendability cleanup — shipped; see `backlog/done/remote-workspace-identity-sendability_followup.md`

---

## Learnings

### 2026-04-27 — Split-routing tests + stale backlog reconciliation

- **Cover the coordinator switch, not only the model underneath.** `HostTerminalStateStore` already covered split layout, resize, and equalize behavior, but PR #379 added direct `SplitRoutingController` coverage for `new_split`, `goto_split`, `resize_split`, `equalize_splits`, tmux-mode rejection, and invalid payloads. That protects the notification-routing contract where regressions would actually enter.
- **Re-ground backlog items by symbols before selecting them.** The remote identity/sendability follow-up still looked active in the roadmap, but `sessionRoutingID`, `Workspace.remotePathSentinel`, `localWorkspaceContext`, and the `LocalBackend` value boundary were already on `main`. A fast `rg` pass prevented a second implementation of shipped work and turned the next unit into backlog cleanup instead.

### 2026-04-25 — Workspace-creation regression net + shared-desktop Phase 1 (PRs #372, #374)

- **Tests as a probe, even when they pass.** PR #372 added a deterministic regression surface for the workspace-creation hang. The tests passed cleanly under in-memory SwiftData, which doesn't prove the production hang is fixed, but the artifact is still load-bearing: it locks down PR #190's `insertedModelsArray` premise so a future refactor can't silently regress the guard. "Did the tests reproduce the bug?" is the wrong question — "do the tests prevent the regression we already fixed?" is the right one.
- **Helper-based gates pay for themselves at three call sites.** `AppActivationPolicy` (PR #374) replaced three direct `NSApp.activate(ignoringOtherApps:)` sites with one-line calls into a tested helper. The dedup ratio was modest, but the *contract* is now centralized: when a fourth activation site shows up, the next person doesn't have to remember the env var. Helpers earn their keep when behavior must be uniform across many sites, not just when there's syntactic duplication.
- **Truthful diagnostics survive review better than aspirational ones.** The first version of the policy-gated `TerminalFocusCoordinator` log said `coordinator_activate_requested` and fired before the gate. Code review caught it. The fix renamed to `_attempted` and added a `policy_allows` field so traces show whether the call actually happened. Diagnostic phase names are part of the contract — wrong names are quietly worse than missing logs.
- **Shared-desktop is its own dependency loop for verification.** Verifying PR #374 needs interactive `launch-dev.sh --no-activate` + clicking around — exactly the workflow the PR is making safer. The PR body called this out explicitly rather than claiming verified behavior; the manual step belongs to Michael at the keyboard. Be honest about which loops your session can close and which it can't.

### 2026-04-23 — Terminal multiplexing decision session (PR #369)

- **Decision sessions need one question, not a survey of opinions.** The plan asked Michael exactly one thing — "what is the daily-driver use case the chosen model must get right?" — and the rest of the four-options framing fell out of his answer. The pattern is briefing → one question → artifact, in that order.
- **A capability clarification can change a decision's framing.** `#324` confirmed tmux-in-sandbox does not survive snapshot/restore. Without that fact, "hybrid" looked attractive; with it, the multiplexing question and the continuity question split apart cleanly. Worth re-reading the most recent capability-clarifying PR before any product decision in the same area.
- **Pair the chosen plan with what it does *not* solve.** Naming `desktop-continuity_plan.md` alongside the tmux choice keeps the decision honest. If the accepted option only addresses part of the user need, the gap deserves its own paired plan in the same PR — otherwise the decision quietly over-promises.
- **Subagent briefing keeps the main thread fit for the human conversation.** Delegating the "read both plans + skim 6 PRs + summarize" work to an `Explore` subagent meant the 5-minute conversation with Michael ran on synthesized context, not raw file content. The same pattern fits any decision session.

### 2026-03-30 — Chat timeline UX: collapsed events (#271)

- **Sort direction bugs hide in data flow** — changing timeline sort from descending to ascending broke the `oldest`/`newest` variable assignments in the new EventGroupRow component. The `/reflect` skill caught it before merge. Always trace data ordering through the full pipeline when changing sort direction.
- **Playwright renders mock UIs for evidence** — when auth blocks local dev screenshots, rendering mock HTML with Playwright produces deterministic before/after evidence. More reliable than screencapture + Chrome tab juggling.
- **Group by adjacency, not by type** — grouping events by type would scatter the timeline. Grouping consecutive events (broken by any chat message) preserves chronological context while still collapsing noise. A group of 12 events goes from ~576px to ~24px.

### 2026-03-30 — Sandbox E2E validation and pre-commit hook gap (#265, #268)

- **Pre-commit hooks must cover all CI-linted languages** — `.githooks/pre-commit` only ran swift-format, so biome errors on TypeScript files weren't caught until CI. Three round-trips to fix lint/typecheck. Always mirror CI lint checks in pre-commit.
- **Two hook systems is one too many** — `prek.toml` defines a `biome-web` hook, but `core.hooksPath=.githooks` means prek's hooks never run. The `.githooks/pre-commit` script is what actually executes. Consolidate to one system. *(Consolidation shipped in PR #364; see `backlog/done/prek-githooks-consolidation_followup.md`.)*
- **Worktrees don't inherit hook installations** — prek installs hooks into `.git/hooks/` of the main checkout, but worktrees have separate hook directories. The `.githooks/` approach (tracked in repo, referenced by `core.hooksPath`) works across all worktrees automatically.
- **assertDefined() is the right pattern for test narrowing** — biome forbids `!` non-null assertions. A simple `assertDefined<T>(val): T` helper narrows the type and throws with a useful message, replacing both `assert(x !== null)` + `x!` in one call.

### 2026-03-30 — Web QA, test coverage expansion, agent runtime hardening (#253, #255, #259, #264)

- **Exploratory QA finds what automated tests miss** — browser-based QA caught the non-sticky tab bar (#253) which no unit test would cover. The QA-then-automate loop is the right order: explore manually, then encode the important flows as tests.
- **Extract-then-test beats testing inline functions** — 9 inline functions couldn't be tested without extracting them. The refactor was trivial but unlocked 55 unit tests. When code is hard to test, restructure it rather than writing complex integration tests.
- **Playwright in CI needs three things right** — (1) the dep must be in package.json + lockfile, (2) tsconfig must exclude e2e/ from typecheck, (3) pnpm's binary resolution needs the package explicitly listed. Each caused a CI failure.
- **Concurrent agents cause dirty working directory** — committing directly in the main working directory while other agents are active leads to mixed changes. Always use worktrees (`wt.sh`) for branch work.
- **DEV_BYPASS_AUTH for E2E is clean but scoped** — bypassing middleware is easy; bypassing `getSession()` in API routes requires a mock session return. Both must be gated on `NODE_ENV=development` to prevent production bypass.
- **Hardcoded allowlists become env vars fast** — the "fairchild" agent login check was duplicated in two routes within one PR. Extracting to a shared config backed by an env var is trivial and saves a deploy cycle when adding users.

### 2026-03-30 — Security review and agent kill switch (#256, #260, #261)

- **Intended kill switches must be wired** — `MENTION_AUTOMATIONS_ENABLED: false` existed as a repo variable but no workflow referenced it. The mention pipeline was live despite the intent to disable it. Always verify the variable is actually checked.
- **Triage sanitization is theater if the agent re-fetches raw content** — the 280-char sanitized summary only protects the maintainer's view. The contributor runtime re-fetches full GitHub payloads via GraphQL and passes them unsanitized into the Claude prompt. Defense-in-depth requires limiting what the agent sees, not just what the human sees.
- **One kill switch beats many** — started with two separate variables (`MENTION_AUTOMATIONS_ENABLED`, `AGENT_SCHEDULED_RUNS_ENABLED`), then consolidated to `AGENT_AUTOMATIONS_ENABLED`. Fewer controls = fewer gaps.
- **Scheduled cron runs are a stealth attack surface** — even with mentions disabled, a crafted issue body sits waiting for the next agent wake-up. The agent encounters it organically during its scan. Disabling mentions alone was insufficient.
- **Self-hosted runners amplify prompt injection risk** — persistent machines with real secrets are higher stakes than ephemeral GitHub-hosted runners. Evidence workflow's two-lane design (untrusted code lane has no secrets) is the right pattern.

### 2026-03-29 — Git worktree skill hardening

- **Real usage is the best test suite** — cleaning up 10 worktrees exposed bugs (slash-in-branch-name, missing archive dirs) that no amount of reading the code would catch. Build features, use them, fix what breaks.
- **Batch operations are high-leverage** — `wt clean` replaced 10 manual check-and-archive cycles. The two-tier merge detection (git ancestry + gh PR status) was essential because most PRs use squash merge.
- **Shell functions vs scripts is a real boundary** — `wt done` needs to `cd` the parent shell, so it must be a shell function. This is the same constraint `wt cd` and `wt home` have. Design for it upfront.
- **Cross-tool worktree sprawl is real** — Claude Code, Cline, Codex, and conductor all create worktrees in different locations. `wt list --all` and `wt clean --all-sources` address this, but the fundamental issue is that each tool reinvents worktree management.
- **Archives accumulate silently** — 3.6GB of dead worktrees across 23 archives. `wt prune` with an age threshold is the right default. Consider adding it to session-end hooks.

### 2026-03-29 — Web chat platform consolidation (#246, #248, #249)

- **Many small overlapping PRs are worse than one consolidated PR** — 6 agent-generated PRs all modified the same 6 core files. Cherry-picking and rebasing each was a conflict nightmare. One consolidated PR fixed it in a single merge.
- **Verify main before closing PRs** — we closed 6 PRs assuming web-next (#237) included all features. It didn't. The `/reflect` skill caught this before it shipped. Always check file existence on main, don't trust commit message similarity.
- **Kanban agents stall at prompts** — background Claude Code sessions go idle when they finish work and wait for user input. The `claude --resume <session-id>` technique preserves conversation context and lets the agent continue. This should be automated.
- **CSS from agent-generated code needs visual verification** — the tab bar was `display: none` on desktop, invisible until we browsed the deployed site. Browser-based QA caught it.
- **Env var names must match deployment** — agents used generic names (`GITHUB_APP_ID`) while Vercel had project-specific names (`GITHUB_WEB_WORKSPACES_APP_ID`). Grep for env var usage before shipping.

### 2026-03-29 — Web local dev reliability (#237)

- `scripts/setup` must handle lockfile-based dependency installation, not just mise — new worktrees were missing `pnpm install` for `web/`
- cmux workshop skill already prioritizes `scripts/setup` in its detection table, but the script itself was too minimal to be useful
- Local SQLite fallback needs `mkdirSync` for the data directory — fresh clones/worktrees hit ENOENT without it
- Workshop setup should always run `scripts/setup` before starting dev servers — this is documented in the cmux skill but easy to skip

### 2026-03-22 — Milestone 6: Terminal Readiness Recovery (PRs #162-#165, plus direct merges)

- **Agent teams work for parallel milestone execution** — 3 Wave 2 teammates (Focus, Selection, Sheet) successfully worked in parallel with clear file ownership boundaries and prescribed merge order.
- **SwiftPM lock contention is the main friction with worktrees** — teammates sharing `.build` directory caused constant test timeouts (exit 144). Future parallel work should consider per-worktree build dirs or sequential test runs.
- **Plan approval mode prevents merge conflicts** — requiring plan review before implementation kept ContentView.swift changes non-overlapping across 3 teammates.
- **Teammates sometimes go idle before committing** — team lead should proactively check worktree state and take over when needed.
- **Debounced persistence works but needs testing under workspace creation** — the "Finishing workspace..." stuck state observed post-milestone needs investigation; may be interaction between debounced save and workspace upsert flow.
- **cachedSetupSnapshot (PR #142) was a premature optimization** — PR #166 removes it because stale state caused correctness issues. One extra daemon probe per setup is acceptable.

### 2026-03-22 — Post-Milestone 6: Workspace creation hang (PR #190)

- **NSLog doesn't flow to unified log in debug builds** — switched to `os.Logger` for reliable debug-build diagnostics. Always use `os.Logger` for new instrumentation.
- **Debounced save rollback can discard unrelated pending changes** — `modelContext.rollback()` affects ALL pending changes in the context, not just the ones the debounced save cares about. Guard rollbacks when other operations may have pending inserts.
- **Watchdog timers surface stuck states** — a 30-second watchdog that updates the UI and logs is cheap insurance against indefinite hangs.

### 2026-03-22 — Spaces dashboard exploration (#191)

- Prototyping multiple layout variants as static HTML before committing to a direction saved significant iteration time — owner could compare side-by-side and pick elements from each.
- The `web/` app has a strong design system (Instrument Serif + JetBrains Mono + mint accent); prototypes that didn't match it felt wrong immediately.
- Dashboard needs two levels: global summary across repos + per-repo drill-in with scoped tabs (schedule/skills are per-repo, not global).
- LLM-driven UI exploration landed on Level 2 (structured JSON decisions, not generated HTML) — industry consensus (CopilotKit, Google A2UI, Vercel AI SDK v6) confirms this.

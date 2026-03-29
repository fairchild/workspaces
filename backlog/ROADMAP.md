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

## Current Product Reality (2026-03-12)

Latest shipped release: `0.4.0` on 2026-03-11.

What is already real in code:

- terminal-first main window with repo overview, persistent repo/workspace terminals, and embedded web views
- calmer repo-first sidebar with explicit sorting and per-window last-surface restoration
- Ghostty-backed terminal integration with current two-pane split actions and focus routing
- local workspaces plus remote/provider-backed workspace plumbing
- Daytona and Lume provider tracks in core, including host-side validation/setup flows for Lume
- notification/auth/activity infrastructure, including GitHub auth entrypoints and webhook/event-stream services
- workspace process monitoring and agent-awareness in repo overview cards
- automation-oriented dev tooling, Tart GUI verification, and host-Lume smoke coverage

What this means for planning:

- the product is no longer "just local workspace copies plus a terminal"
- the highest risk is now complexity management and determinism, not raw feature absence
- roadmap decisions should protect the terminal-first experience from being diluted by side systems

---

## Product Goals

### Goal 1: Keep the core loop excellent

The core loop is: choose context, get a ready terminal, inspect files/changes, continue work without surprise.

Success means:

- launch/restore behavior is boring and predictable
- session reuse and focus stay correct under rapid switching
- sidebar and repo overview stay calm even as more capabilities exist

### Goal 2: Make remote runtimes trustworthy

Remote and VM-backed workspaces are now part of the product direction, but only if they feel as dependable as local workspaces.

Success means:

- provider identity/state is explicit and not leaky
- provisioning and attach flows are understandable
- architecture stays small enough to evolve safely

### Goal 3: Make notifications and automation useful without adding noise

Activity, GitHub auth, and agent automation support should help users coordinate work, not create a second product with its own complexity tax.

Success means:

- reconnect/catch-up behavior is reliable
- auth/session churn stays low
- UI entrypoints reflect the actual value of the activity system

### Goal 4: Preserve evidence-driven delivery

This repo depends on strong verification loops for terminal and desktop behavior.

Success means:

- shared-desktop validation is less disruptive
- remote/runtime smoke checks are repeatable
- refactors come with deterministic proof, not hand-waving

---

## Shipped Baseline

These are done enough that they should not be planned as upcoming roadmap items:

- repo overview as the primary repo surface
- scoped web views at global, repo, and workspace levels
- persistent repo/workspace terminal sessions
- Ghostty split/focus/resize/equalize integration for the current two-pane model
- open-in-editor hardening and launch metrics
- notification client foundation, webhook relay, and GitHub auth integration
- workspace provider registry and active Lume/Daytona provider work
- release/signing/notarization path through current releases

The roadmap should treat these as baseline capabilities that need hardening, not as net-new scope.

---

## Priority Rule

Priority is driven by three filters, in this order:

- protect the core promise first: select context, get a dependable terminal, keep working
- fix dependency debt before adding breadth: work that reduces regression risk outranks adjacent feature growth
- expand side systems only after they are trustworthy enough not to drag on the core product

---

## Priority Bands

### Now (P0)

#### 1. Maintainability pass on main window and Ghostty boundaries

Why now:

- `ContentView` remains a large orchestration surface
- the Ghostty/AppKit bridge is still one of the riskiest places to change
- future remote/activity work will compound costs if these seams stay muddy

Primary pointers:

- `backlog/main-window-sidebar-maintainability_followup.md`
- `backlog/ghostty-appearance-hardening_followup.md`

#### 2. Shared-desktop and evidence-loop reliability

Why now:

- local visual verification still contends with the active desktop session
- this slows refactors and lowers confidence in UI and terminal behavior changes

Primary pointer:

- `backlog/shared-desktop-focus-contention-followup.md`

#### 3. Remote workspace identity cleanup

Why now:

- remote workspace persistence and routing semantics are still not clean enough
- this is foundational before expanding more remote/runtime behavior

Primary pointer:

- `backlog/remote-workspace-identity-sendability_followup.md`

### Next (P1)

#### 4. Lume runtime architecture cleanup

Why next:

- Lume has crossed from experiment to meaningful product surface
- the current runtime/provider implementation works, but reviewer friction and maintenance cost are too high

Primary pointer:

- `backlog/lume-runtime-architecture-followups_followup.md`

#### 5. Notification catch-up and reconnect correctness

Why next:

- `0.3.0` and `0.4.0` added enough notification surface that duplicate/replay behavior now matters
- reconnect semantics should be reliable before investing in richer activity UX

Primary pointer:

- `backlog/notification-client-catchup-plan.md`

#### 6. Decide the next terminal multiplexing step

Why next:

- current two-pane behavior is useful, but it is not the final terminal tiling model
- this needs a deliberate decision, not incremental shortcut accretion

Primary pointers:

- `backlog/pane-tree-tiling_plan.md`
- `backlog/tmux-support_plan.md`

Decision bias:

- prefer one primary multiplexing model
- do not productize pane-tree and tmux deeply at the same time

### Later (P2)

#### 7. Strategic isolation backend direction

The long-range isolation question is still open, but the roadmap should reflect current reality:

- Lume-backed runtime work is already active product code
- Daytona integration exists
- Tahoe VZ remains a strategic native-backend direction, not the only path to remote isolation

Primary pointers:

- `backlog/vz-tahoe-execution-brief-plan.md`
- `backlog/isolation-strategies.md`

Planning note:

- do not frame VZ as the immediate next milestone unless P0/P1 quality debt is materially lower

### Icebox (P3)

- Sparkle auto-update: `backlog/sparkle-autoupdate-plan.md`
- landing page / marketing site: completed in PR #188, moved to `backlog/done/landing-page.md`
- web dashboard Phase 3 follow-ups: `backlog/web-dashboard-phase3-followups.md`
- internal skills/task-list work: `backlog/swift-dev-skills-task-list.md`

---

## Milestone Alignment

Roadmap and GitHub milestones play different roles:

- roadmap = strategic order and promotion rules
- GitHub milestone = live execution contract for one promoted theme
- backlog plan = design/supporting detail for work not yet promoted

Default execution policy:

- only `Now` items and explicitly pulled-forward `Next` items should become milestones
- default to one active product milestone at a time unless a second lane is clearly independent
- milestone names should come from the approved planning discussion title; the roadmap tracks themes, not canonical GitHub titles

Current GitHub state (2026-03-12):

- the active milestone is `Core reliability and maintainability` (#1)
- the queued next milestone is `Lume runtime hardening` (#5)
- the active milestone should stay limited to the current `P0` theme
- roadmap ordering still wins over milestone drift; if the milestone scope widens, bring it back to the `P0` set

Theme-to-milestone map:

| Roadmap theme | Milestone posture |
|------|----------|
| Core reliability and maintainability | Current execution milestone |
| Lume runtime hardening | Queued standalone milestone after the current core-reliability milestone |
| Notification catch-up and reconnect correctness | Standalone milestone after Lume unless activity work becomes urgent sooner |
| Terminal multiplexing direction | Milestone only after an explicit product decision to invest here |
| Strategic isolation backend direction | Backlog/research until promoted by a fresh approved discussion |

---

## Learnings

### 2026-03-22 — Milestone 6: Terminal Readiness Recovery (PRs #162-#165, plus direct merges)
- **Agent teams work for parallel milestone execution** — 3 Wave 2 teammates (Focus, Selection, Sheet) successfully worked in parallel with clear file ownership boundaries and prescribed merge order
- **SwiftPM lock contention is the main friction with worktrees** — teammates sharing `.build` directory caused constant test timeouts (exit 144). Future parallel work should consider per-worktree build dirs or sequential test runs
- **Plan approval mode prevents merge conflicts** — requiring plan review before implementation kept ContentView.swift changes non-overlapping across 3 teammates
- **Teammates sometimes go idle before committing** — team lead should proactively check worktree state and take over when needed
- **Debounced persistence works but needs testing under workspace creation** — the "Finishing workspace..." stuck state observed post-milestone needs investigation; may be interaction between debounced save and workspace upsert flow
- **cachedSetupSnapshot (PR #142) was a premature optimization** — PR #166 removes it because stale state caused correctness issues. One extra daemon probe per setup is acceptable

### 2026-03-22 — Post-Milestone 6: Workspace creation hang (PR #190)
- **NSLog doesn't flow to unified log in debug builds** — switched to `os.Logger` for reliable debug-build diagnostics. Always use `os.Logger` for new instrumentation.
- **Debounced save rollback can discard unrelated pending changes** — `modelContext.rollback()` affects ALL pending changes in the context, not just the ones the debounced save cares about. Guard rollbacks when other operations may have pending inserts.
- **Watchdog timers surface stuck states** — a 30-second watchdog that updates the UI and logs is cheap insurance against indefinite hangs


---

## Recommended Milestone Sequence

This sequence follows the priority rule above: core promise first, dependency cleanup second, broader product bets after that.

1. `Core reliability and maintainability`
   Covers the current P0 set: main-window/Ghostty maintainability, shared-desktop verification reliability, and remote workspace identity cleanup.
2. `Lume runtime hardening`
   Refactor the runtime/provider internals now that the contract is proven.
3. `Notification catch-up and reconnect correctness`
   Make activity reliable before expanding activity UX.
4. `Terminal multiplexing direction`
   Either commit to pane-tree investment or consciously defer it.
5. `Strategic isolation backend direction`
   Promote only after the earlier milestones reduce implementation drag.

---

## Backlog Index

| Item | Category | Priority | Pointer |
|------|----------|----------|---------|
| Main-window + sidebar maintainability pass | Follow-up | P0 | `backlog/main-window-sidebar-maintainability_followup.md` |
| Ghostty appearance hardening | Follow-up | P0 | `backlog/ghostty-appearance-hardening_followup.md` |
| Shared desktop focus contention hardening | Follow-up | P0 | `backlog/shared-desktop-focus-contention-followup.md` |
| Remote workspace identity and sendability cleanup | Follow-up | P0 | `backlog/remote-workspace-identity-sendability_followup.md` |
| Lume runtime architecture follow-ups | Follow-up | P1 | `backlog/lume-runtime-architecture-followups_followup.md` |
| Notification client catch-up | Plan | P1 | `backlog/notification-client-catchup-plan.md` |
| Pane-tree terminal tiling model | Plan | P1 | `backlog/pane-tree-tiling_plan.md` |
| Tahoe VZ backend execution brief | Plan | P2 | `backlog/vz-tahoe-execution-brief-plan.md` |
| Isolation strategy options | Plan | P2 | `backlog/isolation-strategies.md` |
| tmux per-worktree support | Plan | P3 | `backlog/tmux-support_plan.md` |
| Sparkle auto-update decision record | Plan | P3 | `backlog/sparkle-autoupdate-plan.md` |
| Landing page + web dashboard | Plan | Done | `backlog/done/landing-page.md` |
| Web dashboard Phase 3 follow-ups | Follow-up | P2 | `backlog/web-dashboard-phase3-followups.md` |
| Swift dev skills task-list | Task List | P3 | `backlog/swift-dev-skills-task-list.md` |
| Workspace creation hang root cause | Follow-up | P0 | `backlog/workspace-creation-hang-root-cause_followup.md` |
| Spaces agent discovery dashboard | Plan | P2 | `backlog/spaces-agent-discovery-dashboard-plan.md` |

---

## Learnings

### 2026-03-29 — Web local dev reliability (#237)
- `scripts/setup` must handle lockfile-based dependency installation, not just mise — new worktrees were missing `pnpm install` for `web/`
- cmux workshop skill already prioritizes `scripts/setup` in its detection table, but the script itself was too minimal to be useful
- Local SQLite fallback needs `mkdirSync` for the data directory — fresh clones/worktrees hit ENOENT without it
- Workshop setup should always run `scripts/setup` before starting dev servers — this is documented in the cmux skill but easy to skip

### 2026-03-22 — Spaces dashboard exploration (#191)
- Prototyping multiple layout variants as static HTML before committing to a direction saved significant iteration time — owner could compare side-by-side and pick elements from each
- The `web/` app has a strong design system (Instrument Serif + JetBrains Mono + mint accent); prototypes that didn't match it felt wrong immediately
- Dashboard needs two levels: global summary across repos + per-repo drill-in with scoped tabs (schedule/skills are per-repo, not global)
- LLM-driven UI exploration landed on Level 2 (structured JSON decisions, not generated HTML) — industry consensus (CopilotKit, Google A2UI, Vercel AI SDK v6) confirms this

---

## Verification Notes

Roadmap grounding sources:

- `CHANGELOG.md` through `0.4.0`
- `README.md`
- `docs/product_overview.md`
- current app/core source files under `Sources/WorkspaceManager` and `Sources/WorkspaceManagerCore`
- active backlog plans referenced above

Local `swift test` could not be completed in this session because the checked-in `Frameworks/GhosttyKit.xcframework` artifact is currently incomplete in this worktree, causing SwiftPM to fail before tests run.

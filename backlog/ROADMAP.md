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
- make concurrent agent sessions legible, steerable, and verifiable without leaving the terminal-first loop
- add remote runtimes and activity feeds only when they make that workflow more reliable

This roadmap is grounded in the current codebase and recent releases, not older MVP assumptions.

---

## Current State

Workspaces now spans three surfaces — a Mac-native app, a web dashboard, and an agent-automation track. Each surface carries its own complexity and its own hardening agenda.

**Desktop app.** Terminal-first main window with repo overview and persistent repo/workspace terminals. Calmer repo-first sidebar with explicit sorting and per-window last-surface restoration. Ghostty-backed terminal with split/focus/resize/equalize and working shortcut routing. Local workspaces plus Lume and Daytona provider tracks, including host-side validation and setup flows for Lume. Notification/auth/activity infrastructure, workspace process monitoring, and agent-awareness in repo overview cards. A canonical performance system (`workspaces-performance-system` skill + `config/performance/contract.json`) enforces scenario budgets across debug, installed, release, and CI environments. The terminal layout model is mid-transition: the Tile Tree + Surface abstraction epic ([#627](https://github.com/fairchild/workspaces/issues/627)) is replacing the two-pane split maps with a recursive tile tree, Phases 0–2 landed/in review (PRs #625, #633).

**Web dashboard** (`web/`). Next.js 15 on Vercel with GitHub OAuth (Better Auth) and LibSQL+Kysely persistence. A ghostty-web terminal tab and a TerminalShare Cloudflare Worker proxy. A multi-provider agent runtime now covering Vercel Sandbox and Anthropic Managed Agents, with Daytona/GitHub Actions registered as unavailable stubs and `mock` available for tests (#332). Persistent-sandbox snapshot/restore for conversation continuity (#277); tmux inside the sandbox for real resume continuity (#311/#312/#315, clarified in #324). Automated PR review posted by Managed Agents (#345). Preview → validate → promote CD pipeline with a bootstrap orchestrator (#344). PostHog telemetry (#336). A `qa-web` skill + subagent (#343) covers black-box exploratory testing, author-mode spec generation, and heal-mode regression-vs-selector-drift triage.

**Agent automation.** The `.agents/skills/` library (`workspaces-performance-system`, `workspaces-optimization`, `drive`, `peter-planner`, `gh-discuss`, and others). April agent workflow runs on a Lume self-hosted runner. Managed PR review is now ReviewRun-first, repairable, documented, quiz-validated, and closed under milestone #8. Most broader autonomous automations remain gated off behind `AGENT_AUTOMATIONS_ENABLED`, pending runner policy, prompt-injection defense hardening, and proof that new automation surfaces reduce delivery drag rather than adding operator noise.

**Shipping cadence.** Weekly-ish releases. Latest release `v0.18.0`.

What this means for planning.

- The product is three surfaces, not one, and they do not age at the same rate.
- The highest risk is now complexity management and determinism across surfaces, not raw feature absence.
- Terminal-first remains the product's core promise; everything else is in service of that, including the web and agent surfaces.
- The next agent-facing product opportunity is not a separate dashboard; it is a calmer control layer over sessions, surfaces, and verification context that already exist in the app.
- Performance has moved from crisis to system. Ongoing measurement via the canonical contract is the norm, not a fire drill.
- Agent automation must earn expansion by improving delivery throughput and reducing review drag on already-shipped workflows, not by adding more autonomous surfaces first.
- Post-`v0.18.0`, the release/config debts from the `v0.17.0` closure are retired (#615/#617) and one product epic is mid-flight: Tile Tree + Surface abstraction (#627, stacked PRs). A 2026-06-09 daily-driver readiness review converted the remaining reliability/performance gaps into concrete issues (#634–#638); retiring those alongside the epic outranks reopening breadth.

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
- multi-provider agent runtime (Vercel Sandbox and Anthropic Managed Agents; Daytona/GitHub Actions unavailable stubs; mock test provider)
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
- managed PR reviewer via Anthropic Managed Agents, with ReviewRun-first execution/projection state, health reporting, repair posture, docs, visual guide, and quiz validation closed under milestone #8

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

### Goal 5: Make agent surfaces legible, controllable, and verifiable

The app should help users and trusted local agents understand and steer live work without turning the terminal-first shell into a noisy dashboard.

Success means:

- a mission-control overlay can preview and jump to live repo/workspace/session contexts
- sidebar and attention metadata show enough context to choose the next session confidently
- local agent control routes through stable WorkSpaces IDs and an auditable same-user boundary
- embedded web views can provide bounded page snapshots and safe verification hooks for agent workflows

---

## Priority Rule

Priority is driven by three filters, in this order:

- Protect the core promise first — select context, get a dependable terminal, keep working.
- Fix dependency debt before adding breadth — work that reduces regression risk outranks adjacent feature growth.
- Expand side systems only after they are trustworthy enough not to drag on the core.

Throughput means fewer stuck PRs, fewer manual review repairs, clearer operator state, and less rework on the workflows already in use. With managed-reviewer reliability closed and the `v0.17.0` release/configuration debts retired (#615/#617), the next throughput gains come from the core-reliability hardening cluster (#634/#635) and keeping the tile-tree epic's stacked PRs small and mergeable — before broadening agent automation.

---

## Priority Bands

### Now (P0)

#### 1. Workspace creation hang root cause

GitHub: [#554](https://github.com/fairchild/workspaces/issues/554) · `arc:core-reliability`

Diagnostics shipped in PR #190 (`os.Logger` signposts + a 30-second watchdog). Regression net for the PR #190 guard added in PR #372. Root cause still uncertain. Reliability blocker — hangs in the creation path erode core-loop trust the fastest.

**Gate: live repro.** The hang has not been reproduced with the current diagnostics. In-vitro investigation has gone as far as it can — `WorkspaceCreationRaceTests` rules out a basic deadlock under in-memory SwiftData, and code reading shows the MainActor-serialized save path can't deadlock without an external factor (slow disk, vanished store path, SwiftData internal locks under WAL pressure). Tackle this after a deliberate interactive session at the keyboard, not as the first reach for an autonomous session.

**Adjacent ungated hardening (2026-06-09).** A reliability review found a second, deterministic hang class upstream of the reported symptom: `ProcessRunner.run` has no timeout and requires pipe EOF, so a lifecycle script that backgrounds a child hangs creation at "Running setup..." forever (12 services share the runner). It does *not* explain the reported `.finished`-stage hang, so the live-repro gate stands for #554 itself — but the hardening is ungated and improves diagnosability when the repro lands. Tracked as [#634](https://github.com/fairchild/workspaces/issues/634); paired cleanup-visibility and deletion-coordination debt as [#635](https://github.com/fairchild/workspaces/issues/635), with startup orphan reconciliation as the P2 follow-on ([#636](https://github.com/fairchild/workspaces/issues/636)).

#### 2. Tile Tree + Surface abstraction epic

GitHub: [#627](https://github.com/fairchild/workspaces/issues/627) · branch `c-tile-surface-abstraction`

The active product epic: replace the two-pane split maps (`HostTerminalStateStore`) with a recursive tile tree plus a `protocol Surface` seam, so a tile can host a terminal or a web view. This deliberately **reverses** the 2026-04-23 `docs/decisions/terminal-multiplexing.md` choice (pane-tree deferred indefinitely); Phase 8 records the superseding ADR. Phases 0–1 merged (PR #625), Phase 2 in review (PR #633). The risky flips are Phase 3 (tree becomes render source of truth) and Phase 5 (eviction authority) — both should land with the daily-driver smoke net ([#638](https://github.com/fairchild/workspaces/issues/638)) in place or alongside.

#### 3. Main-window + Ghostty boundaries maintainability

The remaining active P0 work is the structural maintainability lane. The narrow Ghostty appearance hardening lane has shipped, and the first Ghostty boundary seams have landed.

- **3a. Main-window + sidebar maintainability** (structural). Sidebar Phase 1 landed (PR #36), and later controller seams moved more selection, bootstrap, surface-resolution, remote-workspace, and sorting behavior out of the root view. Remaining scope is still actionable but should stay incremental: shrink `ContentView.swift` / `SidebarView.swift` integration hotspots without changing navigation, workspace creation, split handling, or inspector behavior. Sequencing note (2026-06-09): while #627 Phases 2–5 are in flight, target the *non-terminal* seams first — the duplicated bootstrap logic (`MainWindowSurfaceResolutionController` internally instantiates its own `MainWindowBootstrapController`), the three competing error-presentation patterns, and selection-state extraction — and leave terminal-orchestration code to the epic to avoid churn. Sidebar Phase 1 source plan: `backlog/done/main-window-sidebar-maintainability_followup.md` (closed #81 + residual notes).
- **3b. Ghostty boundary cleanup** (structural). PR #387 extracted runtime callback config wiring into `GhosttyRuntimeConfigFactory`; PR #394 centralized callback userdata and main-thread bridging. Remaining Ghostty work should now focus on the still-dense `GhosttySurfaceView` / AppKit lifecycle boundary, not on the completed callback userdata/config seams. The `TerminalSurface` conformer from #627 Phase 2 is becoming the natural home for that boundary.
- **3c. Ghostty appearance hardening** (completed). Split-routing controller coverage shipped in PR #379. Appearance dedupe coverage and docs parity shipped in PR #383, and current smoke docs/scripts already state the Ghostty-splits/tmux preconditions. Closed under #84.

P0 because these integration files still carry the highest regression risk when terminal, workspace, and activity behavior changes land. Treat this as a sequence of small behavior-preserving refactors with focused tests, not a broad rewrite.

#### 4. Shared-desktop + evidence-loop reliability — Phase 1 done; Phase 2 deferred to P2

Phase 1 complete: `AppActivationPolicy` (PR #374) gates all `NSApp.activate` calls — launch *and* runtime — behind `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` / `CI`. `scripts/capture-window.sh` provides window-id capture without activation. Remaining items (capture handshake, separate-user execution lane, VM-backed CI lane) drop to P2 — promote back when a concrete daily-driver scenario forces the issue. Phase 1 source: `backlog/done/shared-desktop-focus-contention-followup.md` (closed #82 + residual notes).

#### 5. Release and local-configuration reliability debt — completed in `v0.18.0`

GitHub: [#615](https://github.com/fairchild/workspaces/issues/615) + [#617](https://github.com/fairchild/workspaces/issues/617) · `area: platform` / `area: distribution` / `devEx`

Both closed: release preflight check-run pagination shipped (PR #619), and the Claude hook installer now writes machine-agnostic, shell-safe commands without backup churn (PRs #620/#621). The successor reliability-debt theme is the core-reliability hardening cluster under item 1 (#634/#635/#636).

#### 6. Managed reviewer reliability and understandability — completed in `v0.17.0`

GitHub: [#584](https://github.com/fairchild/workspaces/issues/584) · milestone [Managed reviewer: understandable ReviewRun-first system](https://github.com/fairchild/workspaces/milestone/8) · `area: platform`

Milestone #8 is closed. Closure validation covered pickup, terminal state, details URL, projection repair behavior, ReviewRun-first health, GitHub projection audit separation, release/Sparkle verification, and human-maintainer quiz review. Keep the shipped ReviewRun-first model as baseline operating doctrine, and file any new reviewer work as specific follow-up debt rather than reopening the milestone.

### Next (P1)

#### 7. Terminal continuity — cross-session restore; tmux posture pending the #627 ADR

GitHub: [#549](https://github.com/fairchild/workspaces/issues/549) (tmux implementation) + [#548](https://github.com/fairchild/workspaces/issues/548) (across-session restore) · `arc:terminal-continuity`

The 2026-04-23 decision (`docs/decisions/terminal-multiplexing.md`: tmux primary, pane-tree deferred) has been **partially superseded**: the Tile Tree epic (#627) deliberately reverses the pane-tree deferral and will record the new ADR in its Phase 8. What survives the reversal cleanly is the continuity question — tile trees don't keep processes alive across app restarts, so #548 (close laptop, reopen, pick up where you left off) remains valid regardless of layout model. The first continuity slice already shipped: tmux preserves live process state when the server survives, and the terminal continuity manifest records target + launch directory as the honest fallback. Hold #549 (tmux-per-worktree as the *multiplexing* layer) until the Phase 8 ADR settles how tmux and the tile tree compose; re-scope it then rather than implementing against the superseded decision.

#### 8. Lume runtime architecture cleanup

Closed: #87, #88, #89 · `arc:lume-runtime`

Contract proven (PR #54). The three decomposition follow-ups (shared HTTP transport, native detachment + VM typing, doc refresh) all closed; reviewer-friction work is complete. Source plan archived to `backlog/done/lume-runtime-architecture-followups_followup.md`.

#### 9. Notification client catch-up + reconnect correctness

GitHub: [#547](https://github.com/fairchild/workspaces/issues/547) · `arc:notification-catchup`

Stable client identity, ACK cadence, duplicate/replay behavior. Reliability step before richer activity UX.

#### 10. Agent automation expansion

New autonomous-agent surfaces, broader reviewer features, and narration/eval expansion are no longer blocked by the managed-reviewer closure milestone, but they still sit behind the priority rule: first retire the post-release reliability debt above, then reassess whether the next highest-leverage move is more reviewer capability, notification catch-up, terminal continuity, or Web Dashboard work.

#### 11. Agent/session mission control and richer session metadata

GitHub: [#680](https://github.com/fairchild/workspaces/issues/680) · `area: ui` / `devEx`

Wanted product direction: a keyboard-first overlay/read model for live repo, workspace, terminal, web, and agent surfaces. It should rank attention-demanding sessions first, show bounded preview/status text, surface branch/worktree and cost/context data when already available, and focus the existing target without adding persistent chrome.

This is the user-facing legibility layer for the agent-status work that already exists in `AgentSessionRegistry` and `WorkspaceStatusAggregator`. Prototype behind a fixture or experimental path first; productionize only after the read model is cheap, stable-ID routed, and covered by focused ordering/truncation tests.

#### 12. Local app-shell control plane for agents

GitHub: [#628](https://github.com/fairchild/workspaces/issues/628) · `devEx`

Wanted product direction: a local socket API plus `workspaces` CLI commands that let a trusted process inside a terminal tile operate its own WorkSpaces shell: split/close/focus tiles, open a web surface, and set lightweight tab/session metadata.

This should ride on the Tile Tree reducer and stable tile/surface IDs rather than inventing a parallel layout model. Gate it behind an explicit trust setting, keep the socket same-user/local-only, and scope callers to their registered surface by default.

#### 13. Agent-verifiable embedded web surfaces

GitHub: [#679](https://github.com/fairchild/workspaces/issues/679) · `area: ui` / `devEx`

Wanted product direction: make active WorkSpaces-owned `WKWebView` surfaces inspectable and safely operable by trusted local agent sessions. The first slice is list + bounded snapshot by stable web-source ID: URL, title, bounded visible/page text, explicit truncation metadata, and structured failures.

This complements the control-plane work but should not wait for a full browser automation product. Keep the first version local-only, active-surface-only, and non-disruptive to user focus. Interaction verbs such as click/fill/evaluate can follow only after the trust boundary and audit story are settled.

### Later (P2)

#### 14. Strategic isolation backend direction

GitHub: [#533](https://github.com/fairchild/workspaces/issues/533) (VZ Tahoe tracking) + [#555](https://github.com/fairchild/workspaces/issues/555) (remote runtime expansion tracking) + [#532](https://github.com/fairchild/workspaces/issues/532) (Daytona native Swift) + [#616](https://github.com/fairchild/workspaces/issues/616) (AgentFS provider spike) · `arc:isolation-backend`

Current native-backend direction. Lume and Daytona already ship; VZ/Tahoe stays P2 until earlier quality debt is materially lower. AgentFS is promising as an experimental provider, not a replacement for the current git-worktree local default; validate filesystem, git, lifecycle, symlink/binary, and terminal-wrapper-vs-mounted-path behavior before product implementation. `backlog/done/isolation-strategies.md` holds the long-form option tradeoff history.

### Icebox (P3)

- Sparkle auto-update: already shipped under closed umbrella #2; source archived at `backlog/done/sparkle-autoupdate-plan.md`
- Swift dev skills task list: [#552](https://github.com/fairchild/workspaces/issues/552)
- Dev-build warning cleanup + mise task migration: [#551](https://github.com/fairchild/workspaces/issues/551)

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

| Roadmap theme | Arc label | Milestone posture |
|---|---|---|
| Core reliability and maintainability | `arc:core-reliability` | Active P0 theme; hardening cluster [#634](https://github.com/fairchild/workspaces/issues/634)/[#635](https://github.com/fairchild/workspaces/issues/635)/[#636](https://github.com/fairchild/workspaces/issues/636) |
| Tile Tree + Surface abstraction | — (epic [#627](https://github.com/fairchild/workspaces/issues/627)) | Active execution lane: stacked PRs on `c-tile-surface-abstraction` (Phases 0–2 landed/in review). Phase 8 records the ADR reversing `docs/decisions/terminal-multiplexing.md`. |
| Release and local-configuration reliability debt | `area: platform` / `area: distribution` / `devEx` | Closed in `v0.18.0`: [#615](https://github.com/fairchild/workspaces/issues/615) (PR #619) and [#617](https://github.com/fairchild/workspaces/issues/617) (PRs #620/#621). |
| Managed reviewer reliability and understandability | `area: platform` | Closed in `v0.17.0`: [#584](https://github.com/fairchild/workspaces/issues/584) / [milestone 8](https://github.com/fairchild/workspaces/milestone/8). Treat the ReviewRun-first model as baseline doctrine. |
| Lume runtime hardening | `arc:lume-runtime` | Closed (#87/#88/#89). Label retained for future Lume work. |
| Notification catch-up and reconnect correctness | `arc:notification-catchup` | Next standalone after core-reliability theme clears |
| Terminal continuity (tmux + cross-session) | `arc:terminal-continuity` | 2026-04-23 decision partially superseded by #627 (pane-tree reversal; ADR in Phase 8). #548 cross-session restore stays valid; re-scope #549 after the ADR. |
| Agent surface legibility and control | — | Next product direction: mission control [#680](https://github.com/fairchild/workspaces/issues/680), local app-shell control [#628](https://github.com/fairchild/workspaces/issues/628), and verifiable web surfaces [#679](https://github.com/fairchild/workspaces/issues/679). Sequence behind the Tile Tree identity/surface work where needed. |
| Strategic isolation backend direction | `arc:isolation-backend` | Backlog/research until promoted by a fresh approved discussion |

---

## Backlog Index

**Index policy** — one comprehensive index, tagged by Scope. Priority Bands above stay strategic-product-only. Quality, ops, and tooling items live in this index so nothing becomes an orphan, but they do not clutter the bands. Priority values match the bands; completed items show `Done`, and items not yet promoted show `—` (awaiting promotion or awaiting a dependent decision).

Scope tags:

- `product` — strategic capability or feature
- `quality` — test coverage, reliability, or regression safety net for already-shipped work
- `ops` — infrastructure, runners, release plumbing
- `tooling` — dev productivity, build/CI, internal skills

Live source of truth is GitHub Issues on `fairchild/workspaces`. This table mirrors the strategic posture for items that have been promoted to issues; for the full operational queue use `gh issue list` (or the `backlog` skill).

| Item | Scope | Priority | Issue |
|------|-------|----------|-------|
| Workspace creation hang root cause | product | P0 | [#554](https://github.com/fairchild/workspaces/issues/554) (live-repro gated; hypothesis comment 2026-06-09) |
| Tile Tree + Surface abstraction epic | product | P0 | [#627](https://github.com/fairchild/workspaces/issues/627) (Phases 0–2: PRs #625, #633) |
| ProcessRunner subprocess hang hardening | quality | P1 | [#634](https://github.com/fairchild/workspaces/issues/634) |
| Workspace deletion session coordination + cleanup visibility | quality | P1 | [#635](https://github.com/fairchild/workspaces/issues/635) |
| Startup orphan reconciliation | quality | P2 | [#636](https://github.com/fairchild/workspaces/issues/636) |
| Performance contract: main-window hot spots | quality | P1 | [#637](https://github.com/fairchild/workspaces/issues/637) |
| Desktop UI smoke: daily-driver flows | quality | P2 | [#638](https://github.com/fairchild/workspaces/issues/638) (protects #627 Phase 3/5 flips) |
| Main-window + sidebar maintainability | product | P0 | covered by closed #81 + residual notes in `backlog/done/main-window-sidebar-maintainability_followup.md` |
| AGENTS.md startup-budget refactor | tooling | P1 | [#626](https://github.com/fairchild/workspaces/issues/626) |
| Agent/session mission control and richer session metadata | product | P1 | [#680](https://github.com/fairchild/workspaces/issues/680) |
| Local app-shell control plane for agents | product | P1 | [#628](https://github.com/fairchild/workspaces/issues/628) |
| Agent-verifiable embedded web surfaces | product | P1 | [#679](https://github.com/fairchild/workspaces/issues/679) |
| Release preflight check-run pagination | quality | Done | [#615](https://github.com/fairchild/workspaces/issues/615) (PR #619) |
| Claude hook installer idempotence and backup hygiene | quality | Done | [#617](https://github.com/fairchild/workspaces/issues/617) (PRs #620/#621) |
| Managed reviewer ReviewRun-first hardening | quality | Done | [#584](https://github.com/fairchild/workspaces/issues/584) + [milestone 8](https://github.com/fairchild/workspaces/milestone/8) |
| Ghostty appearance hardening | product | Done | closed #84 |
| Tmux per-worktree implementation | product | P1 | [#549](https://github.com/fairchild/workspaces/issues/549) (re-scope after the #627 Phase 8 ADR supersedes `docs/decisions/terminal-multiplexing.md`) |
| Desktop continuity (across-session restore) | product | P1 | [#548](https://github.com/fairchild/workspaces/issues/548) (paired with #549) |
| Lume runtime architecture follow-ups | product | Done | closed #87, #88, #89 |
| Notification client catch-up | product | P1 | [#547](https://github.com/fairchild/workspaces/issues/547) |
| Managed PR reviewer continuous reruns | quality | absorbed | [#545](https://github.com/fairchild/workspaces/issues/545) is absorbed by [#584](https://github.com/fairchild/workspaces/issues/584) / [milestone 8](https://github.com/fairchild/workspaces/milestone/8) |
| PR reviewer narration eval skill | product | — | [#546](https://github.com/fairchild/workspaces/issues/546) |
| Daytona native Swift API | product | — | [#532](https://github.com/fairchild/workspaces/issues/532) |
| Remote runtime expansion (tracking) | product | — | [#555](https://github.com/fairchild/workspaces/issues/555) |
| Terminal PTY relay (sandbox) | product | — | [#529](https://github.com/fairchild/workspaces/issues/529) |
| Terminal architecture (tracking) | product | — | [#520](https://github.com/fairchild/workspaces/issues/520) (children #521–#527) |
| Terminal polish | product | — | [#528](https://github.com/fairchild/workspaces/issues/528) |
| Detail Pane sticky width | product | — | [#530](https://github.com/fairchild/workspaces/issues/530) |
| Web API authorization hardening (tests) | quality | — | [#535](https://github.com/fairchild/workspaces/issues/535) |
| Web dashboard component regression tests | quality | — | [#536](https://github.com/fairchild/workspaces/issues/536) |
| Web dashboard CD deployment-smoke | quality | — | [#543](https://github.com/fairchild/workspaces/issues/543) |
| CD auto-opener stale-close / dedup policy | quality | — | [#557](https://github.com/fairchild/workspaces/issues/557) |
| Shared-desktop focus contention Phase 2 | quality | P2 | residual notes in `backlog/done/shared-desktop-focus-contention-followup.md` (Phase 1 closed under #82) |
| Tahoe VZ backend execution brief (tracking) | product | P2 | [#533](https://github.com/fairchild/workspaces/issues/533) |
| AgentFS experimental provider spike | product | P2 | [#616](https://github.com/fairchild/workspaces/issues/616) |
| Web dashboard Phase 3 (tracking) | product | P2 | [#537](https://github.com/fairchild/workspaces/issues/537) + children #538–#541 |
| Spaces agent discovery dashboard | product | P2 | [#542](https://github.com/fairchild/workspaces/issues/542) |
| Sparkle auto-update | product | Done | covered by closed #2 (verified shipped) |
| Dev-build warning cleanup + mise tasks | tooling | P3 | [#551](https://github.com/fairchild/workspaces/issues/551) |
| Swift dev skills task list | tooling | P3 | [#552](https://github.com/fairchild/workspaces/issues/552) |
| Signing-host runner provisioning | ops | — | [#553](https://github.com/fairchild/workspaces/issues/553) (human lane) |

Archived (in `backlog/done/`):

- Pane-tree terminal tiling model — deferred 2026-04-23 (`docs/decisions/terminal-multiplexing.md`), then deliberately revived as the Tile Tree epic [#627](https://github.com/fairchild/workspaces/issues/627) (Phase 8 records the superseding ADR)
- Terminal multiplexing decision session — resolved by `docs/decisions/terminal-multiplexing.md` (2026-04-23)
- Isolation strategies (research) — superseded by Tahoe VZ execution brief
- `cloudflare-sandbox` live plan — scaffold deleted in PR #321
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

### 2026-06-09 — Daily-driver readiness review (issues #634–#638, PR #633 review)

- **A structural review lands best as issues plus a roadmap diff, not a report.** Four parallel explorers (reliability, performance, architecture, tests) produced findings that mostly *confirmed* the existing P0s — the new value was three untracked clusters (subprocess hangs, cleanup visibility, desktop UI smoke) and two staleness fixes. Encoding them as #634–#638 with file:line evidence makes them executable by cold sessions; the report alone would have evaporated.
- **Map the symptom string before claiming a root cause.** The ProcessRunner EOF-starvation hang is real and deterministic, but "Finishing workspace..." maps to `.finished` — *after* the setup script returns — so it can't be the reported #554 hang. Checking the phase-string-to-code mapping took one `rg` and converted an overclaim into an honest hypothesis branch plus an ungated hardening issue (#634).
- **Performance findings route through the contract, not past it.** Code-reading found four plausible hot spots; the roadmap's own posture ("performance is a system now") means the right move is contract scenarios + baselines first (#637), fixes second. Magnitudes from reading are hypotheses.
- **An epic that reverses a recorded decision must update the strategy docs in the same arc.** #627 deliberately reversed the 2026-04-23 multiplexing decision in April–June PRs while the roadmap still presented tmux-primary as operative — anyone planning from the roadmap would have sequenced #549 wrong. Reversal PRs should touch the roadmap (or the decision doc) in the same change, not wait for the Phase 8 ADR.

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
- The workshop skill already prioritizes `scripts/setup` in its detection table, but the script itself was too minimal to be useful
- Local SQLite fallback needs `mkdirSync` for the data directory — fresh clones/worktrees hit ENOENT without it
- Workshop setup should always run `scripts/setup` before starting dev servers — this is documented in the workshop skill but easy to skip

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

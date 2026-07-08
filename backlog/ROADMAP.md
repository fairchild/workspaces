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

**Desktop app.** Terminal-first main window with repo overview and persistent repo/workspace terminals. Calmer repo-first sidebar with explicit sorting and per-window last-surface restoration. Ghostty-backed terminal with split/focus/resize/equalize and working shortcut routing. Local workspaces plus Lume and Daytona provider tracks, including host-side validation and setup flows for Lume. Notification/auth/activity infrastructure, workspace process monitoring, and agent-awareness in repo overview cards. A canonical performance system (`workspaces-performance-system` skill + `config/performance/contract.json`) enforces scenario budgets across debug, installed, release, and CI environments. The terminal layout model has completed its transition: the Tile Tree + Surface abstraction epic ([#627](https://github.com/fairchild/workspaces/issues/627), **closed 2026-07-07**) replaced the two-pane split maps with a recursive tile tree — recursive renderer, N-way tiling, `SurfaceStore` as the live owner / eviction authority, web-through-the-seam, the `TileTreeStore` rename, the Phase 8 ADR superseding `docs/decisions/terminal-multiplexing.md` (#693), and geometric depth-≥2 directional focus (#690, PR #867). Epic follow-ons are filed as #872 (web tiles), #873 (per-tile tabs), #874 (pane zoom). Recent shipping also added a WorkSpaces automation API/CLI (#684/#628), a keyboard-shortcut cheat-sheet (#691), a keyboard-first session switcher, archive-to-`.archived/` workspace lifecycle (#661), a needs-you notification dropdown, and in-app feedback capture (#699). The Orca-inspired parallel-agent track shipped its first two slices on 2026-07-07: an experimental caller-scoped `input.write` automation capability (#798, double-gated, submit via synthetic Return) and a `ws race` CLI verb fanning one prompt across N worktree workspaces with detached headless agents (#800). Follow-up slices are filed, not promoted: fleet view + CLI→app workspace reconciliation (#836), winner→PR ship lane (#837), cross-tile writes via child handles (#838, `idea`).

**Web dashboard** (`web/`). Next.js 15 on Vercel with GitHub OAuth (Better Auth) and LibSQL+Kysely persistence. A ghostty-web terminal tab and a TerminalShare Cloudflare Worker proxy. A multi-provider agent runtime now covering Vercel Sandbox and Anthropic Managed Agents, with Daytona/GitHub Actions registered as unavailable stubs and `mock` available for tests (#332). Persistent-sandbox snapshot/restore for conversation continuity (#277); tmux inside the sandbox for real resume continuity (#311/#312/#315, clarified in #324). Automated PR review posted by Managed Agents (#345), with continuous reruns on PR updates (trigger classification + durable run fingerprints + prior-review context, closed under #545). Preview → validate → promote CD pipeline with a bootstrap orchestrator (#344) and a `deployment-smoke` Playwright lane in both preview and prod validators (#543). PostHog telemetry (#336). A `qa-web` skill + subagent (#343) covers black-box exploratory testing, author-mode spec generation, and heal-mode regression-vs-selector-drift triage. The 2026-07-02 cycle closed out milestone #7: middleware validates session freshness at the edge (#541, PR #727), a jsdom component-test lane guards dashboard render/race regressions (#536, PR #731), narrow viewports get a sidebar drawer + reachable activity feed (#539, PR #732), and the dead Chat SDK bot island was retired while keeping the dashboard Chat tab (#540, PR #725).

**Agent automation.** The `.agents/skills/` library (`workspaces-performance-system`, `workspaces-optimization`, `drive`, `peter-planner`, `gh-discuss`, and others). Managed PR review is now ReviewRun-first, repairable, documented, quiz-validated, and closed under milestone #8. The scheduled contributor fleet is **live**: `AGENT_AUTOMATIONS_ENABLED` is `true`, so April Clearwater and Plat Ironwood run on their daily crons and Oliver Obever runs the weekly ops observer (verify with `gh variable get AGENT_AUTOMATIONS_ENABLED` and `gh run list --workflow agent-april.yml`). April prefers the `lume-macos` self-hosted runner and falls back to `ubuntu-latest` when none is online — currently the case, since only the signing-host runner is up. What remains genuinely un-shipped is the *broader* vision, not the kill switch: a Fable orchestrator that produces one daily recommendation, agent-driven feedback triage, persistent agent memory (Phase 2), and formal debate/vote. Prompt-injection defense and runner-ephemerality hardening continue in parallel — see the Actions-agent security work.

**Shipping cadence.** Weekly-ish releases. Latest release `v0.22.0`.

What this means for planning.

- The product is three surfaces, not one, and they do not age at the same rate.
- The highest risk is now complexity management and determinism across surfaces, not raw feature absence.
- Terminal-first remains the product's core promise; everything else is in service of that, including the web and agent surfaces.
- Performance has moved from crisis to system. Ongoing measurement via the canonical contract is the norm, not a fire drill.
- Agent automation must earn expansion by improving delivery throughput and reducing review drag on already-shipped workflows, not by adding more autonomous surfaces first.
- The 2026-06-09 daily-driver readiness cluster has been **retired**: the ProcessRunner subprocess-hang hardening (#634), deletion/cleanup coordination (#635), startup orphan reconciliation (#636), and desktop UI smoke net (#638) all closed, as did the release/config debts (#615/#617), the AgentFS spike (#616), the CD dedup policy (#557), the AGENTS.md budget refactor (#626), and the automation API/CLI (#628). Milestone [#9 — Tile-tree completion + daily-driver reliability](https://github.com/fairchild/workspaces/milestone/9) closed out on 2026-07-07: epic #627 closed (#690 shipped geometric directional focus), the perf contract narrowed and landed its coalescer slice (#637), the maintainability seams cut (#708/#710) with the archive-lifecycle net (#709), and the lifecycle bugs retired (#663/#664/#670/#696/#666).
- **The entire D-lane (desktop) is closed as of 2026-07-08.** [#9](https://github.com/fairchild/workspaces/milestone/9), [#10 — durable sessions](https://github.com/fairchild/workspaces/milestone/10), and [`[D3]` #15 — product breadth](https://github.com/fairchild/workspaces/milestone/15) all closed in one continuous overnight arc. #15's three issues shipped in full, not just their narrowed first slices: native diff review + destructive stage/unstage/discard + dirty-nav veto (#704, PRs #894/#924 — two codex rounds closed a syscall-level TOCTOU, a stale-git-status misroute, and a save-then-navigate race), the shared `SessionActivity` read model + latest-activity session-card snippets (#680, PRs #896/#897/#930), and the Automation API `browser.read` plane — surface listing plus a bounded live-surface PNG snapshot (#679, PRs #898/#926). The D-lane queue is now **empty**; the next desktop theme has not been chosen yet.

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

---

## Priority Rule

Priority is driven by three filters, in this order:

- Protect the core promise first — select context, get a dependable terminal, keep working.
- Fix dependency debt before adding breadth — work that reduces regression risk outranks adjacent feature growth.
- Expand side systems only after they are trustworthy enough not to drag on the core.

Throughput means fewer stuck PRs, fewer manual review repairs, clearer operator state, and less rework on the workflows already in use. With managed-reviewer reliability, the release/config debts, and the 2026-06-09 hardening cluster (#634/#635/#636/#638) all closed, the next throughput gains come from milestone #9 — finishing the tile-tree epic and retiring the lifecycle/maintainability debt that recent shipping (archive, sidebar, Lume, managed-review) surfaced — before broadening agent automation or product breadth.

---

## Priority Bands

### Now (P0)

#### 1. Workspace creation hang root cause — closed 2026-07-07 (not reproducible)

GitHub: [#554](https://github.com/fairchild/workspaces/issues/554) · `arc:core-reliability`

**Closed as not-reproducible.** This sat in the top band since March with no live reproduction against the shipped diagnostics — a phantom P0 that anchored planning without earning it. The instrumentation stays load-bearing: `os.Logger` signposts + a 30-second watchdog (PR #190) and the regression net (PR #372) are in place, and `WorkspaceCreationRaceTests` rules out a basic in-memory deadlock. In-vitro investigation is exhausted (the MainActor-serialized save path can't deadlock without an external factor — slow disk, vanished store path, SwiftData WAL-pressure locks). The watchdog will surface the `.finished`-stage hang if it recurs; reopen with real signpost evidence then, not before.

**Adjacent ungated hardening (2026-06-09) — shipped.** A reliability review found a second, deterministic hang class upstream of the reported symptom: `ProcessRunner.run` had no timeout and required pipe EOF, so a lifecycle script that backgrounds a child hung creation at "Running setup..." forever (12 services share the runner). It did *not* explain the reported `.finished`-stage hang. The hardening was ungated and shipped: subprocess-hang hardening (#634), deletion-coordination + cleanup visibility (#635), and startup orphan reconciliation (#636).

#### 2. Tile Tree + Surface abstraction epic

GitHub: [#627](https://github.com/fairchild/workspaces/issues/627) · branch `c-tile-surface-abstraction`

The product epic: replace the two-pane split maps (`HostTerminalStateStore`) with a recursive tile tree plus a `protocol Surface` seam, so a tile can host a terminal or a web view. This deliberately **reversed** the 2026-04-23 `docs/decisions/terminal-multiplexing.md` choice (pane-tree deferred indefinitely); the Phase 8 ADR recording the reversal has landed (#693). Phases 0–5 merged (PRs #625/#633/#645/#658/#701) — the tree is the render source of truth, N-way tiling ships, and `SurfaceStore.sync(activeLeafIDs:)` is the live terminal surface eviction authority. Phase 6 (web main content through the seam, shared-store-per-source) and the Phase 7 rename sweep landed 2026-07-06; remaining is depth-≥2 directional-focus traversal hardening (#690), with the daily-driver smoke net (#638 — now also gating web-through-seam) in place. The epic's still-open seam — the `GhosttySurfaceView`/AppKit lifecycle boundary the `TerminalSurface` conformer should own — is tracked as #710.

#### 3. Main-window + Ghostty boundaries maintainability

The remaining active P0 work is the structural maintainability lane. The narrow Ghostty appearance hardening lane has shipped, and the first Ghostty boundary seams have landed.

- **3a. Main-window + sidebar maintainability** (structural). Sidebar Phase 1 landed (PR #36), and later controller seams moved more selection, bootstrap, surface-resolution, remote-workspace, and sorting behavior out of the root view. Remaining scope is still actionable but should stay incremental: shrink `ContentView.swift` / `SidebarView.swift` integration hotspots without changing navigation, workspace creation, split handling, or inspector behavior. Sequencing note (2026-06-09): while #627 Phases 2–5 are in flight, target the *non-terminal* seams first — the duplicated bootstrap logic (`MainWindowSurfaceResolutionController` internally instantiates its own `MainWindowBootstrapController`), the three competing error-presentation patterns, and selection-state extraction — and leave terminal-orchestration code to the epic to avoid churn. The bootstrap-dedup + error-presentation-unification slice is now tracked as [#708](https://github.com/fairchild/workspaces/issues/708) (milestone #9). Sidebar Phase 1 source plan: `backlog/done/main-window-sidebar-maintainability_followup.md` (closed #81 + residual notes).
- **3b. Ghostty boundary cleanup** (structural). PR #387 extracted runtime callback config wiring into `GhosttyRuntimeConfigFactory`; PR #394 centralized callback userdata and main-thread bridging. Remaining Ghostty work should now focus on the still-dense `GhosttySurfaceView` / AppKit lifecycle boundary, not on the completed callback userdata/config seams. The `TerminalSurface` conformer from #627 Phase 2 is the natural home for that boundary; the extraction is tracked as [#710](https://github.com/fairchild/workspaces/issues/710) (milestone #9).
- **3c. Ghostty appearance hardening** (completed). Split-routing controller coverage shipped in PR #379. Appearance dedupe coverage and docs parity shipped in PR #383, and current smoke docs/scripts already state the Ghostty-splits/tmux preconditions. Closed under #84.

P0 because these integration files still carry the highest regression risk when terminal, workspace, and activity behavior changes land. Treat this as a sequence of small behavior-preserving refactors with focused tests, not a broad rewrite.

#### 4. Shared-desktop + evidence-loop reliability — Phase 1 done; Phase 2 deferred to P2

Phase 1 complete: `AppActivationPolicy` (PR #374) gates all `NSApp.activate` calls — launch *and* runtime — behind `WORKSPACES_NO_ACTIVATE_ON_LAUNCH=1` / `CI`. `scripts/capture-window.sh` provides window-id capture without activation. Remaining items (capture handshake, separate-user execution lane, VM-backed CI lane) drop to P2 — promote back when a concrete daily-driver scenario forces the issue. **Promotion happened (2026-07-07):** recurring evidence-capture failures forced it, and the in-app half (self-capture over an operator-scoped Automation API) is now milestone [#16 `[A1]`](https://github.com/fairchild/workspaces/milestone/16) per `docs/decisions/automation-operator-scope.md`; the VM/separate-user lanes stay P2 as the full-fidelity fallback. Phase 1 source: `backlog/done/shared-desktop-focus-contention-followup.md` (closed #82 + residual notes).

#### 5. Release and local-configuration reliability debt — completed in `v0.18.0`

GitHub: [#615](https://github.com/fairchild/workspaces/issues/615) + [#617](https://github.com/fairchild/workspaces/issues/617) · `area: platform` / `area: distribution` / `devEx`

Both closed: release preflight check-run pagination shipped (PR #619), and the Claude hook installer now writes machine-agnostic, shell-safe commands without backup churn (PRs #620/#621). The core-reliability hardening cluster that succeeded it (#634/#635/#636) has since closed too; the live reliability theme is now milestone [#9](https://github.com/fairchild/workspaces/milestone/9).

#### 6. Managed reviewer reliability and understandability — completed in `v0.17.0`

GitHub: [#584](https://github.com/fairchild/workspaces/issues/584) · milestone [Managed reviewer: understandable ReviewRun-first system](https://github.com/fairchild/workspaces/milestone/8) · `area: platform`

Milestone #8 is closed. Closure validation covered pickup, terminal state, details URL, projection repair behavior, ReviewRun-first health, GitHub projection audit separation, release/Sparkle verification, and human-maintainer quiz review. Keep the shipped ReviewRun-first model as baseline operating doctrine, and file any new reviewer work as specific follow-up debt rather than reopening the milestone.

### Next (P1)

#### 7. Terminal continuity — cross-session restore; tmux posture pending the #627 ADR

GitHub: [#549](https://github.com/fairchild/workspaces/issues/549) (tmux implementation) + [#548](https://github.com/fairchild/workspaces/issues/548) (across-session restore) · `arc:terminal-continuity`

The 2026-04-23 decision (`docs/decisions/terminal-multiplexing.md`: tmux primary, pane-tree deferred) was **superseded** by the Tile Tree epic (#627), whose Phase 8 ADR has now landed (#693). What survives the reversal cleanly is the continuity question — tile trees don't keep processes alive across app restarts, so #548 (close laptop, reopen, pick up where you left off) remains valid regardless of layout model and can proceed independently. The first continuity slice already shipped: tmux preserves live process state when the server survives, and the terminal continuity manifest records target + launch directory as the honest fallback. With the ADR settled, #549 is **unblocked but needs re-scoping**: decide whether tmux still owns per-worktree *multiplexing* now that the tile tree owns split layout, or whether it narrows to cross-session continuity only. Re-scope before promoting (see the grooming note on #549).

#### 8. Lume runtime architecture cleanup

Closed: #87, #88, #89 · `arc:lume-runtime`

Contract proven (PR #54). The three decomposition follow-ups (shared HTTP transport, native detachment + VM typing, doc refresh) all closed; reviewer-friction work is complete. Source plan archived to `backlog/done/lume-runtime-architecture-followups_followup.md`.

#### 9. Notification client catch-up + reconnect correctness

GitHub: [#547](https://github.com/fairchild/workspaces/issues/547) · `arc:notification-catchup`

Stable client identity, ACK cadence, duplicate/replay behavior. Reliability step before richer activity UX.

#### 10. Agent automation expansion

New autonomous-agent surfaces, broader reviewer features, and narration/eval expansion are no longer blocked by the managed-reviewer closure milestone, but they still sit behind the priority rule: first retire the post-release reliability debt above, then reassess whether the next highest-leverage move is more reviewer capability, notification catch-up, terminal continuity, or Web Dashboard work.

### Later (P2)

#### 11. Strategic isolation backend direction

GitHub: [#533](https://github.com/fairchild/workspaces/issues/533) (VZ Tahoe tracking) + [#532](https://github.com/fairchild/workspaces/issues/532) (Daytona native Swift) · `arc:isolation-backend`. The AgentFS provider spike (#616) has concluded; the remote-runtime expansion tracker (#555, SSH/k8s/Compose) is parked under the `idea` label until a concrete demand promotes it.

Current native-backend direction. Lume and Daytona already ship; VZ/Tahoe stays P2 until earlier quality debt is materially lower. `backlog/done/isolation-strategies.md` holds the long-form option tradeoff history.

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

**Two parallel lanes (2026-07-07).** The product is two surfaces that share neither a codebase nor an aging curve — the Mac-native desktop app and the `web-next` hosted sessions app. They run as **independent lanes**, each with **one active milestone at a time**. This is the sanctioned exception to the single-active-milestone default: the lanes don't contend for the same files or the same reviewer context, so parallel is honest rather than a focus tax. Both are held to the same bar — quality and performance over feature breadth, no compromise on maintainability, a calm crafted surface.

**Automation lane added (2026-07-07).** A third lane (`A`) covers the automation two-arc strategy — reliable evidence capture, then agent workspace orchestration (`docs/decisions/automation-operator-scope.md`). Independence argument: the work lives in the Automation service seam (`Sources/WorkspaceManagerCore/Services/Automation/`), the `workspaces` CLI, and `scripts/`, while `[D3]` #15's remaining tail is live-desktop-gated and parked; the one shared thread is #679's bounded-snapshot e2e, which `[A1]`'s snapshot route supersedes as the capture mechanism.

### Active milestone stack

**Milestone titles are self-describing (2026-07-07).** Each open milestone carries a `[<lane><order>]` title prefix — `D` = desktop, `W` = web-next, `A` = automation, number = execution order within the lane — so the stack below reads straight off the milestone list, and the number-vs-order inversion (execution runs `[W1]#11 → [W2]#14 → [W3]#13 → [W4]#12`, not by issue number) is visible on sight. Each milestone description also leads with a `[LANE: … · ACTIVE|QUEUED]` posture header. A read-only drift gate (`scripts/milestone-legibility-check.py`, `.github/workflows/milestone-legibility.yml`) fails if any open milestone loses its prefix or posture tag. `peter-planner` matches milestones by the prefix-stripped name, so the convention doesn't disturb automated planning.

| Lane | Active now | Queued next | Sequencing note |
|---|---|---|---|
| **Desktop** | *(D-lane queue empty — no active milestone)* | *(next theme not yet chosen)* | [#9](https://github.com/fairchild/workspaces/milestone/9), [#10](https://github.com/fairchild/workspaces/milestone/10), and [`[D3]` #15](https://github.com/fairchild/workspaces/milestone/15) **all closed** — #9/#10 on 2026-07-07, #15 on 2026-07-08. #15 shipped past its verify-before-plan narrowing to full closure on all three issues: #704 (native diff review + destructive stage/unstage/discard + dirty-nav veto, PRs #894/#924), #680 (shared `SessionActivity` read model + latest-activity session-card snippets, PRs #896/#897/#930), #679 (Automation API `browser.read` — surface listing + bounded live-surface PNG snapshot, PRs #898/#926). Recorded live spot-checks (production-framework resume demo per #728/#895, #924's destructive-path click-through) are **post-merge** verification, not open milestone work. |
| **Automation** | **[#17](https://github.com/fairchild/workspaces/milestone/17) — `[A2]` agent workspace orchestration (verbs = clicks)** | *(A-lane queue empty — companion-app surface is post-A2)* | [#16](https://github.com/fairchild/workspaces/milestone/16) `[A1]` **closed 2026-07-08**, all four slices merged in one orchestrated day (#933 spike memo, #941 operator scope, #942 window.snapshot, #943 evidence lane): own-window capture is TCC-free, the GhosttyKit surface reads back (IOSurfaceLayer), and `./scripts/evidence.sh --pr <N> --fixture <scenario>` is the sanctioned first-choice capture path with a non-blank content gate as permanent lane contract. `[A2]` is now **active**, riding the proven trust model: gesture-verb layer under the verbs-=-clicks contract (`docs/decisions/automation-operator-scope.md`), workspace verbs, App Intents veneer, API-driven smoke lane gated on milestone parity. |
| **web-next** | **[#11](https://github.com/fairchild/workspaces/milestone/11) — sessions-first** | **[#14](https://github.com/fairchild/workspaces/milestone/14) essentials → [#13](https://github.com/fairchild/workspaces/milestone/13) → [#12](https://github.com/fairchild/workspaces/milestone/12) (thinned)** | Real runtime landed (#822+#831). Finish #11 (drawer #752, lifecycle/errors #753, edit→diff #790, build flake #780, cutover #754), then the start-and-identify loop (#823 title, #824 model, #825 repo picker), then self-validation (#13). Ordered by the web-next phase plan, not milestone number — see `web-next/docs/roadmap.md`. |
| **Desktop** | **[#15](https://github.com/fairchild/workspaces/milestone/15) — product breadth** | *(D-lane queue empty — next theme promotes from the backlog)* | [#9](https://github.com/fairchild/workspaces/milestone/9) and [#10](https://github.com/fairchild/workspaces/milestone/10) both **closed 2026-07-07**: the full debt cluster and the durable-sessions arc landed (#883–#898 wave; e2e resume proof in PR #888; restore-aware retention #886; #728/#548 closed with ledgers; #729 moved to backlog pending the owner's trust-boundary call). #15 is the **active** milestone and is substantially shipped after verify-before-plan collapsed each epic: #704 narrowed (native editor phases 0–2 pre-existed via #713/#720; diff-review render merged, PR #894), #680 narrowed (⌘P switcher pre-existed; shared `SessionActivity` read model + attention unification merged, PRs #896/#897), #679 narrowed (Automation API V1 is the control plane; `browser.read` list route merged, PR #898). Remaining #15 work is the **live-desktop-gated tail**: #704 stage/unstage/discard + dirty-nav, #680 latest-snippet cards, #679 bounded snapshot e2e — parked on an unlocked desktop with memory headroom, alongside the recorded live spot-checks (#893/#894 interactions, production-framework resume demo per #728's close and #895). |
| **Automation** | *(A-lane complete — companion-app surface promotes from the backlog when a concrete need forces it)* | — | Both arcs **closed 2026-07-08**, PRD #914 closed. [#16](https://github.com/fairchild/workspaces/milestone/16) `[A1]` (#933 spike memo, #941 operator scope, #942 window.snapshot, #943 evidence lane): own-window capture is TCC-free, the GhosttyKit surface reads back (IOSurfaceLayer), and `./scripts/evidence.sh --pr <N> --fixture <scenario>` is the sanctioned first-choice capture path with a non-blank content gate as permanent lane contract. [#17](https://github.com/fairchild/workspaces/milestone/17) `[A2]` (#946 workspace.read, #947 gesture-verb layer + select, #952 create + confirmation_required, #954 App Intents veneer, #955 API-driven smoke parity lane): one gesture-verb layer under socket/CLI/App Intents per the verbs-=-clicks contract (`docs/decisions/automation-operator-scope.md`); the parity report proves the API lane matches the UI lane's milestone contract — the UI lane stays authoritative, retirement is a later human decision. Residuals tracked, not vague: repo-select verb gap (parity report), Shortcuts hands-on spot check, SCK migration #944. |
| **web-next** | *(W-lane complete — next theme promotes from the backlog)* | **#820** (PR-from-session) is the standing follow-up, design-first | All four W milestones **closed 2026-07-08** ([#11](https://github.com/fairchild/workspaces/milestone/11)→[#14](https://github.com/fairchild/workspaces/milestone/14)→[#13](https://github.com/fairchild/workspaces/milestone/13)→[#12](https://github.com/fairchild/workspaces/milestone/12), executed in phase order). web-next ships at **folio.cloudcompute.com** — owner decision on #754: *no cutover*, the old `web/` dashboard stays in maintenance mode. Sign-in via the `web-workspaces` GitHub App; daily validation vs folio fully green incl. a 9/9 real agentic turn. History + follow-ups: `web-next/docs/roadmap.md`. |

**Personal-tool scope cut (2026-07-07).** web-next serves the owner only for now. **#829** (owner-scoped session sharing) is parked (`idea`, out of #14) until a real second login is wanted — it's the clean prerequisite to sharing, deferred not cancelled. Within **#12**, keyboard/contrast/visible-failure/compose work (#805/#806/#808/#807) stays because it helps the owner; assistive-tech announcements (#804) and mobile touch targets (#809) defer until web-next has an audience beyond one person. Craft aimed at users who don't exist yet is breadth, not quality.

**Perf floor: shipped; #856 re-scoped** ([#856](https://github.com/fairchild/workspaces/issues/856)). A web-next perf floor already exists — [#761](https://github.com/fairchild/workspaces/issues/761) landed `web-next/perf/` (8-scenario `contract.json` + `run.mjs` + a dated `BASELINE.md`) with `pnpm run perf` as a **hard** CI gate on every `web-next/**` PR. The earlier "no perf budget" framing was stale (verified 2026-07-07). #856 is re-scoped to the two real gaps: **(A)** a baseline-relative regression guard layered on the existing absolute budgets — the piece that makes "no *creeping* regressions" real before #754 goes primary; and **(B)** measuring the deployed target (Vercel edge/serverless), which rides #814's authenticated-preview seam rather than a separate mechanism.

Theme-to-milestone map:

| Roadmap theme | Lane / label | Milestone posture |
|---|---|---|
| Tile-tree completion + daily-driver reliability | Desktop · `arc:core-reliability` | **Substantially complete (2026-07-07)** — milestone [#9](https://github.com/fairchild/workspaces/milestone/9). Epic [#627](https://github.com/fairchild/workspaces/issues/627) is **closed**: #690 shipped geometric directional focus (PR #867) and the epic's follow-ons are filed, not open-ended (#872 web tiles, #873 per-tile tabs, #874 pane zoom). The debt cluster is paid — #708 (PRs #875/#879, follow-on #882), #710 (PR #877, slice-2 declined on demand-signal), #637 (narrowed, coalescer PR #876), #663/#664/#670/#709 closed. Remaining: #696 (broker recovery, in flight; live validation limited while the managed reviewer is paused) and #666 (real PTY foreground probe, in flight). |
| Durable sessions (reboot / resume / history) | Desktop · `arc:terminal-continuity` | **Closed (2026-07-07)** — milestone [#10](https://github.com/fairchild/workspaces/milestone/10). Epic [#728](https://github.com/fairchild/workspaces/issues/728) and #548 closed with verification ledgers; the resume contract was proven end-to-end on hardware (PR #888 evidence). #783 shipped the banner guards + bridge-delivered resume (and surfaced libghostty bug #889); #789 shipped restore-aware retention (#886). The `restoreSessionsOnLaunch` flag stays **default-off** with recorded flip preconditions (production-framework resume demo; #889 bridge workaround holds); split-layout fidelity is follow-on #895. #729 (cloud handoff) moved to backlog with a research memo — the trust-boundary yes/no is with the owner. #549 tmux (full path) still needs a re-scope before any pull-in. |
| Desktop product breadth | Desktop | **Closed (2026-07-08)** — milestone [#15](https://github.com/fairchild/workspaces/milestone/15) `[D3]`. All three issues verify-before-planned, narrowed, and shipped to full closure: #704 diff-review render + destructive stage/unstage/discard + dirty-nav veto (PRs #894/#924 — two codex rounds closed a syscall-level TOCTOU, a stale-status misroute, and a save-then-navigate race), #680 shared `SessionActivity` read model + severity-unified attention + latest-activity session-card snippets (PRs #896/#897/#930), #679 `browser.read` web-surface list + bounded live snapshot (PRs #898/#926). #706 (Pierre diff) stays `idea`. |
| Sessions-first web | web-next | **Active** — milestone [#11](https://github.com/fairchild/workspaces/milestone/11). Runtime landed (#822/#831); drawer/lifecycle/cutover/edit-diff/build-flake remain. |
| web-next usability completeness | web-next | **Queued** — milestone [#14](https://github.com/fairchild/workspaces/milestone/14): #823/#824/#825 start-loop essentials. #829 parked (personal-tool cut). |
| web-next self-validation | web-next | **Queued** — milestone [#13](https://github.com/fairchild/workspaces/milestone/13): validate the real runtime local→preview→prod. Valuable single-user (owner trust in the deployed path). |
| web-next refinement (a11y / resilience) | web-next | **Thinned** — milestone [#12](https://github.com/fairchild/workspaces/milestone/12): keep #805/#806/#807/#808; defer #804/#809 pending an audience. |
| Desktop product breadth | Desktop | **Active (2026-07-07)** — milestone [#15](https://github.com/fairchild/workspaces/milestone/15) `[D3]`. All three issues verify-before-planned and narrowed to their genuinely-open halves; first slices merged same-day: #704 diff-review render (PR #894, native editor phases 0–2 pre-existed), #680 shared `SessionActivity` read model + severity-unified attention (PRs #896/#897, killed a real two-ladder drift), #679 `browser.read` web-surface list on the Automation API (PR #898). Remaining tail is live-desktop-gated (destructive git wiring, dirty-nav veto, snippet cards, snapshot e2e) — parked with an explicit manifest, not open-ended. #706 (Pierre diff) stays `idea`. |
| Sessions-first web | web-next | **Closed (2026-07-08)** — milestone [#11](https://github.com/fairchild/workspaces/milestone/11). Runtime (#822/#831), drawer #752, lifecycle #753, edit→diff #790, build flake #780, and #754 reshaped to *ship at folio.cloudcompute.com* (no cutover; old dashboard in maintenance mode). |
| web-next usability completeness | web-next | **Closed (2026-07-07)** — milestone [#14](https://github.com/fairchild/workspaces/milestone/14): #823/#824/#825 start-loop essentials shipped. #829 stays parked (personal-tool cut). |
| web-next self-validation | web-next | **Closed (2026-07-08)** — milestone [#13](https://github.com/fairchild/workspaces/milestone/13): validation harness #813–#819 live; daily cron vs folio green incl. real agentic turn. |
| web-next refinement (a11y / resilience) | web-next | **Closed (2026-07-08)** — milestone [#12](https://github.com/fairchild/workspaces/milestone/12): #805/#806/#807/#808/#810/#811/#812/#828 + e2e determinism #901/#932 shipped; #804/#809 still deferred pending an audience. |
| Managed reviewer / Lume / release-config debt | — | Closed (milestones [#8](https://github.com/fairchild/workspaces/milestone/8)/#5, `v0.17`–`v0.18`). Baseline doctrine; file new reviewer work as specific follow-up debt. |
| Notification catch-up and reconnect correctness | Desktop · `arc:notification-catchup` | Standalone P1 (#547); no milestone until a desktop lane slot opens. |
| Parallel-agent race primitive (Orca-inspired) | Desktop-adjacent | Phase 0+1a shipped 2026-07-07 (#798/PR #799, #800/PR #801). Follow-ups filed unpromoted: fleet view #836, ship lane #837; #838 `idea`. |
| Automation two-arc: evidence capture → workspace orchestration | Automation | **Closed (2026-07-08)** — both arcs and PRD #914. `[A1]` [#16](https://github.com/fairchild/workspaces/milestone/16) (#933/#941/#942/#943; evidence lane live, locked-screen falls back to VM lanes, SCK migration #944). `[A2]` [#17](https://github.com/fairchild/workspaces/milestone/17) (#946/#947/#952/#954/#955; verbs = clicks held across socket/CLI/App Intents; parity lane shipped, UI smoke stays authoritative). Decision record: `docs/decisions/automation-operator-scope.md`. |
| Strategic isolation backend (VZ/Tahoe, Daytona-native) | Desktop · `arc:isolation-backend` | P2 research until a fresh approved discussion promotes it (#532/#533). |

Default execution policy:

- one active milestone **per lane**; a third concurrent milestone in either lane needs an explicit independence argument
- only `Now` items and explicitly pulled-forward `Next` items should become milestones
- milestone names come from the approved planning-discussion title; the roadmap tracks themes

---

## Backlog Index

**Index policy** — one comprehensive index, tagged by Scope. Priority Bands above stay strategic-product-only. Quality, ops, and tooling items live in this index so nothing becomes an orphan, but they do not clutter the bands. Priority values match the bands; completed items show `Done`, and items not yet promoted show `—` (awaiting promotion or awaiting a dependent decision).

Scope tags:

- `product` — strategic capability or feature
- `quality` — test coverage, reliability, or regression safety net for already-shipped work
- `ops` — infrastructure, runners, release plumbing
- `tooling` — dev productivity, build/CI, internal skills

Live source of truth is GitHub Issues on `fairchild/workspaces`. This table mirrors the strategic posture for items that have been promoted to issues; for the full operational queue use `gh issue list` (or the `backlog` skill).

Priority `idea` = parked in the `idea` label (speculative, may never be built); `stale` = tagged `stale` for maintainer close/delete review. Desktop items in milestone [#9](https://github.com/fairchild/workspaces/milestone/9) are noted `· ms9`. The old `web/` dashboard's milestone [#7](https://github.com/fairchild/workspaces/milestone/7) is closed; the live web track is now `web-next` across milestones [#11](https://github.com/fairchild/workspaces/milestone/11)–[#14](https://github.com/fairchild/workspaces/milestone/14), tracked in `web-next/docs/roadmap.md` rather than this index.

| Item | Scope | Priority | Issue |
|------|-------|----------|-------|
| Workspace creation hang root cause | product | Closed | [#554](https://github.com/fairchild/workspaces/issues/554) closed 2026-07-07 (not reproducible; diagnostics + watchdog shipped, reopen on real evidence) |
| Tile Tree + Surface abstraction epic | product | P0 · ms9 | [#627](https://github.com/fairchild/workspaces/issues/627) (Phases 0–4 landed: PRs #625/#633/#645/#658; Phase 5 + #690 remain) |
| Depth-≥2 directional tile-focus hardening | quality | P3 · ms9 | [#690](https://github.com/fairchild/workspaces/issues/690) |
| Performance contract: main-window hot spots | quality | P1 · ms9 | [#637](https://github.com/fairchild/workspaces/issues/637) |
| Main-window maintainability: error-presentation + bootstrap dedup | quality | P1 · ms9 | [#708](https://github.com/fairchild/workspaces/issues/708) (new) |
| Ghostty surface / AppKit lifecycle seam | quality | P1 · ms9 | [#710](https://github.com/fairchild/workspaces/issues/710) (new) |
| Archive/unarchive lifecycle regression-test net | quality | P1 · ms9 | [#709](https://github.com/fairchild/workspaces/issues/709) (new) |
| Unarchive corrupts path for legacy archived workspaces | quality | P1 · ms9 | [#663](https://github.com/fairchild/workspaces/issues/663) |
| Repo workspace count badge over-counts archived | quality | P2 · ms9 | [#664](https://github.com/fairchild/workspaces/issues/664) |
| Sidebar hover: real foreground process for plain tabs | quality | P2 · ms9 | [#666](https://github.com/fairchild/workspaces/issues/666) |
| Lume storage-missing diagnostic | quality | P2 · ms9 | [#670](https://github.com/fairchild/workspaces/issues/670) |
| Managed-review stuck-before-session recovery | quality | P1 · ms9 | [#696](https://github.com/fairchild/workspaces/issues/696) |
| ProcessRunner subprocess hang hardening | quality | Done | [#634](https://github.com/fairchild/workspaces/issues/634) |
| Workspace deletion coordination + cleanup visibility | quality | Done | [#635](https://github.com/fairchild/workspaces/issues/635) |
| Startup orphan reconciliation | quality | Done | [#636](https://github.com/fairchild/workspaces/issues/636) |
| Desktop UI smoke: daily-driver flows | quality | Done | [#638](https://github.com/fairchild/workspaces/issues/638) |
| Main-window + sidebar maintainability (Phase 1) | product | Done | closed #81; residual seams now #708 |
| AGENTS.md startup-budget refactor | tooling | Done | [#626](https://github.com/fairchild/workspaces/issues/626) |
| Socket API + CLI for in-app agent shell control | product | Done | [#628](https://github.com/fairchild/workspaces/issues/628) (shipped as automation API v1, #684) |
| Automation API `input.write` (caller-scoped PTY injection) | product | Done | [#798](https://github.com/fairchild/workspaces/issues/798) (PR #799; decision record `docs/decisions/automation-input-write.md`) |
| CLI `ws race` parallel fan-out | product | Done | [#800](https://github.com/fairchild/workspaces/issues/800) (PR #801) |
| AgentFS experimental provider spike | product | Done | [#616](https://github.com/fairchild/workspaces/issues/616) (spike concluded) |
| CD auto-opener stale-close / dedup policy | quality | Done | [#557](https://github.com/fairchild/workspaces/issues/557) |
| Release preflight check-run pagination | quality | Done | [#615](https://github.com/fairchild/workspaces/issues/615) (PR #619) |
| Claude hook installer idempotence and backup hygiene | quality | Done | [#617](https://github.com/fairchild/workspaces/issues/617) (PRs #620/#621) |
| Code signing + notarization | ops | Done | #3 (shipped baseline; runner provisioning is #553) |
| Managed reviewer ReviewRun-first hardening | quality | Done | [#584](https://github.com/fairchild/workspaces/issues/584) + [milestone 8](https://github.com/fairchild/workspaces/milestone/8) |
| Ghostty appearance hardening | product | Done | closed #84 |
| Lume runtime architecture follow-ups | product | Done | closed #87, #88, #89 |
| Native edit + diff-review loop | product | Done | [#704](https://github.com/fairchild/workspaces/issues/704) closed 2026-07-08, `[D3]` #15 (PRs #894/#924) (Pierre enhancement #706 is `idea`) |
| Browser-verifiable embedded web surfaces | product | Done | [#679](https://github.com/fairchild/workspaces/issues/679) closed 2026-07-08, `[D3]` #15 (PRs #898/#926) |
| Agent/session mission control + richer metadata | product | Done | [#680](https://github.com/fairchild/workspaces/issues/680) closed 2026-07-08, `[D3]` #15 (PRs #896/#897/#930) |
| Race fleet view + CLI→app workspace reconciliation | product | — (next ms candidate) | [#836](https://github.com/fairchild/workspaces/issues/836) |
| Race ship lane: winner → draft PR + managed review | product | — | [#837](https://github.com/fairchild/workspaces/issues/837) (depends on #836 for the compare step) |
| Cross-tile `input.write` via child-handle authority | product | idea | [#838](https://github.com/fairchild/workspaces/issues/838) |
| Tmux per-worktree implementation | product | P1 | [#549](https://github.com/fairchild/workspaces/issues/549) (unblocked by #693 ADR; re-scope before promoting) |
| Desktop continuity (across-session restore) | product | P1 | [#548](https://github.com/fairchild/workspaces/issues/548) (survives the reversal; can proceed) |
| Notification client catch-up | product | P1 | [#547](https://github.com/fairchild/workspaces/issues/547) |
| Claude integration: first-run discovery + error-state UI | product | P2 | [#517](https://github.com/fairchild/workspaces/issues/517) / [#518](https://github.com/fairchild/workspaces/issues/518) (ready) |
| Detail Pane sticky width | product | — | [#530](https://github.com/fairchild/workspaces/issues/530) |
| Managed PR reviewer continuous reruns | quality | Done | [#545](https://github.com/fairchild/workspaces/issues/545) closed 2026-07-02 (phases 1–4 shipped; rollout-flag residue split to [#724](https://github.com/fairchild/workspaces/issues/724)) |
| PR reviewer reruns rollout flag + skip-reason logs | quality | — | [#724](https://github.com/fairchild/workspaces/issues/724) (split from #545) |
| Review-layer stack calibration (gate depth vs risk) | quality | idea | [#733](https://github.com/fairchild/workspaces/issues/733) (owner: managed-review quality still "not quite right"; anchor for rethinking the 4-layer stack) |
| Remote-session environment gaps (evidence token, mise, Playwright browser) | ops | — | [#734](https://github.com/fairchild/workspaces/issues/734) (human lane; conventions doc `docs/development/remote-sessions.md` shipped meanwhile) |
| Daytona native Swift API | product | P2 | [#532](https://github.com/fairchild/workspaces/issues/532) (`arc:isolation-backend`) |
| Tahoe VZ backend execution brief (tracking) | product | P2 | [#533](https://github.com/fairchild/workspaces/issues/533) |
| Web API authorization E2E coverage | quality | Done | [#535](https://github.com/fairchild/workspaces/issues/535) closed 2026-07-02 (`web/e2e/fast/api-authorization.spec.ts`, all 8 cases verified green) |
| Web dashboard component regression harness | quality | Done | [#536](https://github.com/fairchild/workspaces/issues/536) shipped in PR #731 (`unit`+`component` Vitest projects, jsdom, 3 mutation-verified regression tests) |
| Web dashboard CD deployment-smoke | quality | Done | [#543](https://github.com/fairchild/workspaces/issues/543) closed 2026-07-02 (`deployment-smoke` project wired into `cd.yml` preview + prod validators, verified live) |
| Web Dashboard Phase 3 (tracking) | product | Done | [#537](https://github.com/fairchild/workspaces/issues/537) closed 2026-07-02 — all children done: #538, #539 (PR #732), #540 (retired, PR #725), #541 (PR #727). **Milestone #7 is empty.** |
| Web: persistent event store (Turso events table) | quality | Done | [#538](https://github.com/fairchild/workspaces/issues/538) (`lib/events.ts` is a Kysely `webhook_events` table) |
| Web: middleware session-freshness validation | quality | Done | [#541](https://github.com/fairchild/workspaces/issues/541) shipped in PR #727 (edge cookie-cache verification via `getCookieCache`; `web/src/lib/session-cookie.ts`) |
| Web: responsive layout for narrow viewports | product | Done | [#539](https://github.com/fairchild/workspaces/issues/539) shipped in PR #732 (sidebar hamburger drawer <640px, activity-feed toggle <960px, desktop unchanged) |
| Spaces agent-discovery dashboard | product | Done | [#542](https://github.com/fairchild/workspaces/issues/542) (repo scan + per-repo agents/pipeline shipped) |
| Terminal architecture (tracking) | product | — | [#520](https://github.com/fairchild/workspaces/issues/520) (cleanups #521/#524; #522 closed 2026-07-02 — scaffold was already deleted in commit `a467162`; UX children #523/#525/#526/#527/#528/#529 → `idea`) |
| PR reviewer narration eval skill | product | idea | [#546](https://github.com/fairchild/workspaces/issues/546) |
| Remote runtime expansion (tracking) | product | idea | [#555](https://github.com/fairchild/workspaces/issues/555) |
| Chat tab / Chat SDK epic | product | Done (chat tab kept; bot path retired) | #174/#181/#182/#224–#231 built the surface; `#540` resolved **retire** 2026-07-02 (PR #725): the SDK bot island (`bot.ts`/`ai.ts`/`slack-notifications.ts`/`[platform]` route + 4 deps) was dead code behind a 501 stub and was removed. The dashboard Chat tab (`api/chat/*`, `chat-panel.tsx`) never used the SDK and remains live + e2e-covered. |
| Shared-desktop focus contention Phase 2 | quality | P2 | residual notes in `backlog/done/shared-desktop-focus-contention-followup.md` (Phase 1 closed under #82) |
| Sparkle auto-update | product | Done | covered by closed #2 (verified shipped) |
| Dev-build warning cleanup + mise tasks | tooling | P3 | [#551](https://github.com/fairchild/workspaces/issues/551) |
| Swift dev skills task list | tooling | P3 | [#552](https://github.com/fairchild/workspaces/issues/552) |
| Signing-host runner provisioning | ops | — | [#553](https://github.com/fairchild/workspaces/issues/553) (human lane) |

Archived (in `backlog/done/`):

- Web next-cycle plan (2026-07) — fully executed same-day 2026-07-02 (PRs #723–#735; milestone #7 closed); see `backlog/done/web-next-cycle_plan.md`
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

### 2026-07-08 — [A2] workspace orchestration: 5 slices, contract held across 3 surfaces (#946/#947/#952/#954/#955)

- **One human-reviewed contract slice made the rest cheap.** The owner personally reviewed only #947 (the gesture-verb layer — the slice where verbs-=-clicks is enforced structurally, not by convention); #952/#954/#955 then extended the layer under delegated merge with zero contract drift. The replicable part is *what the coordinator checked* on each successor: the verb's entry point verified in the diff (not the PR prose), evidence images rendered and inspected, and read-back-from-live-UI rather than claimed effects. Encoded where it fires: the ADR names `workspace.select` as the exemplar; `.agents/skills/subagent-delegation/SKILL.md` carries the gate checklist.
- **Execution agents fail on harness, not model — preflight the verification loop.** A deliberate pi-vs-codex race on #921 (same brief, same worktree base, both xhigh): pi produced a structurally correct ~1,000-line implementation and died unverifiable because its sandbox blocked `swift`; codex shipped reviewed PR #952 in under an hour. Context absorption was the smaller gap than expected. Encoding: § "Before dispatching to a new execution agent" in `subagent-delegation/SKILL.md` (verify-loop preflight + context quiz + GhosttyKit rsync).
- **Trust-model changes ship with their disclosure or not at all.** #954's App Intents mint an in-process operator handle with no experiment gate — judged sound (user-initiated, OS-mediated, handle never leaves the process; the experiments gate the external socket) but merged only after the doc said so explicitly. The pattern: when a reviewer finds an implicit widening, the fix is a disclosed rationale in `docs/development/automation-api.md`, not necessarily a new gate.
- Mechanical residue: the `main` ruleset blocks squash-merge on unresolved review threads — address, reply, *resolve*, then merge. Transitory milestone tags (`[A1]`/`[A2]`) stay out of code comments and doc prose per the owner's #947 review; lane-history context belongs here, not in the tree.

### 2026-07-08 — [A1] evidence capture: 4 slices, one orchestrated day (#933/#941/#942/#943)

- **The exit criterion demonstrating itself caught the one bug that mattered.** #918's rule — the PR's evidence must be produced by the lane it ships — surfaced a blank 2744×1800 capture that every mechanical check had passed (file exists, dimensions sane, upload green, shellcheck clean, codex review clean). Only rendering the pixels revealed it; root cause was the desktop auto-locking between runs, the exact composited-path limitation the #915 spike had documented. The fix shipped as machinery, not advice: `evidence.sh` now retries until the PNG carries rendered content (luminance-spread gate) and fails with a clear error instead of uploading a blank — "never smoke-test a capture by size alone" lives in `docs/development/evidence.md` § content gate. Coordinator practice that found it: download and *look at* every evidence image before merging.
- **Facts-before-mechanism paid for itself in one wave.** The #915 spike (own-window capture is TCC-free; Ghostty presents via a readable IOSurfaceLayer) let #917 implement capture without a single mechanism debate, and its locked-screen finding pre-explained the #918 incident when it happened. Cost: one worker-session; the alternative was guessing across three slices. Residue is tracked, not vague: #944 holds the CGWindowList→ScreenCaptureKit migration with an explicit obsolescence trigger.
- **Injected-dispatch orchestration held up; idle-without-done was the one seam.** Four worker sessions (orca worktrees, injected lifecycle preambles) shipped four PRs with zero readiness failures (the #913 four-field template fix held) and one substantive review rejection total. The failure mode worth naming: a long #918 turn went idle without `worker_done` after heavy context use; a re-engagement prompt carrying the live taskId/dispatchId resumed it cleanly from uncommitted work. Encoded here rather than a skill edit: re-engage idle workers with their dispatch context before assuming failure — and workers on long tasks should commit incrementally.
- **Pre-existing flake, not this diff:** #933 was delayed ~40 min by `session-cookie.test.ts` failing twice; root-caused (tamper helper flips only base64url padding bits ~1/16 runs) and filed as #934 with the one-line fix rather than rerun-and-forget.

### 2026-07-07 — Triage of the un-milestoned backlog: one promotion, not many

- **49 of 86 open issues had no milestone; the triage was mostly confirming parking, not creating.** ~21 were already correctly `idea` (Orca cross-tile #838, web-next deferrals, terminal-UX children #523/#525–#529, the four `future` UI wishes). The value was separating those from the few real-and-loose items rather than milestoning the pile.
- **Only genuinely-next themes earn a milestone.** Of two coherent clusters — desktop breadth (#704/#679/#680) and the parallel-agent race (#836/#837) — only breadth was promoted to a milestone (`[D3]` #15), because the roadmap already named it the theme that follows the reliability/maintainability debt. The race cluster stays a roadmap theme + labels until it's actually next: milestones are execution contracts, not thematic buckets. Loose UI polish (#530/#654/#517/#518) and the selection bug #845 were deliberately left un-milestoned rather than manufacture a home.
- **Triage surfaced two live problems the milestone view hid:** #356 (CD playwright red on `main`, `needs-human`) and #776 (april-clearwater GitHub App near org-admin — standing security risk). Both are owner/human lanes, invisible in any product-milestone plan; a backlog sweep is where they surface.

### 2026-07-07 — Milestone grooming: six open milestones → two sequenced lanes

- **"Everything open" is the absence of a priority, not a priority.** Six milestones were live at once (#9–#14) while the execution policy said one at a time — the doc listed both surfaces as if maintainer attention were free. The grooming's highest-leverage output was naming the two-lane structure (desktop vs `web-next`) and declaring one active milestone *per lane*, which is the honest form of the single-active rule when the lanes genuinely don't share files or reviewer context. Owner chose true-parallel over collapsing to one bet.
- **A P0 nobody can reproduce for four months is a planning anchor, not a priority.** #554 (workspace-creation hang) had shipped diagnostics + watchdog + a regression net and still no live repro since March. Closed as not-reproducible — the instrumentation stays load-bearing, and the watchdog reopens it on real evidence. Kept the ungated hardening (#634/#635/#636) it spun off. Lesson: gate-blocked P0s should carry an explicit demote/close trigger, or they zombie the top band.
- **Craft aimed at users who don't exist yet is breadth wearing quality's clothes.** web-next is a single-user tool today, so owner-scoped sharing (#829) and assistive-tech/mobile a11y (#804/#809) only pay off with an audience it doesn't have. Parked #829 (`idea`, out of #14) and deferred those a11y items, while keeping contrast/keyboard/visible-failures (#805/#806/#808) — which help the owner. The quality principle cuts *toward* deferring these, not toward doing them.
- **The newer surface inherited the older surface's discipline unevenly.** Desktop performance is a contract; web-next, the surface meant to become *primary*, was flagged as having no perf budget. **(Correction, same day: it did have one — #761's `web-next/perf/` harness + hard CI gate; this grooming pass missed it, the third stale-issue catch of the session after #356/#864. #856 re-scoped to a regression-relative guard + deployed-target measurement.)** The lesson — verify against the tree before asserting a gap — landed on its own author.

### 2026-07-02 — Web cycle: plan → 3 waves of subagents → milestone #7 closed (PRs #723–#732)

- **Grounding the plan in code was worth more than the plan itself.** Of 9 "open" web items, 4 were already shipped (#535/#543/#545 fully, #522 moot) — the tracker-lags-code failure mode for the third consecutive planning pass. The cycle's first wave was closures, not code. Now a High-Signal Lesson in `AGENTS.md`: `rg` acceptance criteria against the tree before sequencing from open issues, and put `Closes #N` in every implementing PR so the drift never accumulates.
- **A specific brief beats a bigger model.** Six subagent PRs passed the quality gate first-try. The brief format that did it (grounded file:line facts marked *re-verify, don't trust*; hard constraints; exact verification commands; mutation checks for test PRs; honest-evidence rules; draft-only ship protocol) is now `.agents/skills/subagent-delegation/SKILL.md`. Notably, mid-tier models on tight briefs matched high-tier output — the "verify, don't trust" clause caught a wrong claim in the orchestrator's own brief (#725's import graph) before it became a wrong deletion.
- **Environment friction is a per-agent tax until it's a doc.** Every agent independently rediscovered the same three remote-container walls (no `EVIDENCE_UPLOAD_TOKEN`, no `mise`, Playwright browser pin mismatch) and paid tokens re-deriving the same workarounds. Fix: `docs/development/remote-sessions.md` (sanctioned conventions incl. green-CI-link evidence), `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` in `web/playwright.config.ts`, and #734 for the environment itself (human lane).
- **The four-layer review stack is redundant below a risk threshold.** Author verify + session gate + managed reviewer + CI each independently re-ran identical suites on docs-only PRs, while the layers earned their keep only on the risky ones (the gate caught a LEDGER merge conflict, a post-install flake, and did the visual + security passes CI can't). #733 (`idea`) anchors the calibration question — including whether the managed reviewer should spend its budget on review depth rather than suite re-runs.
- **Two tool-sharp edges:** legacy three-arg `git merge-tree` false-negatived a real conflict (use `--write-tree`); and a one-off test failure lost its identity because grep pipelines filtered the raw output before it was saved — capture to file first, filter second. Both are recorded in `remote-sessions.md` § session practices.

### 2026-06-28 — Backlog grooming pass (milestone #9, `idea`/`stale` labels)

- **A roadmap that lags the release log silently mis-sequences work.** The doc still read `v0.18.0` while `main` shipped `v0.22.0`, and the entire "next" reliability cluster (#634/#635/#636/#638, plus #626/#628/#615/#617/#616/#557) had already closed. Anyone planning from it would have re-opened finished work. The cheap guard is to diff the roadmap's "Now" issues against their live `state` before trusting the bands — the grooming's highest-leverage output was deleting stale *forward* claims, not adding new ones.
- **Two new labels do the de-noising that closing can't.** `stale` (tag for maintainer delete-review) and `idea` (speculative parking lot) turn "should this 3-month-old detailed spec be deleted?" from an irreversible call into a reviewable one. Crucially, both are reversible tags, not closures — which is what saved the next bullet.
- **Judge done/stale from the code, not the issue text — and a same-day milestone-#7 review proved why.** The first grooming pass tagged the 12-issue chat-tab/Chat-SDK epic `stale` from the March issue bodies, which described it as unbuilt. A follow-up "is this still valid?" review of milestone #7 read the actual `web/` tree and found the opposite: `bot.ts` (GitHub + Slack adapters), `api/chat/{messages,dispatch,agent-stream}`, the Discussion bridge, the Turso `webhook_events` store, the agent-discovery routes, and the dashboard **Chat tab** had all shipped. The `stale` tags were removed and the issues closed as *completed*; milestone #7 went 18→4 open. The lesson: a months-old issue's own framing is the least reliable signal for its status — `rg`/`ls` the implementation before tagging, and prefer reversible tags so a wrong call costs a label edit, not a reopen.
- **Re-ground every gate before promoting the issue behind it.** #549 (tmux multiplexing) was "blocked pending the Phase 8 ADR"; the ADR had landed (#693) weeks earlier, so the real state was *unblocked, needs re-scope*, not *blocked*. Walking the actual commit log beats trusting the issue's own stale framing.
- **File the gap the roadmap already names but never tracked.** Item 3a/3b had described the duplicate-bootstrap, three-error-pattern, and `GhosttySurfaceView` seams in prose for weeks with no issue numbers. Converting prose debt into #708/#710 (+ an archive-lifecycle test net #709 from the #663/#664 bug cluster) is what makes the maintainability lane executable by a cold session — the same lesson as the 2026-06-09 review, applied to its own leftovers.

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

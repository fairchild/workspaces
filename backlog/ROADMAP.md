---
status: in-progress
category: plan
pr: null
branch: null
score: null
retro_summary: null
completed: null
---

# AI Coding Workspace Manager — MVP Roadmap

**Vision**: A Mac-native app for managing AI coding sessions. Add repos, fork them into isolated workspaces, run any terminal-based coding agent in an embedded terminal, and track file changes—all without context-switching to Finder or a separate terminal.

## Status Snapshot (2026-03-10)

- Latest shipped release: `v0.1.2` (GitHub release + DMG workflow path healthy).
- Branch validation baseline: `swift test` is green at 270 tests across 45 suites.
- Daily-driver reliability fixes have landed:
  - shared non-blocking process execution (`ProcessRunner`) adopted across git/workspace/backend services
  - terminal identity hardening on workspace switch and restart generation
  - workspace recency ordering now updates on selection
- Open-in-editor hardening has landed on mainline:
  - deterministic launch guardrails for shortcut/UI-triggered editor handoff
  - launch metrics/signposts and smoke coverage for editor-launch reliability
- Tart GUI automation + editor handoff UX hardening landed in PR #19:
  - target-manifest-driven Tart harness/docs for repeatable automation runs
  - workspace editor toolbar/context attachment launch-path improvements
- URL sources + embedded webview MPP support is on mainline:
  - sidebar-managed URL sources with persisted metadata
  - embedded domain-scoped browsing alongside terminal-first routing
- Main-window/sidebar redesign and navigation hardening are now validated on the active branch:
  - repo overview is the primary repo destination
  - scoped web views can be global, repo-owned, or workspace-owned
  - sidebar chrome is flatter and calmer, with explicit repo sorting replacing the old `Recent` section
  - launch/selection state is hardened with per-window restore state and deterministic remote-workspace activation
- Refinement-gate closure work has landed on mainline:
  - Ghostty split shortcut parity (`resize_split`, `equalize_splits`)
  - product/release docs parity and release-script ergonomics hardening
  - main-window coordinator extraction plus inspector/right-pane regression coverage
  - workspace creation progress UX
  - strict-concurrency warning cleanup in the app layer
- Active implementation focus: maintainability-first quality work that keeps shrinking `ContentView`/`SidebarView`/Ghostty integration complexity now that the main-window redesign direction is validated.

---

## Current Locked Direction (2026-02-14)

For the VZ/Tahoe implementation track (`M2`-`M6`), `backlog/vz-tahoe-execution-brief-plan.md` is the source of truth.

Execution priority is:

1. Complete the **Refinement Gate (Before M2)** in this roadmap.
2. Resume the execution brief milestones starting at `M2`.

### Product Defaults

- App launch restores the last active repo overview, repo terminal, workspace terminal, or web view. If the saved surface is invalid, fallback is: most recent workspace, then most recent web view, then first repo overview.
- Sidebar top-level concepts are `Repositories` and `Web`.
- Sidebar clicks are explicit context actions:
  - Repo row opens the repo overview.
  - Expanded repo rows reveal repo-owned web views first, then workspaces.
  - Workspace rows open or resume persistent terminal sessions in those directories.
  - Web rows open embedded web views.
- Repository ordering is explicit and stable: `Alphabetical` by default, with `Last Accessed` only re-sorted on demand.
- Sidebar shows live session indicators for repos/workspaces with active terminals.

### VM Lifecycle Scope

- No VM creation or startup at app launch.
- VM creation/start is triggered when creating a new workspace configured for `vzLinuxTahoe`.
- Existing tracked workspaces remain `local` (no auto-migration).

### Backend + Platform Scope

- Native `Virtualization.framework` backend first (`vzLinuxTahoe`).
- VZ backend support target: macOS 26+ (Tahoe), Apple Silicon only.
- New workspaces default to VZ backend only on supported hosts; fallback remains local backend.

### Execution Routing Defaults

- VZ workspaces: run commands in VM by default.
- Host build/test routing in `auto` mode for:
  - `xcodebuild`
  - `swift build`
  - `swift test`
- Explicit overrides:
  - `--host` forces host execution.
  - `--vm` forces VM execution.

### Security Defaults

- Workspace mount in VM is RW virtiofs.
- Per-workspace vmnet logical network with NAT default.
- Outbound egress is unrestricted in phase 1.
- Any non-workspace extra mounts require an external allowlist outside the repo/workspace.

### Best Implementation Order

1. [x] Persistent terminal foundation and session UX.
2. [x] Refinement gate: quality hardening and performance baselining for current feature set.
3. [ ] Maintainability-first quality pass: continue shrinking oversized integration files and keep verification deterministic.
4. [ ] Backend abstraction/registry in core while preserving `LocalBackend`.
5. [ ] `VZTahoeBackend` implementation (runtime checks, VM lifecycle, vmnet, SSH executor, allowlist).
6. [ ] New-workspace flow integration to create/start VM only for VZ workspaces.
7. [ ] CLI backend-aware routing (`auto`, `--host`, `--vm`) plus VM lifecycle commands.
8. [ ] Tests, docs, fallback hardening, and validation.

### Performance Backlog (Fast-Path Follow-ups)

- [x] Add production signposts around launch, repo hydration, and repo-click-to-focus latency.
- [x] Run baseline captures and check in a short perf report (including documented `xctrace` limitations on local runs).
- [x] Add optional session/surface cap policy (LRU for inactive repo sessions) if memory pressure appears. (Decision: keep unbounded for now with guardrail logging + revisit threshold.)
- [ ] Re-introduce remote URL metadata in a background/idle pipeline (not launch-critical path).

---

## Refinement Gate (Before M2)

The next cycle prioritizes implementation quality for shipped behavior before expanding the feature set.

### Objectives

- Make session behavior deterministic under fast click-switching between repos and workspaces.
- Keep launch and interaction latency consistently fast on real `~/code` portfolios.
- Ensure release workflow reliability stays boring and repeatable.
- Align product docs and stories with the behavior users are actually testing.

### Exit Criteria

- [x] `swift test` remains green with added regression coverage for session focus and reuse semantics.
- [x] A short perf report is checked in with baseline numbers for:
  - launch-to-first-prompt
  - repo hydration
  - repo-click-to-focused-terminal
- [x] No known crash/repro defects remain around workspace selection and session switching on the validated branch.
- [x] Release workflow passes end-to-end from the mainline release flow (signed + notarized DMG published).
- [x] Product docs (`docs/product_overview.md`, `docs/user-stories.md`) reflect implemented UX.

### Planned Work Items

- [x] Add instrumentation signposts around launch, sidebar selection handling, and terminal focus handoff.
- [x] Add focused regression tests for session reuse + focus restoration behavior.
- [x] Add a lightweight memory guardrail decision: either cap inactive surfaces (LRU) or document why unbounded is acceptable today.
- [x] Land daily-driver reliability fixes: deadlock-safe process execution, terminal identity reset on workspace switch, and recency updates.
- [x] Complete Ghostty shortcut pass-through parity for split actions (`resize_split`, `equalize_splits`) and keep `mask verify-shortcuts` green.
- [x] Tighten release docs/scripts around Apple credential troubleshooting and idempotent setup (metadata consistency now fixed in workflow title/version flow).
- [x] Land main-window coordinator extraction, inspector/right-pane regression coverage, and workspace creation progress UX.
- [ ] Capture usage findings and feed them into post-refinement prioritization for M2.

---

## Completed Work

- **Phases 1-3 complete**: Three-column layout, SwiftData persistence, repo/workspace CRUD, file tree, git status pane
- **Phase 4 partial**: Keyboard shortcuts, signed + notarized DMG releases through `v0.1.2`, GitHub Actions CI
- **Terminal migration**: SwiftTerm replaced with GhosttyKit (`libghostty`) for persistent session support
- **Terminal-first repo/workspace UX**: Auto-discovery from `~/code`, repo overview as the primary repo surface, persistent repo/workspace terminals, and live session indicators
- **URL sources + embedded webview (MPP)**: persisted `WebSource` entries, embedded browsing with global/repo/workspace scope, and terminal/web selection coexistence
- **Session coordinator**: Manages terminal surface lifecycle, reuse, and focus restoration
- **Refinement/performance hardening (2026-02-15)**: Signposts, perf baseline report, session regression tests, and memory-policy guardrails (`backlog/done/refinement-performance-followup.md`)
- **Daily-driver reliability hardening (2026-02-26 to 2026-02-28)**: non-blocking process runner, terminal/workspace identity fixes, recency sort correctness, and release metadata consistency
- **Open-in-editor polish (PR #18 + follow-up fixes)**: deterministic launch guardrails, launch metrics/signposts, and strengthened shortcut smoke assertions
- **Editor UX + automation hardening (PR #19)**: external editor service/toolbar action hardening and Tart automation target-manifest/documentation upgrades
- **Refinement-gate closure (2026-03-07)**: split parity, docs/release parity, main-window/inspector hardening, workspace creation progress, and app-layer strict-concurrency cleanup
- **Main-window/sidebar redesign + navigation hardening (2026-03-10)**: repo overview launch flow, scoped web views, quieter sidebar hierarchy, repo sorting, per-window last-surface restore, and deterministic remote-workspace selection handling
- **270 tests** passing across 45 suites (services, models, session behavior, process runner, app-level routing/UX behaviors)
- **Monorepo extraction**: Clean standalone repo, SPM-only build (no Xcode project)

---

## Active Phase: Maintainability + Determinism

Prioritization lens for this phase (aligned with `README.md`):

1. Keep the product simple: one clear core workflow (select context, run terminal, inspect files/changes).
2. Improve quality before adding surface area: determinism, readability, testability, and memory behavior first.
3. Protect performance: prioritize changes that keep startup and interaction latency boringly consistent.

### Now (P0): Must Land Before New Feature Breadth

| Item | Effort | Impact | Why now |
|------|--------|--------|---------|
| Main-window/sidebar maintainability pass | Medium | High | `ContentView` and `SidebarView` are still the largest integration files and slow down safe iteration. |
| Ghostty boundary maintainability | Medium | High | `GhosttySurfaceView` and `GhosttyAppManager` remain the riskiest AppKit/C interop surfaces to modify. |
| Shared-desktop verification reliability | Medium | Medium | UI evidence capture is still the least deterministic quality loop and slows confident refactors. |
| Usage findings + post-refinement prioritization | Low | Medium | Needed to decide whether M2 starts next or more quality work should land first. |

### Next (P1): Core UX Evolution With Controlled Refactor Scope

| Item | Effort | Impact | Guardrail |
|------|--------|--------|-----------|
| Pane-tree terminal tiling model | High | High | Execute only with reducer-first design + invariant tests + memory sync contract. See `backlog/pane-tree-tiling_plan.md`. |
| Ghostty appearance hardening follow-up | Medium | Medium | Run after the current maintainability pass so appearance behavior is checked against the new seams. |
| Logging + error-surface cleanup | Low | Medium | Standardize `print`/`NSLog` usage and reduce ad hoc alert/reporting paths once large-file refactors settle. |

### Later (P2): Strategic Expansion

| Item | Effort | Impact | Note |
|------|--------|--------|------|
| VZ backend (M2-M6) | High | High | Strategic roadmap track; resume after P0 quality gate closes and P1 core UX risk is contained. |

### Icebox (P3): Optional/Context-Dependent

- **tmux per-worktree productization** (`backlog/tmux-support_plan.md`) — defer while choosing one primary multiplexing model (pane tree) to avoid dual-mode complexity.
- **Sparkle auto-update** (`backlog/sparkle-autoupdate-plan.md`) — defer until external user distribution pressure increases.
- **Landing page** (`backlog/landing-page.md`) — go-to-market asset; not on critical path for product quality.
- **Swift dev skills task-list** (`backlog/swift-dev-skills-task-list.md`) — internal workflow optimization, not user-facing product quality.
- **Session history** (persist scrollback) — non-trivial GhosttyKit scope.
- **File watching auto-refresh** — manual refresh currently sufficient.

### Dropped

Removed from roadmap (conflict with design principles or low value):

- ~~Git operations from UI~~ — design principle: "not a git client"
- ~~Search in files~~ — use terminal
- ~~Workspace templates~~ — `setup.sh` handles this

---

## Next Phase: VZ Backend

VM-backed workspaces via macOS 26 Virtualization.framework. See `backlog/vz-tahoe-execution-brief-plan.md` for the full execution plan (M2-M6).

Summary: backend abstraction/registry, VZTahoeBackend implementation (VM lifecycle, vmnet, SSH executor), workspace creation integration, CLI routing with `--host`/`--vm` flags.

---

## Backlog

| Item | Category | Priority Band | Pointer |
|------|----------|---------------|---------|
| Main-window + sidebar maintainability pass | Follow-up | P0 | `backlog/main-window-sidebar-maintainability_followup.md` |
| Pane-tree terminal tiling model | Plan | P1 | `backlog/pane-tree-tiling_plan.md` |
| Ghostty appearance hardening | Follow-up | P1 | `backlog/ghostty-appearance-hardening_followup.md` |
| Shared desktop focus contention hardening | Follow-up | P0 | `backlog/shared-desktop-focus-contention-followup.md` |
| VZ Tahoe execution brief | Plan | P2 | `backlog/vz-tahoe-execution-brief-plan.md` |
| Isolation strategy options (research) | Plan | P2 | `backlog/isolation-strategies.md` |
| tmux per-worktree support | Plan | P3 | `backlog/tmux-support_plan.md` |
| Sparkle auto-update decision record | Plan | P3 | `backlog/sparkle-autoupdate-plan.md` |
| Landing page | Plan | P3 | `backlog/landing-page.md` |
| Swift dev skills task-list | Task List | P3 | `backlog/swift-dev-skills-task-list.md` |

---

## Learnings

### 2026-03-10 — Main-window/sidebar redesign landed on active branch

**Context**: The Apple-native main-window redesign plan was executed together with deeper main-window state hardening and sidebar simplification.

**Results**:
- Repo overview is now the primary repo destination; workspaces and repo-owned web views are launched from there or from the calmer repo tree.
- The visible `Host` / `Recent` model is gone. Sidebar top-level concepts are now `Repositories` and `Web`.
- Scoped web views now support global, repo-owned, and workspace-owned ownership.
- Last-surface restoration is per-window, and remote workspace selection no longer commits visible state before attach succeeds.
- Repository ordering is explicit and stable with `Alphabetical` and on-demand `Last Accessed` modes.
- Validation on the branch is green at 270 tests across 45 suites, plus live debug-app launch/capture and `Cmd+B` / `Cmd+D` runtime checks.

**What this changes for planning**: The redesign itself is no longer the blocking priority. The remaining work is maintainability, Ghostty-boundary cleanup, and more deterministic shared-desktop verification.

### 2026-03-07 — Refinement gate closure + strict-concurrency cleanup

**Context**: The remaining refinement-gate items and follow-up cleanup work were merged to mainline.

**Results**:
- Ghostty split shortcut parity now covers `new_split`, `goto_split`, `resize_split`, and `equalize_splits`.
- Product docs, release docs, and release-script ergonomics now match shipped behavior.
- Main-window coordinator extraction, inspector/right-pane regression tests, and workspace-creation progress UX are landed.
- App-layer strict-concurrency warnings are cleaned up and `swift build -Xswiftc -warn-concurrency` is green.
- `swift test` is green at 185 tests across 29 suites.

**What this changes for planning**: The highest-value next work is maintainability-first quality improvement, especially shrinking oversized integration files and tightening the Ghostty/AppKit boundary before new feature breadth.

### 2026-03-07 — Main-window maintainability pass (in flight)

**Context**: The next quality branch continues the maintainability pass by reducing `ContentView`'s mixed state/orchestration surface instead of adding product scope.

**Results so far**:
- `ContentView` now uses a dedicated `MainWindowViewState` instead of a long list of top-level `@State` fields.
- Root-view presentation and selection-derived state moved into `MainWindowPresentationController`.
- Deep-link and UI-fixture bootstrap decisions moved into `MainWindowBootstrapController`.
- Focused controller tests were added, bringing `swift test` to 196 tests across 31 suites.

**What this changes for planning**: the next maintainability slice after this PR should continue Phase 2 only if a clearly separable root-view seam remains; otherwise move to the Ghostty boundary cleanup in Phase 3.

### 2026-03-01 — PR #18/#19 mainline hardening pass

**Context**: PR #18 and PR #19 were merged to mainline to harden open-in-editor behavior and strengthen GUI automation/editor handoff reliability.

**Results**:
- Open-in-editor routing now has deterministic guardrails for missing/invalid targets plus launch outcome metrics.
- Shortcut smoke coverage for open-in-editor is hardened (including fixture-home assertions).
- Tart GUI automation gained target-manifest workflow/docs updates and activation/verification flows.
- `swift test` is green at 142 tests across 23 suites.

**What this changed for planning at the time**: Open-in-editor shortcut polish moved out of quick wins; remaining refinement work centered on docs parity and split shortcut parity.

### 2026-02-28 — Release metadata consistency pass

**Context**: After cutting `v0.1.2`, release naming drifted because workflow title formatting depended on both plist version and tag.

**Results**:
- Updated workflow release name to derive from tag consistently.
- Bumped app bundle version metadata to match `v0.1.2`.
- Verified `swift test` remains green (97 tests) and remote mainline stayed in sync.

**What this changes for planning**: Release hardening is now mostly about documentation and credential/idempotency ergonomics, not core workflow correctness.

### 2026-02-26 — Daily-driver reliability hardening

**Context**: Daily use surfaced reliability gaps: process output deadlock risk, terminal/workspace mismatch on selection changes, and stale recency ordering.

**Results**:
- Added shared process runner with concurrent stdout/stderr draining and adopted it in core services.
- Hardened terminal identity lifecycle for workspace switches/restarts.
- Updated workspace selection flow to persist `lastAccessedAt` on selection for correct recency sorting.

**What worked**: Prioritizing correctness-first fixes before feature expansion improved day-to-day confidence without adding product complexity.

### 2026-01-30 — Documentation audit

**Context**: Reviewed project state to plan next work.

**Discovery**: The project is much further along than TASKS.md indicated. Tasks 1-9.5 were all implemented but documentation hadn't been updated:
- Three-column layout, SwiftData persistence, repo/workspace flows all working
- Right pane with file tree and git status complete
- Settings with configurable workspace location done
- 41 unit tests pass (GitService, WorkspaceService, Models)

**What worked**: Code review revealed actual state vs documented state.

**Remaining MVP work**:
- Task 11: Build & Distribution (requires Apple Developer account)
- Stretch items: file watching auto-refresh and multi-window workspace sessions

### 2026-02-08 — Build health validation (post-monorepo extraction)

**Context**: Validated standalone repo after extracting from services monorepo.

**Results**: Clean bill of health — debug build, release build, 52 tests, lint all pass. No monorepo remnants.

**Fixes applied**:
- Updated stale test counts (36 → 52) and task statuses (async migration, error handling already done)
- Fixed ARCHITECTURE.md doc path references
- Removed unused `NSColor(hex:)` extension
- Added release build to CI, `mask run` command
- Removed TASKS.md (GitHub issues is source of truth) and progress.md (stale, replaced by roadmap learnings)

**What worked**: Parallel exploration agents for fast codebase audit. The extraction was clean — zero issues blocking development.

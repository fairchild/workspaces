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

---

## Current Locked Direction (2026-02-14)

For the VZ/Tahoe implementation track (`M2`-`M6`), `backlog/vz-tahoe-execution-brief-plan.md` is the source of truth.

Execution priority is:

1. Complete the **Refinement Gate (Before M2)** in this roadmap.
2. Resume the execution brief milestones starting at `M2`.

### Product Defaults

- App launch opens a live host terminal in `~/code` by default (fallback to `$HOME/code`, then `$HOME`).
- Main terminal stays host-pinned by default.
- Sidebar clicks are explicit terminal actions:
  - Host Portfolio row returns to the default host session.
  - Repo/workspace rows open or resume persistent host sessions in those directories.
- Users can spawn additional regular host terminals from the host context.
- Sidebar shows live session indicators for repos with active terminals.

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

1. [x] Host-terminal-first foundation and persistent session UX.
2. [ ] Refinement gate: quality hardening and performance baselining for current feature set.
3. [ ] Backend abstraction/registry in core while preserving `LocalBackend`.
4. [ ] `VZTahoeBackend` implementation (runtime checks, VM lifecycle, vmnet, SSH executor, allowlist).
5. [ ] New-workspace flow integration to create/start VM only for VZ workspaces.
6. [ ] CLI backend-aware routing (`auto`, `--host`, `--vm`) plus VM lifecycle commands.
7. [ ] Tests, docs, fallback hardening, and validation.

### Performance Backlog (Fast-Path Follow-ups)

- [ ] Add production signposts around launch, repo hydration, and repo-click-to-focus latency.
- [ ] Run Instruments baselines (Time Profiler + SwiftUI + Hangs) and check in a short perf report.
- [ ] Add optional session/surface cap policy (LRU for inactive repo sessions) if memory pressure appears.
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

- [ ] `swift test` remains green with added regression coverage for session focus and reuse semantics.
- [ ] A short perf report is checked in with baseline numbers for:
  - launch-to-first-prompt
  - repo hydration
  - repo-click-to-focused-terminal
- [ ] No open crash/repro defects around workspace selection and session switching.
- [ ] Release workflow passes end-to-end from `main` (signed + notarized DMG published).
- [ ] Product docs (`docs/product_overview.md`, `docs/user-stories.md`) reflect implemented UX.

### Planned Work Items

- [ ] Add instrumentation signposts around launch, sidebar selection handling, and terminal focus handoff.
- [ ] Add focused regression tests for session reuse + focus restoration behavior.
- [ ] Add a lightweight memory guardrail decision: either cap inactive surfaces (LRU) or document why unbounded is acceptable today.
- [ ] Tighten release docs/scripts around Apple credential troubleshooting and idempotent setup.
- [ ] Capture usage findings and feed them into post-refinement prioritization for M2.

---

## Completed Work

- **Phases 1-3 complete**: Three-column layout, SwiftData persistence, repo/workspace CRUD, file tree, git status pane
- **Phase 4 partial**: Keyboard shortcuts, signed + notarized DMG release (v0.1.0), GitHub Actions CI
- **Terminal migration**: SwiftTerm replaced with GhosttyKit (`libghostty`) for persistent session support
- **Host-terminal-first UX**: Auto-discovery from `~/code`, persistent per-repo host sessions, live session indicators
- **Session coordinator**: Manages terminal surface lifecycle, reuse, and focus restoration
- **52 tests** passing (GitService, WorkspaceService, Models, session behavior)
- **Monorepo extraction**: Clean standalone repo, SPM-only build (no Xcode project)

---

## Active Phase: Polish & Daily Use

After the refinement gate completes, focus shifts to daily-driver quality and small high-value additions.

### Tier 1: Quick Wins

| Item | Effort | Impact | Notes |
|------|--------|--------|-------|
| Quick switcher (Cmd+P) | Low | High | Filtered overlay to jump repos/workspaces. Session coordinator has the data. |
| Auto-launch claude in workspace | Low | High | Option to run `claude` on workspace creation. The primary use case. |
| Workspace creation progress UI | Medium | Medium | Existing backlog item. Eliminates "frozen" feel on large repos. |

### Tier 2: Defer

These wait for VZ backend or until usage reveals the need:

- **Session history** (persist scrollback) — non-trivial GhosttyKit integration
- **File watching auto-refresh** — manual refresh works
- **Sparkle auto-update** — user base is one, defer
- **Multi-terminal split** — high effort

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

| Item | Category | Pointer |
|------|----------|---------|
| Isolation strategy options | Research | `backlog/isolation-strategies.md` |
| VZ Tahoe execution brief | Plan | `backlog/vz-tahoe-execution-brief-plan.md` |
| Refinement & performance follow-ups | Quality | `backlog/refinement-performance-followup.md` |

---

## Learnings

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

# Sidebar arrangement: Recent mode, pinning, manual pin order

> **Status: shipped in v0.25.0 (2026-08-23).** Slice 1 #1335, slice 2 #1339, slice 3 #1340;
> the coexisting launcher that produced the evidence is #1333. Deferred, with reasons
> on the PRs: drag reorder in Pinned (`.onMove`) pending a VM-desktop verification
> lane; repo-root pinning; a per-repo colour/monogram glyph. Kept as the record of the
> decisions below.

Handoff brief for a Fable session. Fable holds the arc and verifies; the
implementation is delegated per slice. Michael asked for this after reviewing
the design below (2026-08-22).

## Problem

The sidebar groups by repository only. The sort menu (`SidebarRepoSortMode`,
`Sources/WorkspaceManager/Views/MainWindow/SidebarRepoSortController.swift`)
orders *repos* alphabetically or by last access; workspaces inside a repo are
always recency-sorted (`SidebarView.swift` `sortedWorkspaces(for:)`).

Michael's real store: 51 repos, 21 active workspaces across 8 of them, 1 repo
with a web source. 4 workspaces touched today, 5 in the last week, then a
cliff back to July. The sidebar is 43 empty folders between him and the five
things he's working on.

## Decisions (made — do not re-litigate)

- **Three slices, three stacked PRs**, in order: Recent arrangement → pinning
  → manual pin order. Each lands independently; each is valuable alone.
- **Recent is a third radio item in the existing menu**, not a separate
  "group by" submenu. The enum gains a case; the stored raw value stays
  backward compatible (unknown raw → alphabetical already).
- **Recent is flat**: active workspaces plus repo roots that have open panes,
  under native `Section` headers **Today / This Week / Earlier**. Archived
  workspaces do not appear. Empty repos do not appear. No web-source nesting
  in Recent (they stay reachable via the Web section and breadcrumb).
- **Date source is `lastAccessedAt`** (bumped on selection), not agent
  `lastEventAt`. The activity dot already shows live agents.
- **Ordering is snapshot-stable**, same technique as the existing
  `lastAccessed` repo sort: refresh the snapshot on mode change, on appear,
  on workspace create/delete, and on **app-resigned-active**
  (`NSApplication.didResignActiveNotification` — not become-active: the
  mouse-down that reactivates the window clicks through to a row, so a
  refresh on activation would move the clicked row; codex review, slice 1).
  Never reorder live under the
  cursor.
- **Repo identity in a flat row is text**: `repo / workspace` on one line,
  repo portion in secondary color, mirroring the toolbar breadcrumb. Truncate
  the repo half first. No two-line rows. No favicon (no repo-icon concept
  exists; 1 of 51 repos has a web-source favicon; GitHub owner avatars would
  all be identical). A deterministic per-repo color/monogram glyph is a
  *possible* later refinement, not part of this arc.
- **Pinning is workspace-scoped** (`Workspace.pinOrder: Int?`, nil =
  unpinned; renumber 0…n on reorder). Lightweight SwiftData migration —
  precedent: `archivedAt` (#661), `defaultAgentCommand`. Repo-root pinning
  is a follow-up, not in scope.
- **Pinned section sits at the top in every arrangement.** "Pinned is a
  shortcut list, not a move": in Recent mode the flat list below excludes
  pinned rows; in the repo-grouped modes the workspace also stays in its
  tree (both rows highlight when selected — accepted, same as Finder
  Favorites).
- **Pin affordance**: hover-visible star on the workspace row (the
  `RepoRow` hover "+" pattern in `SidebarRows.swift`; `Sources/AGENTS.md`
  "quiet discoverability") plus Pin / Unpin in the context menu.
- **Manual order**: context-menu **Move Up / Move Down** is the reliable
  path and ships regardless; `.onMove` drag-reorder inside the Pinned
  `ForEach` is attempted on top and kept only if it works with the
  `.plain`-Button rows in a `.sidebar` list. Prototype that before
  committing to it.

## Slice 1 — Recent arrangement

Branch `leftsort/recent-arrangement` (from `origin/main`). PR title:
`feat(sidebar): Recent arrangement — flat, date-bucketed workspace list`.

Build:

1. Rename/extend `SidebarRepoSortMode` → add `case recent` with title
   `"Recent"`. Keep `storageKey`. Leave the existing two cases' behavior
   untouched.
2. A pure, testable arrangement function beside the existing controller
   (same file or a sibling `SidebarRecentArrangement.swift`):
   `recentBuckets(repos:, snapshot:, now:, calendar:) -> [RecentBucket]`
   where a `RecentBucket` has a `title` (Today / This Week / Earlier) and
   ordered `[RecentRow]`; a `RecentRow` is `.workspace(Workspace)` or
   `.repoRoot(Repo)` (repo included only when its root has open panes —
   pass pane counts in, don't read UI state from Core). Rows within a
   bucket sort by snapshot date desc, then name. Empty buckets are omitted.
   "This Week" = within the last 7 days and not today (calendar-local days).
3. `SidebarView`: when mode is `.recent`, `sidebarList` renders the buckets
   as `Section`s instead of `repositoriesSection`. Reuse `WorkspaceRow`
   with a new optional `repoContext: String?` (or similar) that renders the
   `repo / ` prefix in secondary style; `isNested: false`. Repo-root rows
   reuse `RepoRow` with expansion disabled (no children in Recent). Selection,
   context menus, hover cards, activity dots, pane badges all keep working —
   route through the same `workspaceRow(_:)` / `repoListRow(_:)` helpers or
   shared builders, don't fork the context menus.
4. Snapshot: extend the existing snapshot mechanism to cover workspace
   `lastAccessedAt` (a `[UUID: Date]` keyed by workspace and repo IDs is
   fine). Refresh triggers as in Decisions. `onChange(of: repos.map(\.id))`
   already exists; add a workspace-ID-set change trigger and the
   did-become-active observer.
5. Keyboard: ←/→ handlers (`handleSidebarLeftArrow/RightArrow`) must not
   misbehave in Recent (no tree to collapse) — return `.ignored`.
6. `handleNewWorkspaceShortcut` and the toolbar "+" menu still work in Recent
   (they don't depend on the repo tree).

Tests (`Tests/WorkspaceManagerAppTests/`, Swift Testing, mirror
`SidebarRepoSortControllerTests`): bucket assignment at day boundaries
(23:59 today vs 00:01 yesterday → This Week), 7-day edge, archived excluded,
repo root included only with panes, pinned-free ordering stable given a fixed
snapshot, empty buckets omitted, unknown stored raw value still → alphabetical.

Evidence (required before the PR): add fixture scenario `sidebar-recent` —
`scripts/lib/fixture-scenarios.sh` + `scripts/lib/app-capture.sh` env
plumbing + the names list — that launches with the Recent arrangement active
via a fixture-mode env override (e.g. `WORKSPACES_UI_FIXTURE_SIDEBAR_ARRANGEMENT=recent`,
read only in fixture mode, overriding the stored mode) and seeds
`UIFixtureSeeder` workspaces with spread `lastAccessedAt` values (now,
−3 days, −30 days) so all three buckets render. Capture with
`./scripts/evidence.sh --pr <N> --fixture sidebar-recent`; also capture
`--fixture phase-1-release` to show the repo-grouped modes are unchanged.

## Slice 2 — Pinning

Branch `leftsort/pinning` from `leftsort/recent-arrangement`; PR base is that
branch, retargeted to `main` after PR 1 merges.

Build: `Workspace.pinOrder: Int?`; `isPinned` computed. A `SidebarPinController`
(pure, tested) with `pin(_:)`, `unpin(_:)`, `pinnedWorkspaces(in:)` that
renumbers 0…n. A **Pinned** `Section` rendered first in all three modes when
non-empty, rows via `workspaceRow` with `repoContext` set. Recent mode's
buckets exclude pinned workspaces; repo modes leave them in the tree. Hover
star on `WorkspaceRow` (visible on hover, filled when pinned; pinned rows in
the Pinned section show the star only on hover), context-menu Pin/Unpin.
Persist via the model context (`saveModelContext(action:)`). Deleting or
archiving a pinned workspace unpins it (archive = unpin so the Pinned section
never shows an archived row).

Tests: renumbering, unpin-on-archive, Pinned excluded from Recent buckets,
stored `pinOrder` survives a round trip in an in-memory `ModelContainer`.

Evidence: fixture scenario `sidebar-pinned` (env
`WORKSPACES_UI_FIXTURE_PINNED=feature-auth,skills-v13`) captured in Recent
and in Alphabetical.

## Slice 3 — Manual pin order

Branch `leftsort/pin-reorder` from `leftsort/pinning`.

Build: context-menu Move Up / Move Down (disabled at the ends) via the pin
controller's `move(_:, by:)`; then attempt `.onMove` on the Pinned `ForEach`.
Keep drag only if it works reliably with the existing row buttons; if it
fights the `.plain` Button rows, drop it and say so in the PR.

Tests: move at boundaries is a no-op, order persists.

Evidence: fixture capture of a reordered Pinned section, plus a short
recording of the drag (or of Move Up/Down) — the fable-session contract asks
for a demonstrated run where there's a UI.

## Gates (every PR)

`swift test`, `mise run lint` (swift-format strict — CI fails without it),
evidence uploaded via `scripts/evidence.sh` with URLs in the PR body,
`## Mergeability` section with the four labeled fields
(`docs/development/mergeability-standard.md`), label `author:claude-code`,
`codex-review-loop` before flipping ready. Do not touch `Package.swift`.
Never `rm -rf` build state.

## Who does what

- **Fable (this session)** — owns the arc: writes/keeps this brief, dispatches
  each slice, independently re-runs tests + lint, reads the diff, captures
  or checks the evidence, runs the codex review loop, opens the PR, flips
  ready. A worker's claim is not evidence.
- **Opus** — implements slices 1–3 (Swift UI + Core + tests + fixture
  plumbing). One worker per slice, sequential, in this worktree
  (`/Users/fairchild/workspaces/workspaces/leftsort`).
- **Sonnet** — only for fully mechanical follow-ups (e.g. PR-body formatting,
  retargeting stacked PRs).
- **Michael** — merges. Authority contract: Fable reviews and flips ready;
  Michael merges; stacked PRs retarget to `main` as their base merges.

## Done

Per slice: a commit on its branch, green `swift test` + lint re-run by Fable,
uploaded evidence, an open PR. Arc done when PR 3 is open and all three
evidence sets show the rendered result.

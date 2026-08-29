# Design refresh: sidebar + navigation styling

> **Status 2026-08-29 (post-repair): two PRs remain — #1426 (slices 2+3:
> repo identity + worktree rows, rebased on main, April's duplicate-add-menu
> fix in) then #1434 (slices 4+5: active card + search row; retarget to main
> before merging #1426). Merged: #1424 (tokens, on main), #1430 (folded into
> #1426), #1436 (folded into #1434).** Checkable test: #1426 and #1434 are
> the only open implementation PRs and both are conflict-free against their
> bases.
> Follow-ups filed from the arc: #1425 (File-menu add commands), #1427
> (operator-scope capture lane vs running installed app), #1429
> (release-screenshot fixture-env forwarding), #1433 (durable session start
> date for the elapsed label).
> Dispatched 2026-08-28 at Michael's direction from a reference screenshot
> (`design-inspiration-sidebar.png`, an Orca sidebar). Inspiration, not cloning:
> adopt the structure and restraint; keep WorkSpaces' own identity.

Fable session owns the arc; implementation is delegated per slice. Michael's
review gates merge, not progress — slices proceed in sequence unless his review
redirects.

## What the reference shows

A near-black sidebar with: a search row; muted icon+label nav rows with a count
badge; a "Projects" header with inline actions; repo groups as a small colored
glyph + bold name; a collapsed "15 hidden worktrees" pill (count + chevron);
worktree rows as branch glyph + name with an outlined "primary" badge on main;
and the active row as a raised rounded card carrying a live session status line
(status glyph, orange spark, truncated session name, ⏱ 57:32 elapsed, 5d age,
trailing doc icon). Rounded cards, subtle 1px borders, generous spacing, one
accent per element class.

## Identity guardrails (adopt vs. keep)

**Adopt**: the restraint (muted chrome, one accent per element class), the
raised-card active row, per-repo colored identity glyphs, branch-glyph worktree
rows, pill-style progressive disclosure, header-inline section actions, a live
status line on the active session.

**Keep WorkSpaces' own**: adaptive light/dark via semantic colors (the
reference is dark-only; we follow the system — every token below resolves in
both appearances), SF semantic type styles (no custom font), provider
iconography where it carries meaning (Lume/Daytona), quiet hover-revealed
actions (`Sources/AGENTS.md` § UI Design Lessons), and the existing Tone
ladder as the single source of status color. No invented nav destinations:
Orca's Tasks/Automations rows have no WorkSpaces analog and get none.

## Current state (inventory, verified 2026-08-28)

- Sidebar: `ContentView` → `NavigationSplitView` → `SidebarView`
  (`Sources/WorkspaceManager/Views/MainWindow/SidebarView.swift`); sections
  Pinned → Repositories/Recent → Web → footer count bar. No search field
  (Cmd-P switcher only). Headers are plain `Text` + a sort menu on the topmost
  header.
- Rows in `SidebarRows.swift`: `RepoRow` (folder glyph, name, activity dot,
  count/pane capsules, hover "+"), `WorkspaceRow` (provider icon, name, status
  badge, dot, pane badge; second line = transient status or note; hover pin
  star). Selection = `Color.accentColor.opacity(0.1)`, radius 5.
- No branch glyphs, no primary/main labeling (`workspace.gitBranch` renders
  only in the hover card), no elapsed timers anywhere in the sidebar, no
  per-repo glyph (deferred by the sidebar-arrangement arc as a "possible later
  refinement" — this arc is that refinement).
- Archived worktrees hide behind a per-repo `Archived (n)` text header
  (`SidebarView.swift:907-927`) — the native analog of the hidden-worktrees
  pill.
- **No theme/token layer exists.** Zero named color sets; all color is
  semantic SwiftUI or `Color(nsColor:)` bridges plus the `Tone → Color` map in
  `Views/Components/AgentChromeProjectionStyle.swift`. Per-file metric enums
  only (`SidebarTreeMetrics`).
- Status plumbing (post #1353/#1354): 150ms coalesced ingest
  (`AgentHookListener`), per-session `@Observable AgentSessionStatusModel`
  with a render-equivalence publication gate (`AgentSessionRegistry`), rows
  fed via the `agentStatus: (UUID) -> AgentSessionStatus?` closure seam and
  the equality-gated `WorkspaceStatusAggregator`.

## Element-by-element mapping

| # | Reference element | Current | Proposed | Perf constraint |
|---|---|---|---|---|
| 1 | Restrained tokenized chrome | none (ad-hoc semantic colors, per-file metrics) | `SidebarChrome` token enum: fills, strokes, radii, paddings, type roles; adopted by all sidebar surfaces | Pure constants; no new observation. Behavior-neutral by intent |
| 2 | Bold repo name + colored glyph | `folder`/`folder.fill`, weight varies by selection | Deterministic per-repo hue on a small rounded-square glyph (monogram initial), name `.semibold` always | Hue derived from stable repo identity, computed in init from passed values — no new closures into rows |
| 3 | "Projects" header + inline actions | plain `Text` header; add-menu lives in the toolbar | Restyled muted header with inline trailing actions: existing sort menu + the Add Repository / Add URL Source menu (echoed from toolbar; survives `minimalToolbar`) | Static chrome |
| 4 | "15 hidden worktrees" pill | `Archived (n)` text header + chevron | Pill row: count capsule + "archived worktrees" + trailing chevron, same expansion state | Static chrome; same state variables |
| 5 | Branch glyph worktree rows | provider icon (`terminal`/`cloud`/`desktopcomputer`) | Local/host worktrees get `arrow.triangle.branch`; Lume/Daytona keep their provider icons (meaningful, unlike the reference's uniform glyph) | Value passed in, as today |
| 6 | Outlined "primary" badge on main | none; no default-branch concept in Sources | **Deferred.** The repo row *is* the primary checkout — a badge would restate the group header. Revisit only if repo-root branch rows ever exist | — |
| 7 | Active row = raised card | flat `accentColor.opacity(0.1)` fill radius 5 | Selected workspace row becomes a raised card: elevated fill + 1px hairline stroke, radius 8, both lines inside | Selection-driven only; invalidates on selection change, as today |
| 8 | Live status line on active card | second line = transient action message or note | On the selected row with a live session: tone glyph + agent-kind glyph (orange sparkles for Claude) + `AgentChromeProjection` summary + ⏱ elapsed + age. Note/transient messages keep priority rules | Summary/tone ride the existing closure seam (150ms coalesced, render-gated). **Timer is the sensitive part — see below** |
| 9 | Count badge on nav ("Agents 4") | `NeedsYouToolbarPill` in the toolbar | Keep the toolbar pill as the attention surface; no duplicate sidebar badge | — |
| 10 | Search row | none; Cmd-P switcher | Sidebar-top search-styled row that opens the session switcher (shows ⌘P hint); no new search engine | Static chrome |

## The timer (element 8) — perf design, named explicitly

Sidebar row re-evaluation was 86% of app CPU before #1353/#1354. The rules
this element must obey:

- **One timer per sidebar, not per row**: the tick mounts only on the selected
  row while its session is live — exactly the reference's behavior (only the
  active card shows 57:32).
- **Leaf-scoped invalidation**: a dedicated leaf view owning
  `TimelineView(.periodic(from:by:))` (or an equivalent row-scoped clock), so
  tick invalidation terminates at the leaf and never touches
  `SidebarView.body`. Acceptance: the
  `[Perf] event=main_window_body_evaluations` counter
  (`Diagnostics/PerformanceSignposts.swift`) stays flat while the timer ticks.
- **Read unobserved truth**: `AgentSessionRegistry.statuses` deliberately
  excludes `lastEventAt` from its publication gate
  (`AgentSessionRegistry.swift:259-264`), so the observed path is stale by
  design. The leaf reads `status(for:)` (unobserved) on its own clock;
  elapsed = now − `status.createdAt`, age from the workspace record.
- **No new whole-sidebar subscriptions**: summary text and tone already
  arrive via the `agentStatus` closure inside the coalesced window; this arc
  adds zero new `@EnvironmentObject`/Observation dependencies at
  `SidebarView` level.

**Coordination with #1366 (open, `ready`, separate lane)**: that issue wraps
rows in `Equatable` containers so one session's change redraws one row. This
arc must not duplicate it, and must not make it harder: slices pass resolved
*values* into rows wherever possible and add no new captured closures to row
initializers. Expect rebase friction on `SidebarRows.swift` whichever lane
lands second; the design slices keep row-struct inputs enumerable so the
eventual `Equatable` fingerprint stays writable.

## Slices (stacked PRs, in order)

Branches stack (each from the previous) because they share `SidebarRows.swift`
/ `SidebarView.swift`; retarget each PR to `main` before its base merges
(stacked-PR auto-close gotcha). Conventional commits; PR-only, Michael merges.

### Slice 1 — `design/tokens` — feat(design): sidebar chrome tokens

Introduce `Sources/WorkspaceManager/Views/Components/SidebarChrome.swift`: the
token layer the app never had, scoped to sidebar chrome (not a speculative
app-wide system). Codify the vocabulary already in use — fills (row selection,
chip, badge capsule), strokes (hairline `separatorColor` bridges), radii
(row/chip/card), paddings/indents (the 2/4/8/18/24/28/42 family), type roles
(title, secondary, badge `.monospacedDigit`), muted-foreground opacities — all
resolving through semantic colors so light/dark keep working. Migrate
`SidebarRows.swift`, `SidebarView.swift` headers/footer, `SidebarInfoCard.swift`
onto tokens. Visual delta ≈ zero (any intentional normalization, e.g. radius
5→6 unification, listed in the PR body with before/after).

Tests: existing render tests keep passing; their PNGs are the before/after
evidence. Evidence: `--fixture phase-1-release` + `--fixture sidebar-pinned`
before/after pairs.

### Slice 2 — `design/repo-identity` — feat(sidebar): repo identity glyphs + section headers

Per-repo deterministic colored glyph (small rounded square, monogram initial,
hue hashed from stable repo identity; muted saturation consistent with the
Tone ladder — one accent per element class), repo names `.semibold` always
(selection/activity no longer changes weight), restyled muted section headers
with inline trailing actions (sort menu + add menu). Activity stays on the
dot, not the glyph.

Tests: glyph hue determinism (pure function), header action wiring; new
`SidebarRepoRowRenderTests` (light + dark variants). Evidence:
`--fixture phase-1-release` capture; render PNGs.

### Slice 3 — `design/worktree-rows` — feat(sidebar): branch-glyph rows + archived pill

Branch glyph for local/host worktree rows (providers keep theirs), status-badge
and count-capsule restyle onto tokens, `Archived (n)` header becomes the
count-pill disclosure row (same expansion state, keyboard behavior unchanged).

Tests: extend `SidebarPinnedRowRenderTests`/`SidebarRecentRowRenderTests`
expectations; new archived-pill render test. Evidence: fixture captures of an
expanded repo with archived rows (extend a fixture scenario if none stages
archived workspaces — check `scripts/lib/fixture-scenarios.sh` first).

### Slice 4 — `design/active-card` — feat(sidebar): active session card + live status line

The flagship slice. Selected workspace row becomes the raised card (elevated
semantic fill, hairline stroke, radius 8); second line becomes the live status
line per element 8, with the timer built exactly per the perf design above.
Transient action messages ("Connecting…") and notes keep their current
priority over the status line.

Tests: render tests for the card (live, awaiting-input, errored; light+dark);
timer leaf unit-tested as a pure elapsed-formatting function
(mm:ss / h:mm:ss). Perf evidence in the PR body: `main_window_body_evaluations`
count flat over ≥60s with a ticking timer under `phase-1-release` fixture
states, plus the standard captures.

### Slice 5 — `design/search-row` — feat(sidebar): search row + polish pass

Search-styled row at sidebar top opening the session switcher (⌘P hint),
footer bar restyle onto tokens, final spacing sweep. Smallest slice, easily
dropped or reshaped if Michael's review redirects.

Tests: switcher-invocation wiring; render test. Evidence: capture + a short
recording of the row opening the switcher.

## Gates (every PR)

`swift test` (full suite), `mise run lint` (swift-format strict), evidence
uploaded via `scripts/evidence.sh` with URLs in the body **before** PR
creation, `## Mergeability` section with the four labeled fields
(`docs/development/mergeability-standard.md`), label `author:claude-code`,
`codex-review-loop` before flipping ready. Don't touch `Package.swift`. Never
`rm -rf` build state.

## Who does what

- **Fable (this session)** — owns the arc and the design coherence: dispatches
  each slice, independently re-runs tests + lint, reads the diff, captures or
  verifies evidence, runs the codex review loop, opens the PR, flips ready. A
  worker's claim is not evidence.
- **Opus workers** — implement slices 1–5, one at a time, guided by the
  `macos-development` and `swiftui-expert` skills, in this worktree
  (`workspace/design-refresh` stack).
- **Michael** — reviews and merges. His review gates merge, not progress;
  slices proceed in sequence unless a review redirects.

## Done

Per slice: green `swift test` + lint re-run by Fable, uploaded evidence
showing the rendered result (light and dark for row-visual slices), an open
PR. Arc done when slice 5's PR is open, every PR carries before/after
captures, and the perf evidence for slice 4 shows the timer riding a
row-scoped clock.

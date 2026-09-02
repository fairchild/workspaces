# Sidebar row equality, and the closures that outlive it

Sidebar rows sit behind `SidebarEquatableRow`, which compares on a display-state value and skips
the closure that builds the row when that value is unchanged (#1366). A skipped row keeps the
closures it was built with — its buttons, its context menu, and its hover card's `tabsProvider`
all still point at the render they were born in. This is the account of what each of those
closures reads, and why reading it late is safe.

This is the hazard #1347 deliberately deferred the slice over. It is not a thing to assume.

## The rule

A closure captures `self`, and `SidebarView` is a struct, so every plain `let` on it is captured
**by value** and can go stale. Everything else on it is a box or a reference and reads live:

| On `SidebarView` | Reads |
|---|---|
| `@State`, `@Binding`, `@FocusState` | Live — the wrapper holds a reference to storage the view does not own |
| `@Environment`, `@EnvironmentObject` | Live — same, plus the environment value is itself a reference here |
| `let` closures from `ContentView` | Live — each closes over `tileTreeStore`, `agentSessionRegistry`, `selectionController` or ContentView's own `@State`, all reference-typed |
| plain `let` values | **Stale unless fingerprinted** |

So the whole hazard reduces to `SidebarView`'s plain `let` inputs: `repos`, `webSources`,
`selectedRepo`, `paneCountBySessionKey`, `activeSessionKey`, `hostSessions`, and
`connectingWorkspaceID`. Every one of them has to reach a row's display state, or be shown not to
matter to that row.

## Repo rows

| Closure | What it reads that could be stale | Disposition |
|---|---|---|
| `onToggleExpansion` | `expansionController` | Live (`@State` box) |
| `onSelectRepo` → `selectRepo` | `paneCount(for:)` over `paneCountBySessionKey`, which decides whether the click opens the terminal or the overview | **Fingerprinted** — `paneCount` is in `RepoRowDisplayState` |
| `onSelectRepo` → `selectRepo` | `sidebarHasKeyFocus`, `expansionController` | Live (boxes) |
| `onSelectRepo` → `selectRepo` | `onRepoSelected` / `onRepoTerminalSelected` | Live — both reach `MainWindowSelectionController` through a stored reference |
| `onNewWorkspace` | `prepareNewWorkspaceSheet` writes `@State` and reads the `@Environment` provider registry | Live |
| `onNewWebView` | `onRequestWebSourceCreation` writes `ContentView` `@State` | Live |
| `tabsProvider` | the row's `SidebarRowSessionState` — its sessions, their statuses, their resolved foreground names and transcript tails | **Fingerprinted** — it *is* the value the row compares on |
| `tabsProvider` | `titleForSession` | Live — reads `TileTreeStore` (a `final class`) for the override and the surface title |
| menu · Open Terminal | `onRepoTerminalSelected` | Live |
| menu · New Workspace… `.disabled` | `isCreatingWorkspace(for:)` | **Fingerprinted** — `isCreatingWorkspace` is in the state (and the underlying `@State` is live besides) |
| menu · New Web Session `.disabled` | `webNextSessionSlug(repo)` over `repo.remoteURL` | Live (`repo` is a `@Model` class); also **fingerprinted** by `remoteURL` |
| menu · Reveal in Finder | `repo.localPath` | Live (class) |
| menu · Remove from List | `modelContext` | Live (`@Environment`) |

## Workspace rows

| Closure | What it reads that could be stale | Disposition |
|---|---|---|
| `onToggleExpansion`, `onSelect` | `expansionController`, `sidebarHasKeyFocus`, the two selection `@Binding`s | Live (boxes) |
| `onTogglePin` → `togglePin`, menu · Move Up / Move Down | `allWorkspaces`, derived from the captured `repos`. `pin` reads `max(pinOrder)` across it, and every mutation ends in `renumber`, which rewrites `pinOrder` over the whole pinned set | **Fingerprinted** by `pinGraphRevision` — see "The peer graph" below. `pinnedIndex` and `pinnedCount` are not enough on their own |
| menu · Move Up / Move Down `.disabled` | used to rebuild the Pinned ordering from the captured list on every open | **Fingerprinted and retired** — `canMovePinUp` / `canMovePinDown` read `pinnedIndex` and `pinnedCount` off the row's own state, which also removes a sort from the menu path |
| menu · Reveal in Finder gate | `usesHostWorkspaceFiles` over the `@Environment` registry and `workspace.backendIdentifier` | Live; also **fingerprinted** by `backendIdentifier` |
| menu · Pin / Unpin | `isPinnable`, `isPinned` | **Fingerprinted** |
| menu · Add/Edit/Clear Note | `workspace.note` | Live (class); also **fingerprinted** by `note` |
| menu · Archive/Start/Stop/Open Desktop | `workspace.status` (class) and the `@Environment` registry | Live; also **fingerprinted** by `status` |
| menu · New Web Session | `workspace.sourceRepo?.remoteURL` | Live (classes); also **fingerprinted** by `repoRemoteURL` |
| menu · Delete Workspace | `@State` | Live |
| `tabsProvider` | as for repo rows | **Fingerprinted** / live |

## Web-source rows and the archived pill

| Closure | Disposition |
|---|---|
| `onWebSourceSelected` | Live — writes `ContentView` `@State` |
| `openWebSourceExternally`, `removeWebSource` | Live — `source` is a class, `modelContext` is `@Environment` |
| `WebSourceFaviconView` | Live on its own — holds the image in `@State` and reloads on `.task(id: source.baseURLString)` |
| `ArchivedDisclosureRow.onToggle` | Live — writes the `expandedArchivedRepoIDs` `@State` |

## Object identity, and why selection is the exception

`MainWindowOrderCache` fingerprints `ObjectIdentifier` because SwiftData can hand back a
replacement instance carrying identical values — the hole review found in #1354's
`SidebarRepoSortCache`. The same threat reaches rows, for the same reason: a row keyed on the
model's `id` plus the values it draws would compare **equal** across that swap, skip its body, and
go on handing the *superseded* object to every closure it kept.

So `RepoRowDisplayState`, `WorkspaceRowDisplayState`, and `WebSourceRowDisplayState` each carry
`identity: ObjectIdentifier`. The closures it protects are the ones that dereference the object
for something other than its id:

| Closure | What it does with the captured object |
|---|---|
| `setNote(_:on:)` | writes `workspace.note` and saves — on a superseded instance the write is lost |
| `togglePin` / `movePin` | write `pinOrder` |
| `deleteWorkspace`, `removeRepo`, `removeWebSource` | delete *that* instance |
| `NSWorkspace.selectFile(workspace.path)`, `repo.localPath` | read a path off it |
| `markRepoAccessed(repo)`, via `selectRepo` | writes `lastAccessedAt` |

**Selection is the one path that would have been safe without the fingerprint**, and it is worth
naming because it shows the general shape of the defence. `selectWorkspace` reaches
`setSelectedWorkspace`, which stores a `MainWindowWorkspaceSelection` — a `UUID`, not the object
(`MainWindowViewState.swift:4`) — and every read comes back through `cachedWorkspace(with:)`
against the live index (`MainSelectionCoordinator.swift:62`). A superseded object handed to it is
reduced to its id and re-resolved. That is exactly the invariant `Sources/AGENTS.md` states as
*"persist selection state by stable IDs, not live SwiftData objects; resolve models late and
validate them against current data before selection"*. The mutations have no such boundary, so
they get the fingerprint instead.

`ArchivedDisclosureDisplayState` deliberately carries no identity: its only closure is
`toggleArchivedSection(for:)`, which reads `repo.id`, and the state already carries `repoID`.

The fingerprint is close to free, measured rather than assumed: with it the sidebar builds **2.73
rows/second** under the standard load against **2.75** without, inside run-to-run noise. That is
the same observation from the other side, and worth recording — SwiftData is *not* churning
instances during steady-state agent churn, so this is cheap insurance against a rare event rather
than a cost on the hot path.

## The peer graph

Per-row identity closes the hazard for the object a closure *is handed*. It does not close it for
the objects a closure goes on to *walk*, and the pin verbs walk the whole workspace list:
`SidebarPinController.pin` reads `max(pinOrder)` across it, and every mutation — pin, unpin, move,
and the rollback on a failed save — ends in `renumber`, which rewrites `pinOrder` over the pinned
set.

So when SwiftData replaces a **peer** with an equal-valued instance, a row keyed on its own
workspace plus `pinnedIndex`/`pinnedCount` compares equal: the ordering reads identically, the
index and count are unchanged, and the row's own object was never touched. The row skips, keeps
its `togglePin` closure over the superseded array, and the next Pin or Move Up renumbers objects
whose writes never reach the store — a move that reverts on the next refresh, duplicate persisted
`pinOrder` values, or a save that fails outright. Found by the codex pass on #1504.

`WorkspaceRowDisplayState.pinGraphRevision` closes it. `MainWindowOrderCache` already fingerprints
that graph to memoize the Pinned ordering, and that fingerprint is already the complete account of
what the pin verbs read: identity, `pinOrder`, name, and status for every workspace. The cache
bumps a counter whenever it changes and hands it back with the ordering, as one
`SidebarPinnedSection`, so a row cannot pair an ordering from one graph with a revision from
another. Every workspace row carries the same number, so a peer replacement rebuilds all of them
and no closure survives holding a superseded object.

The trade is deliberate and lands on the cheap side. A peer replacement now rebuilds the whole
workspace list rather than one row, but the measurement above is the reason that is affordable:
SwiftData does not churn instances during steady-state agent churn, so the revision holds still
through the load this slice exists to survive. What moves it — a workspace added, archived,
deleted, pinned, renamed, or replaced — is a human-paced event that was going to rebuild most rows
anyway.

`SidebarRowRebuildTests.peerReplacementRefreshesTheRetainedPinClosure` mounts the rows and proves
it through the closure itself rather than through the state value: it invokes the `onTogglePin`
the row actually kept and asserts the array it walks no longer contains the superseded peer.

## Two surfaces that outlive their row's body

A row that skips its body stops re-reading anything its body computed — including the clock. Two
places in the row's expression keep drawing after that:

- **The hover card**, below, which needed the most thinking.
- **The workspace age**, which read `Date()` in the row's body. Under the old shape every sidebar
  refresh rebuilt every row, so it was never wrong for long; under this one a workspace created 59
  minutes ago kept showing `59m` past the hour, beside an elapsed timer that was still advancing,
  until the row's state moved for some unrelated reason. `WorkspaceAgeLabel` takes the fix the
  elapsed timer already had: `createdAt` is fixed for the workspace's life, so the label takes it
  and owns a minute clock inside a leaf of its own. Also found by the codex pass on #1504.

## Why the hover card needed its own thinking

The card is the surface that can be *on screen* longest while its row's body never runs again, so
it is the place a fingerprint has to cover most beyond what the row itself draws:

- **Agent detail the row does not draw** — model, context percent, cost, last-active. A cost tick
  moves none of the dot, the badge, or the live line, so the row's own appearance would not have
  caught it. The full `AgentSessionStatus` per tab rides `SidebarRowSessionState`.
- **The two lazy resolutions** — the foreground process name and the Claude transcript tail are
  kicked off *by* the card opening and land a moment later. They ride the state for exactly that
  reason: without it, the first hover on a row would never show the tail it just went and fetched.
- **Tabs opening and closing** — the row's sessions ride the state, which is what fingerprints the
  `hostSessions` array the provider captured by value.

None of this costs a new lookup. `sessionActivity` already resolved every one of a row's statuses
to pick the freshest; gathering them once per row and deriving the dot, the live line, and the
card's inputs from that one pass replaces three separate walks with one.

## The one accepted residual

**A tab's title changing while its card is already open repaints on the next hover, not in place.**

`titleForSession` resolves through `SurfaceStore.displayTitle(for:)`, which scans every mounted
surface to find the one owning a session. Putting that in the display state would run it for every
tab of every row on every evaluation — reintroducing per-render work of exactly the shape #1354
spent its slice removing, to fix a stale reading that lasts as long as one hover.

It is bounded (one card, until the pointer leaves), self-healing (the next hover reads live), and
the same class of trade #1353 recorded for its recency-only staleness. If it ever matters, the fix
is to give `SurfaceStore` a session-keyed title index rather than to widen the fingerprint.

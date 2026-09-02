//
//  SidebarRowEquality.swift
//  WorkspaceManager
//
//  The equality boundary each sidebar row sits behind, and the value types that decide it.
//  A row's content is built by a closure, and closures never compare memberwise-equal, so
//  before this every sidebar refresh reloaded every row: under agent load that is one full
//  `List`/NSTableView reload per 150ms coalescing window (#1366, following #1353's coalesced
//  ingest and #1354's memoized render path). Comparing on a value that describes exactly what
//  the row draws turns that into one row redrawn per changed session.
//

import Foundation
import SwiftUI
import WorkspaceManagerCore

/// One sidebar row behind an equality boundary. `content` builds the row's whole expression —
/// the row view, its hover card, and its context menu — and `state` is the complete account of
/// what that expression draws. SwiftUI skips `content` while the state is unchanged.
///
/// The closures inside `content` outlive the skip: a row that does not rebuild keeps the
/// closures it was built with. Every one of them must therefore either read live storage
/// through a reference (the tile-tree store, the agent registry, a `@State`/`@Binding`/
/// `@Environment` box) or read only values `state` carries. The site-by-site account is in
/// `docs/development/sidebar-row-equality.md`; the display-state types below are the half of
/// that contract the compiler can hold onto.
/// `nonisolated` at the type: SwiftUI compares view values outside `body`'s isolation, and the
/// comparison touches only `state`, never `content`. `body` carries its own `@MainActor` from
/// the `View` conformance.
nonisolated struct SidebarEquatableRow<RowState: Equatable & Sendable, Content: View>: View, Equatable {
    private let state: RowState
    private let content: () -> Content

    init(state: RowState, @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
    }

    @MainActor
    var body: some View {
        content()
    }
}

/// The tabs sharing one row's session key and everything the registry and the lazy hover
/// resolvers currently know about them, gathered per row.
///
/// Per row is the point: an event on one session changes that row's state and no other's, which
/// is what lets every unchanged row skip its body. It also closes the hover card's staleness
/// hole — `tabsProvider` reports these same values, and the two lazy resolutions (foreground
/// process name, Claude transcript tail) land *after* a card opens, so they must be able to
/// invalidate the row that is showing the card.
struct SidebarRowSessionState: Equatable {
    /// The host sessions whose key matches the row's, in session order. Carrying the sessions
    /// themselves is what fingerprints the `hostSessions` array a surviving `tabsProvider`
    /// captured by value.
    var sessions: [HostTerminalSession] = []
    /// Parallel to `sessions`: the registry's status for each, `nil` for a plain tab.
    var statuses: [AgentSessionStatus?] = []
    /// Parallel to `sessions`: the resolved foreground process name, `nil` until it resolves.
    var foregroundNames: [String?] = []
    /// Parallel to `sessions`: the Claude Code transcript tail, `nil` for every other tab and
    /// for every non-happy path.
    var transcriptTails: [String?] = []

    /// The freshest registered status among the row's tabs — what the activity dot and the
    /// live status line both read. Resolved from the gathered statuses rather than by a second
    /// pass over the registry, so a row costs one lookup per tab per render.
    var freshestStatus: AgentSessionStatus? {
        statuses.lazy.compactMap { $0 }.max { $0.lastEventAt < $1.lastEventAt }
    }

    var hasAnyStatus: Bool {
        statuses.contains { $0 != nil }
    }
}

// MARK: - SidebarRowIdentity
//
// Rows whose closures dereference a SwiftData model carry `identity: ObjectIdentifier` alongside
// the model's `id`, for the reason `MainWindowOrderSignature` carries one: SwiftData can hand
// back a replacement instance with identical values (the hole review found in #1354's
// `SidebarRepoSortCache`). A row keyed on `id` plus values alone would compare equal across that
// swap, skip its body, and go on handing the *superseded* object to the closures it kept —
// `setNote`, `togglePin`, `removeRepo`, `removeWebSource`, `workspace.path`.
//
// Selection is the one path that would have been safe without it, and it is worth naming because
// it shows the shape of the general defence: `selectWorkspace` reaches `setSelectedWorkspace`,
// which stores `MainWindowWorkspaceSelection` — a `UUID`, not the object — and every read goes
// back through `cachedWorkspace(with:)` against the live index. A superseded object handed to it
// is reduced to its id and re-resolved, which is the invariant `Sources/AGENTS.md` states as
// "persist selection state by stable IDs, not live SwiftData objects". The mutations have no such
// boundary, so they get the fingerprint instead.
//
// `ArchivedDisclosureDisplayState` deliberately carries none: its only closure is
// `toggleArchivedSection(for:)`, which reads `repo.id`, and the state already carries `repoID`.

/// Everything a repo row and its context menu draw. `remoteURL` rather than the parsed
/// `GitHubRepoSlug`: the slug is what the menu's "New Web Session" entry reads, and
/// fingerprinting its input costs a string compare instead of a parse per row per render.
struct RepoRowDisplayState: Equatable {
    let repoID: UUID
    /// The `Repo` object this row's closures captured — see `SidebarRowIdentity` above.
    let identity: ObjectIdentifier
    let name: String
    let remoteURL: String?
    let activeWorkspaceCount: Int
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int
    let isSelected: Bool
    let isExpanded: Bool
    let showsExpansion: Bool
    let sessionActivityTooltip: String?
    let isCreatingWorkspace: Bool
    let sessionState: SidebarRowSessionState
}

/// Everything a workspace row and its context menu draw.
///
/// `pinnedIndex`/`pinnedCount` stand in for the Pinned section's ordering: the Move Up / Move
/// Down entries used to rebuild that ordering every time the menu opened, and a menu closure
/// that survives a skipped body would have rebuilt it from a stale workspace list. Carrying the
/// two numbers both fingerprints that input and retires the sort.
///
/// They are not enough on their own, which is what `pinGraphRevision` is for: the pin verbs
/// walk the *whole* workspace list, not just this row's workspace, so a peer replaced by an
/// equal-valued instance leaves index and count untouched while the graph underneath them
/// changes. See `MainWindowOrderCache.pinGraphRevision`.
struct WorkspaceRowDisplayState: Equatable {
    let workspaceID: UUID
    /// The `Workspace` object this row's closures captured — see `SidebarRowIdentity` above.
    let identity: ObjectIdentifier
    let name: String
    let status: WorkspaceStatus
    let backendIdentifier: String
    let gitBranch: String?
    let note: String?
    let createdAt: Date
    let repoRemoteURL: String?
    let isSelected: Bool
    let statusMessage: String?
    let sessionActivity: SidebarSessionActivity
    let paneCount: Int
    let repoContext: String?
    let isNested: Bool
    let isExpanded: Bool
    let showsDisclosure: Bool
    let isPinned: Bool
    let isPinnable: Bool
    let isPinnedSectionRow: Bool
    /// Position within the Pinned section, `nil` when the workspace is not in it.
    let pinnedIndex: Int?
    let pinnedCount: Int
    /// The revision of the workspace graph this row's retained `togglePin` and `movePin`
    /// closures walk. Every workspace row carries the same number, so a peer replacement
    /// rebuilds all of them and no closure survives holding a superseded object.
    let pinGraphRevision: Int
    let liveStatus: SidebarLiveSessionStatus?
    let sessionState: SidebarRowSessionState

    /// What `SidebarPinController.canMove(_:by:in:)` would answer, read off the position the
    /// row already carries. A workspace outside the section has no move to offer.
    var canMovePinUp: Bool {
        guard let pinnedIndex else { return false }
        return pinnedIndex > 0
    }

    var canMovePinDown: Bool {
        guard let pinnedIndex else { return false }
        return pinnedIndex + 1 < pinnedCount
    }
}

/// Everything a web-source row and its context menu draw. The favicon needs no fingerprint:
/// `WebSourceFaviconView` holds it in its own `@State` and reloads on `baseURLString`, so a row
/// that skips its body keeps a favicon view that is still watching the right URL.
struct WebSourceRowDisplayState: Equatable {
    let sourceID: UUID
    /// The `WebSource` object this row's closures captured — see `SidebarRowIdentity` above.
    /// `removeWebSource` deletes through it, so a superseded instance would delete nothing.
    let identity: ObjectIdentifier
    let name: String
    let urlString: String
    let isSelected: Bool
    let indentation: CGFloat
}

/// The archived-section pill: a count, an expansion state, and the repo it belongs to.
struct ArchivedDisclosureDisplayState: Equatable {
    let repoID: UUID
    let count: Int
    let isExpanded: Bool
}

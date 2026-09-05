import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// Proves the lever in #1366 at the render level rather than by inspection: with a real view
/// tree mounted, changing one row's display state rebuilds that row and no other.
///
/// The leaf carries a closure, which is the shape every sidebar row has and the reason none of
/// them could ever compare memberwise-equal — so a leaf that rebuilds when its neighbour changes
/// is exactly the behaviour this slice removes.
///
/// What these prove and what they do not, stated because the distinction is easy to lose. They
/// exercise `SidebarEquatableRow`, the display-state values, and — through
/// `SidebarPinnedSection.placement(of:)` — the production derivation of a row's pin fields.
///
/// They do **not** mount `SidebarView` itself, which needs seven environment dependencies and a
/// dozen closures. So none of `SidebarView`'s own wiring is guarded here: that it calls
/// `.equatable()` on every row, that it builds each state through `placement(of:)` rather than
/// assembling the fields itself, or that it passes `recentSnapshotTakenAt` rather than a fresh
/// instant. Those hold by construction and by review. Sharing `placement(of:)` is what keeps the
/// *derivation* from drifting between here and the app; the call sites themselves stay unguarded.
///
/// `.serialized` because every test here mounts a view and pumps the main run loop, and a run
/// loop pumped by one test drives the display cycle of any view another test still has mounted.
@MainActor
@Suite("Sidebar row rebuild scoping", .serialized)
struct SidebarRowRebuildTests {
    private final class BodyCounter {
        private(set) var counts: [Int: Int] = [:]

        func note(_ index: Int) {
            counts[index, default: 0] += 1
        }

        /// What `settle` watches to decide rendering has stopped.
        var total: Int {
            counts.values.reduce(0, +)
        }
    }

    private struct CountingLeaf: View {
        let onBody: () -> Void

        var body: some View {
            onBody()
            return Color.clear.frame(width: 40, height: 12)
        }
    }

    private final class RowStateModel: ObservableObject {
        @Published var values: [Int]

        init(values: [Int]) {
            self.values = values
        }
    }

    private struct EquatableRowList: View {
        @ObservedObject var model: RowStateModel
        let counter: BodyCounter

        var body: some View {
            VStack(spacing: 0) {
                ForEach(model.values.indices, id: \.self) { index in
                    SidebarEquatableRow(state: model.values[index]) {
                        CountingLeaf { counter.note(index) }
                    }
                    .equatable()
                }
            }
        }
    }

    /// The same list without the equality boundary — the pre-change shape, kept as the control
    /// so the assertion below is measuring the boundary and not the test harness.
    private struct PlainRowList: View {
        @ObservedObject var model: RowStateModel
        let counter: BodyCounter

        var body: some View {
            VStack(spacing: 0) {
                ForEach(model.values.indices, id: \.self) { index in
                    CountingLeaf { counter.note(index) }
                }
            }
        }
    }

    /// Pumps until the rows stop rebuilding, rather than for a fixed slice of wall clock.
    ///
    /// A fixed slice was the wrong instrument, and it took a CI failure to show it: every
    /// assertion here compares a count taken before a change against one taken after, so a render
    /// pass that lands *between* those two reads is indistinguishable from a rebuild the boundary
    /// should have prevented. On a laptop one 0.15s pump drained the display cycle every time; on
    /// a loaded CI runner it did not, and every row read one rebuild high — including in the two
    /// tests that predate this change. Waiting for the counter to hold still measures the thing
    /// the assertions actually depend on.
    /// Quiesced means the rows have rendered *and* the count has then held still across
    /// `stillPumpsRequired` consecutive pumps. Requiring the first half matters: before the
    /// initial render the count is zero and would otherwise read as "already still".
    ///
    /// Requiring the second half in quantity is what a single still pump got wrong. On a loaded
    /// runner the display cycle can pause for longer than one 20ms slice, so a pass deferred past
    /// that slice lands after the baseline read and every row reads one rebuild high — the same
    /// signature the fixed 150ms pump produced, which is what this loop replaced it to prevent.
    /// A window of pumps rather than one measures a pause the machine, not the clock, decides the
    /// length of. The exit condition still ends this: ~160ms of quiet in the common case, and the
    /// cap bounds the pathological one at 3s.
    private func settle(_ host: NSHostingView<some View>, _ counter: BodyCounter) {
        let stillPumpsRequired = 8
        var previous = -1
        var stillPumps = 0
        for _ in 0..<150 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            let total = counter.total
            stillPumps = (total > 0 && total == previous) ? stillPumps + 1 : 0
            if stillPumps >= stillPumpsRequired { return }
            previous = total
        }
    }

    @Test("Changing one row's state rebuilds that row alone")
    func oneRowChangeRebuildsOneRow() {
        let rowCount = 12
        let counter = BodyCounter()
        let model = RowStateModel(values: Array(repeating: 0, count: rowCount))
        let host = NSHostingView(rootView: EquatableRowList(model: model, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let baseline = counter.counts
        #expect(baseline.count == rowCount, "every row should have rendered once to start")

        model.values[3] += 1
        settle(host, counter)

        for index in 0..<rowCount {
            let delta = (counter.counts[index] ?? 0) - (baseline[index] ?? 0)
            #expect(delta == (index == 3 ? 1 : 0), "row \(index) rebuilt \(delta) times")
        }
    }

    /// The control: without the boundary, the same single-value change rebuilds everything. This
    /// is what the sidebar did on every coalescing window before this slice.
    @Test("Without the equality boundary the same change rebuilds every row")
    func plainRowsAllRebuild() {
        let rowCount = 12
        let counter = BodyCounter()
        let model = RowStateModel(values: Array(repeating: 0, count: rowCount))
        let host = NSHostingView(rootView: PlainRowList(model: model, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let baseline = counter.counts
        model.values[3] += 1
        settle(host, counter)

        let rebuilt = (0..<rowCount).filter { (counter.counts[$0] ?? 0) > (baseline[$0] ?? 0) }
        #expect(rebuilt.count == rowCount, "expected every row to rebuild, got \(rebuilt)")
    }

    // MARK: - The graph a retained pin closure walks

    /// Records the `onTogglePin` closure each row was last built with, and what that closure
    /// walks when it runs. Holding the closure is the point: a row that skips its body keeps the
    /// one it already had, which is the whole staleness class this slice creates.
    private final class PinClosureRecorder {
        private var closures: [UUID: () -> Void] = [:]
        private(set) var walked: [ObjectIdentifier] = []

        func register(_ id: UUID, _ closure: @escaping () -> Void) {
            closures[id] = closure
        }

        func walk(_ id: UUID) -> [ObjectIdentifier] {
            walked = []
            closures[id]?()
            return walked
        }

        func note(_ identities: [ObjectIdentifier]) {
            walked = identities
        }
    }

    /// The production capture shape, down to which array is frozen. `SidebarView` holds
    /// `let repos: [Repo]` and derives `allWorkspaces` as `repos.flatMap(\.workspaces)` *at call
    /// time*, so what a retained closure freezes is the **repo** array; the workspaces it reaches
    /// are whatever those repo objects' relationships hold when the closure runs.
    ///
    /// That distinction is the whole hazard. A closure holding a superseded `Repo` re-derives
    /// from that instance's relationship and gets the graph as it was, and `pinGraphRevision` is
    /// computed by the parent from the *fresh* `repos.flatMap(\.workspaces)` — which is exactly
    /// the expression the closure re-derives, one evaluation later. Freezing the workspace array
    /// here instead would have proved a fixture rather than the shipping shape.
    private struct PinRowList: View {
        let repos: [Repo]
        let cache: MainWindowOrderCache
        let recorder: PinClosureRecorder
        let counter: BodyCounter

        private let controller = SidebarPinController()

        /// `SidebarView.allWorkspaces`, verbatim.
        private var allWorkspaces: [Workspace] {
            repos.flatMap(\.workspaces)
        }

        var body: some View {
            let pinned = cache.pinnedSection(in: allWorkspaces, controller: controller)
            VStack(spacing: 0) {
                ForEach(Array(allWorkspaces.enumerated()), id: \.element.id) { index, workspace in
                    SidebarEquatableRow(state: rowState(workspace, pinned: pinned)) {
                        CountingLeaf {
                            counter.note(index)
                            recorder.register(workspace.id) { togglePin(workspace) }
                        }
                    }
                    .equatable()
                }
            }
        }

        /// Stands in for `SidebarView.togglePin`, which re-derives `allWorkspaces` off the
        /// captured `self` and hands every one of them to `SidebarPinController` to renumber.
        private func togglePin(_ workspace: Workspace) {
            recorder.note(allWorkspaces.map(ObjectIdentifier.init))
        }

        /// The pin fields come from `SidebarPinnedSection.placement(of:)` — the same production
        /// call `SidebarView` makes, so the derivation cannot drift between here and the app. The
        /// rest is fixture.
        private func rowState(
            _ workspace: Workspace,
            pinned: SidebarPinnedSection
        ) -> WorkspaceRowDisplayState {
            let placement = pinned.placement(of: workspace)
            return WorkspaceRowDisplayState(
                workspaceID: workspace.id,
                identity: ObjectIdentifier(workspace),
                name: workspace.name,
                status: workspace.status,
                backendIdentifier: workspace.backendIdentifier,
                gitBranch: workspace.gitBranch,
                note: workspace.note,
                createdAt: workspace.createdAt,
                repoRemoteURL: workspace.sourceRepo?.remoteURL,
                isSelected: false,
                statusMessage: nil,
                sessionActivity: .inactive,
                paneCount: 0,
                repoContext: nil,
                isNested: false,
                isExpanded: false,
                showsDisclosure: false,
                isPinned: workspace.isPinned,
                isPinnable: controller.isPinnable(workspace),
                isPinnedSectionRow: true,
                pinnedIndex: placement.index,
                pinnedCount: placement.count,
                pinGraphRevision: placement.graphRevision,
                liveStatus: nil,
                sessionState: SidebarRowSessionState()
            )
        }
    }

    private final class GraphModel: ObservableObject {
        @Published var repos: [Repo]

        init(repos: [Repo]) {
            self.repos = repos
        }
    }

    /// Mirrors `ContentView` → `SidebarView`: the observable holder re-evaluates and hands the
    /// array down as a value, so the rows below decide for themselves whether to rebuild.
    private struct PinRowHost: View {
        @ObservedObject var model: GraphModel
        let cache: MainWindowOrderCache
        let recorder: PinClosureRecorder
        let counter: BodyCounter

        var body: some View {
            PinRowList(
                repos: model.repos,
                cache: cache,
                recorder: recorder,
                counter: counter
            )
        }
    }

    private func pinnedFixture(_ names: [String]) -> Repo {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/repos/alpha"))
        repo.workspaces = names.enumerated().map { order, name in
            let workspace = Workspace(
                name: name,
                path: URL(fileURLWithPath: "/repos/alpha/\(name)"),
                sourceRepo: repo
            )
            workspace.pinOrder = order
            return workspace
        }
        return repo
    }

    /// An equal-valued stand-in for one workspace: same id, same drawn values, same rank, a
    /// different object. What SwiftData can hand back, and what a value-keyed fingerprint cannot
    /// see.
    private func replacement(for workspace: Workspace, in repo: Repo) -> Workspace {
        let replacement = Workspace(
            name: workspace.name,
            path: URL(fileURLWithPath: workspace.path),
            sourceRepo: repo,
            lastAccessedAt: workspace.lastAccessedAt
        )
        replacement.id = workspace.id
        replacement.createdAt = workspace.createdAt
        replacement.pinOrder = workspace.pinOrder
        replacement.status = workspace.status
        return replacement
    }

    /// The blocker the codex pass on #1504 found, at the render level and in the shipping capture
    /// shape. A row keeps its `onTogglePin` closure across a skipped body, and that closure
    /// re-derives the whole workspace list from the `[Repo]` array it froze.
    ///
    /// So the replacement modelled here is the one that actually bites: SwiftData hands back a
    /// `Repo` whose relationship holds a replacement for one *peer* workspace. The row under test
    /// keeps its own workspace object, its name, its pinned index and its pinned count — nothing
    /// it draws moves — so before `pinGraphRevision` it skipped, kept the superseded repo, and
    /// the next Pin or Move renumbered an object whose writes never reach the store: a pin move
    /// that reverts on refresh, or duplicate persisted `pinOrder` values.
    @Test("A replaced peer reaches the pin closure the row kept")
    func peerReplacementRefreshesTheRetainedPinClosure() {
        let counter = BodyCounter()
        let recorder = PinClosureRecorder()
        let cache = MainWindowOrderCache()
        let repo = pinnedFixture(["mine", "peer", "third"])
        let original = repo.workspaces
        let model = GraphModel(repos: [repo])

        let host = NSHostingView(
            rootView: PinRowHost(
                model: model, cache: cache, recorder: recorder, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let mine = original[0]
        let peer = original[1]
        #expect(
            recorder.walk(mine.id) == original.map(ObjectIdentifier.init),
            "the closure starts out walking the graph it was built with"
        )

        // The superseding repo: same values, a different object, and a replacement for one peer
        // in its relationship. `mine` and `third` are carried across unchanged, so the row under
        // test has nothing of its own to notice.
        let refreshedRepo = Repo(name: repo.name, localPath: URL(fileURLWithPath: repo.localPath))
        refreshedRepo.id = repo.id
        let refreshedWorkspaces = [mine, replacement(for: peer, in: refreshedRepo), original[2]]
        refreshedRepo.workspaces = refreshedWorkspaces

        model.repos = [refreshedRepo]
        settle(host, counter)

        // Reparenting moves `mine` and `third` onto the superseding repo, which is what leaves
        // the old instance holding the superseded peer alone. A closure still deriving from it
        // would renumber a one-element list — the corruption in its starkest form.
        let walked = recorder.walk(mine.id)
        #expect(
            !walked.contains(ObjectIdentifier(peer)),
            "the row must not still be handing the superseded peer to the pin controller"
        )
        #expect(
            walked == refreshedWorkspaces.map(ObjectIdentifier.init),
            "it must walk the graph SwiftData now holds"
        )
    }

    /// The same hazard with the workspaces left alone, which is the case a workspace-only
    /// fingerprint cannot see. SwiftData supersedes the `Repo` and the *same* workspace objects
    /// move onto it, so every identity, id, name and rank a row draws is untouched. The stale
    /// closure is left deriving from a drained repo: `pin` would read `max(pinOrder)` over an
    /// empty list and hand out a rank another workspace already holds.
    @Test("A replaced repo reaches the pin closure even when its workspaces survive")
    func repoReplacementRefreshesTheRetainedPinClosure() {
        let counter = BodyCounter()
        let recorder = PinClosureRecorder()
        let cache = MainWindowOrderCache()
        let repo = pinnedFixture(["mine", "peer", "third"])
        let original = repo.workspaces
        let model = GraphModel(repos: [repo])

        let host = NSHostingView(
            rootView: PinRowHost(
                model: model, cache: cache, recorder: recorder, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let mine = original[0]
        #expect(recorder.walk(mine.id) == original.map(ObjectIdentifier.init))

        let refreshedRepo = Repo(name: repo.name, localPath: URL(fileURLWithPath: repo.localPath))
        refreshedRepo.id = repo.id
        refreshedRepo.workspaces = original

        model.repos = [refreshedRepo]
        settle(host, counter)

        #expect(
            repo.workspaces.isEmpty,
            "the superseded repo is drained, which is what a stale closure would derive from"
        )
        #expect(
            recorder.walk(mine.id) == original.map(ObjectIdentifier.init),
            "the row must have recaptured, so it walks the full graph and not the drained repo"
        )
    }

    /// The converse: re-publishing the same instances must not rebuild anything, or carrying the
    /// revision on every row would have undone the per-row scoping it is defending.
    @Test("Re-publishing the same workspace graph rebuilds no row")
    func unchangedGraphRebuildsNoPinRow() {
        let counter = BodyCounter()
        let recorder = PinClosureRecorder()
        let cache = MainWindowOrderCache()
        let repo = pinnedFixture(["mine", "peer", "third"])
        let model = GraphModel(repos: [repo])

        let host = NSHostingView(
            rootView: PinRowHost(
                model: model, cache: cache, recorder: recorder, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let baseline = counter.counts
        model.repos = [repo]
        settle(host, counter)

        for index in repo.workspaces.indices {
            #expect(counter.counts[index] == baseline[index], "row \(index) rebuilt")
        }
    }

    @Test("A change that moves no row's state rebuilds nothing")
    func norowChangeRebuildsNothing() {
        let rowCount = 8
        let counter = BodyCounter()
        let model = RowStateModel(values: Array(repeating: 0, count: rowCount))
        let host = NSHostingView(rootView: EquatableRowList(model: model, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host, counter)

        let baseline = counter.counts
        // A publish that leaves every value where it was — the change-gated no-op #1353 lets
        // through when a session's render-relevant state did not actually move.
        model.values = model.values
        settle(host, counter)

        for index in 0..<rowCount {
            #expect(counter.counts[index] == baseline[index], "row \(index) rebuilt")
        }
    }
}

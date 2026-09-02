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
@MainActor
@Suite("Sidebar row rebuild scoping")
struct SidebarRowRebuildTests {
    private final class BodyCounter {
        private(set) var counts: [Int: Int] = [:]

        func note(_ index: Int) {
            counts[index, default: 0] += 1
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

    private func settle(_ host: NSHostingView<some View>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
    }

    @Test("Changing one row's state rebuilds that row alone")
    func oneRowChangeRebuildsOneRow() {
        let rowCount = 12
        let counter = BodyCounter()
        let model = RowStateModel(values: Array(repeating: 0, count: rowCount))
        let host = NSHostingView(rootView: EquatableRowList(model: model, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host)

        let baseline = counter.counts
        #expect(baseline.count == rowCount, "every row should have rendered once to start")

        model.values[3] += 1
        settle(host)

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
        settle(host)

        let baseline = counter.counts
        model.values[3] += 1
        settle(host)

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

    /// The production capture shape: `workspaces` is a plain `let`, so a closure calling a method
    /// on this view captures the array **by value** — exactly what `SidebarView` does with
    /// `repos`, and why `togglePin` can end up renumbering superseded objects.
    private struct PinRowList: View {
        let workspaces: [Workspace]
        let cache: MainWindowOrderCache
        let recorder: PinClosureRecorder
        let counter: BodyCounter

        private let controller = SidebarPinController()

        var body: some View {
            let pinned = cache.pinnedSection(in: workspaces, controller: controller)
            VStack(spacing: 0) {
                ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
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

        /// Stands in for `SidebarView.togglePin`, which reads `allWorkspaces` off the captured
        /// `self` and hands every one of them to `SidebarPinController` to renumber.
        private func togglePin(_ workspace: Workspace) {
            recorder.note(workspaces.map(ObjectIdentifier.init))
        }

        /// The pin half comes from the production cache and controller rather than from numbers
        /// chosen here; the rest is fixture.
        private func rowState(
            _ workspace: Workspace,
            pinned: SidebarPinnedSection
        ) -> WorkspaceRowDisplayState {
            WorkspaceRowDisplayState(
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
                pinnedIndex: pinned.workspaces.firstIndex { $0.id == workspace.id },
                pinnedCount: pinned.workspaces.count,
                pinGraphRevision: pinned.graphRevision,
                liveStatus: nil,
                sessionState: SidebarRowSessionState()
            )
        }
    }

    private final class GraphModel: ObservableObject {
        @Published var workspaces: [Workspace]

        init(workspaces: [Workspace]) {
            self.workspaces = workspaces
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
                workspaces: model.workspaces,
                cache: cache,
                recorder: recorder,
                counter: counter
            )
        }
    }

    private func pinnedFixture(_ names: [String]) -> (Repo, [Workspace]) {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/repos/alpha"))
        let workspaces = names.enumerated().map { order, name -> Workspace in
            let workspace = Workspace(
                name: name,
                path: URL(fileURLWithPath: "/repos/alpha/\(name)"),
                sourceRepo: repo
            )
            workspace.pinOrder = order
            return workspace
        }
        repo.workspaces = workspaces
        return (repo, workspaces)
    }

    /// The blocker the codex pass on #1504 found, at the render level. A row keeps its
    /// `onTogglePin` closure across a skipped body, and that closure walks the whole workspace
    /// list. When SwiftData replaces a *peer* with an equal-valued instance, nothing about this
    /// row's own workspace, pinned index, or pinned count moves — so before `pinGraphRevision`
    /// the row skipped, and the next Pin or Move renumbered an object whose writes never reach
    /// the store: a pin move that reverts on refresh, or duplicate persisted `pinOrder` values.
    @Test("A replaced peer reaches the pin closure the row kept")
    func peerReplacementRefreshesTheRetainedPinClosure() {
        let counter = BodyCounter()
        let recorder = PinClosureRecorder()
        let cache = MainWindowOrderCache()
        let (repo, original) = pinnedFixture(["mine", "peer", "third"])
        let model = GraphModel(workspaces: original)

        let host = NSHostingView(
            rootView: PinRowHost(
                model: model, cache: cache, recorder: recorder, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host)

        let mine = original[0]
        let peer = original[1]
        #expect(
            recorder.walk(mine.id) == original.map(ObjectIdentifier.init),
            "the closure starts out walking the graph it was built with"
        )

        let replacement = Workspace(
            name: peer.name,
            path: URL(fileURLWithPath: peer.path),
            sourceRepo: repo,
            lastAccessedAt: peer.lastAccessedAt
        )
        replacement.id = peer.id
        replacement.createdAt = peer.createdAt
        replacement.pinOrder = peer.pinOrder

        let refreshed = [mine, replacement, original[2]]
        model.workspaces = refreshed
        settle(host)

        let walked = recorder.walk(mine.id)
        #expect(
            !walked.contains(ObjectIdentifier(peer)),
            "the row must not still be handing the superseded peer to the pin controller"
        )
        #expect(
            walked == refreshed.map(ObjectIdentifier.init),
            "it must walk the graph SwiftData now holds"
        )
    }

    /// The converse: re-publishing the same instances must not rebuild anything, or carrying the
    /// revision on every row would have undone the per-row scoping it is defending.
    @Test("Re-publishing the same workspace graph rebuilds no row")
    func unchangedGraphRebuildsNoPinRow() {
        let counter = BodyCounter()
        let recorder = PinClosureRecorder()
        let cache = MainWindowOrderCache()
        let (_, workspaces) = pinnedFixture(["mine", "peer", "third"])
        let model = GraphModel(workspaces: workspaces)

        let host = NSHostingView(
            rootView: PinRowHost(
                model: model, cache: cache, recorder: recorder, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        settle(host)

        let baseline = counter.counts
        model.workspaces = workspaces
        settle(host)

        for index in workspaces.indices {
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
        settle(host)

        let baseline = counter.counts
        // A publish that leaves every value where it was — the change-gated no-op #1353 lets
        // through when a session's render-relevant state did not actually move.
        model.values = model.values
        settle(host)

        for index in 0..<rowCount {
            #expect(counter.counts[index] == baseline[index], "row \(index) rebuilt")
        }
    }
}

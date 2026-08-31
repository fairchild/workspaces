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

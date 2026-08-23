import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarPinController")
struct SidebarPinControllerTests {
    private let controller = SidebarPinController()

    private func makeRepo(_ name: String = "alpha") -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func makeWorkspace(
        _ name: String,
        in repo: Repo,
        pinOrder: Int? = nil,
        status: WorkspaceStatus = .active
    ) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            status: status,
            pinOrder: pinOrder
        )
    }

    @Test("Pinning appends to the end and numbers the section 0…n")
    func pinningAppendsAndNumbers() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo)
        let second = makeWorkspace("second", in: repo)
        let third = makeWorkspace("third", in: repo)
        let all = [first, second, third]

        controller.pin(second, in: all)
        controller.pin(first, in: all)
        controller.pin(third, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["second", "first", "third"])
        #expect(all.compactMap(\.pinOrder).sorted() == [0, 1, 2])
        #expect(second.pinOrder == 0)
        #expect(first.pinOrder == 1)
        #expect(third.pinOrder == 2)
    }

    @Test("Pinning an already-pinned workspace leaves the order alone")
    func pinningIsIdempotent() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let all = [first, second]

        controller.pin(first, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["first", "second"])
        #expect(first.pinOrder == 0)
        #expect(second.pinOrder == 1)
    }

    @Test("Unpinning from the middle closes the gap it leaves")
    func unpinningRenumbersTheRemainder() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let third = makeWorkspace("third", in: repo, pinOrder: 2)
        let all = [first, second, third]

        controller.unpin(second, in: all)

        #expect(second.pinOrder == nil)
        #expect(second.isPinned == false)
        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["first", "third"])
        #expect(first.pinOrder == 0)
        #expect(third.pinOrder == 1)
    }

    @Test("Unpinning the last pinned workspace empties the section")
    func unpinningTheLastEmptiesTheSection() {
        let repo = makeRepo()
        let only = makeWorkspace("only", in: repo, pinOrder: 0)

        controller.unpin(only, in: [only])

        #expect(controller.pinnedWorkspaces(in: [only]).isEmpty)
    }

    @Test("A pin renumbers a store whose stored values are gapped or duplicated")
    func renumberingRepairsGapsAndDuplicates() {
        let repo = makeRepo()
        let gapped = makeWorkspace("gapped", in: repo, pinOrder: 9)
        let duplicateA = makeWorkspace("aardvark", in: repo, pinOrder: 4)
        let duplicateB = makeWorkspace("badger", in: repo, pinOrder: 4)
        let fresh = makeWorkspace("fresh", in: repo)
        let all = [gapped, duplicateA, duplicateB, fresh]

        controller.pin(fresh, in: all)

        // Duplicates break the tie by name, and the newly pinned row still lands last.
        #expect(
            controller.pinnedWorkspaces(in: all).map(\.name) == ["aardvark", "badger", "gapped", "fresh"]
        )
        #expect(all.compactMap(\.pinOrder).sorted() == [0, 1, 2, 3])
    }

    @Test("Renumbering alone leaves an already-contiguous section untouched")
    func renumberingIsAFixedPoint() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)

        controller.renumber(in: [first, second])

        #expect(first.pinOrder == 0)
        #expect(second.pinOrder == 1)
    }

    @Test("An archived workspace cannot be pinned")
    func archivedWorkspacesAreNotPinnable() {
        let repo = makeRepo()
        let archived = makeWorkspace("archived", in: repo, status: .archived)
        let live = makeWorkspace("live", in: repo)

        #expect(controller.isPinnable(archived) == false)
        #expect(controller.isPinnable(live))

        controller.pin(archived, in: [archived, live])

        #expect(archived.pinOrder == nil)
        #expect(controller.pinnedWorkspaces(in: [archived, live]).isEmpty)
    }

    @Test("Stopped workspaces are still pinnable — only archiving takes a row out")
    func stoppedWorkspacesStayPinnable() {
        let repo = makeRepo()
        let stopped = makeWorkspace("stopped", in: repo, status: .stopped)

        controller.pin(stopped, in: [stopped])

        #expect(stopped.pinOrder == 0)
    }

    @Test("Unpinned workspaces stay out of the Pinned section")
    func unpinnedWorkspacesAreExcluded() {
        let repo = makeRepo()
        let pinned = makeWorkspace("pinned", in: repo, pinOrder: 0)
        let loose = makeWorkspace("loose", in: repo)

        #expect(controller.pinnedWorkspaces(in: [pinned, loose]).map(\.name) == ["pinned"])
    }

    @Test("pinOrder survives a round trip through the model store")
    @MainActor
    func pinOrderPersists() throws {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let repo = makeRepo()
        let pinned = makeWorkspace("pinned", in: repo)
        let loose = makeWorkspace("loose", in: repo)
        context.insert(repo)
        context.insert(pinned)
        context.insert(loose)
        controller.pin(pinned, in: [pinned, loose])
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<Workspace>())
        let refetchedPinned = try #require(refetched.first { $0.name == "pinned" })
        let refetchedLoose = try #require(refetched.first { $0.name == "loose" })

        #expect(refetchedPinned.pinOrder == 0)
        #expect(refetchedLoose.pinOrder == nil)
        #expect(controller.pinnedWorkspaces(in: refetched).map(\.name) == ["pinned"])
    }

    @Test("An archived workspace never appears in Pinned, even with a pinOrder left behind")
    func archivedWorkspaceIsExcludedFromPinned() {
        let repo = makeRepo()
        let live = makeWorkspace("live", in: repo, pinOrder: 1)
        let archived = makeWorkspace("archived", in: repo, pinOrder: 0, status: .archived)

        #expect(controller.pinnedWorkspaces(in: [archived, live]).map(\.name) == ["live"])
    }

    @Test("Moving up swaps a row with the one above it and renumbers the section")
    func movingUpReordersTheSection() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let third = makeWorkspace("third", in: repo, pinOrder: 2)
        let all = [first, second, third]

        controller.move(third, by: -1, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["first", "third", "second"])
        #expect(first.pinOrder == 0)
        #expect(third.pinOrder == 1)
        #expect(second.pinOrder == 2)
    }

    @Test("Moving down swaps a row with the one below it")
    func movingDownReordersTheSection() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let all = [first, second]

        controller.move(first, by: 1, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["second", "first"])
        #expect(second.pinOrder == 0)
        #expect(first.pinOrder == 1)
    }

    @Test("Moving past either end of the section changes nothing")
    func movingAtTheBoundariesIsANoOp() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let all = [first, second]

        controller.move(first, by: -1, in: all)
        controller.move(second, by: 1, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["first", "second"])
        #expect(first.pinOrder == 0)
        #expect(second.pinOrder == 1)
        #expect(controller.canMove(first, by: -1, in: all) == false)
        #expect(controller.canMove(second, by: 1, in: all) == false)
        #expect(controller.canMove(first, by: 1, in: all))
        #expect(controller.canMove(second, by: -1, in: all))
    }

    @Test("Moving an unpinned workspace leaves the section alone")
    func movingAnUnpinnedWorkspaceIsANoOp() {
        let repo = makeRepo()
        let pinned = makeWorkspace("pinned", in: repo, pinOrder: 0)
        let loose = makeWorkspace("loose", in: repo)
        let all = [pinned, loose]

        controller.move(loose, by: -1, in: all)
        controller.move(loose, by: 1, in: all)

        #expect(loose.pinOrder == nil)
        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["pinned"])
        #expect(pinned.pinOrder == 0)
        #expect(controller.canMove(loose, by: 1, in: all) == false)
    }

    @Test("An archived workspace carrying a stale pinOrder cannot be moved")
    func movingAnArchivedWorkspaceIsANoOp() {
        let repo = makeRepo()
        let live = makeWorkspace("live", in: repo, pinOrder: 0)
        let archived = makeWorkspace("archived", in: repo, pinOrder: 1, status: .archived)
        let all = [live, archived]

        controller.move(archived, by: -1, in: all)

        #expect(archived.pinOrder == 1)
        #expect(live.pinOrder == 0)
        #expect(controller.canMove(archived, by: -1, in: all) == false)
    }

    @Test("A move renumbers a gapped section rather than preserving its gaps")
    func movingRepairsGaps() {
        let repo = makeRepo()
        let gapped = makeWorkspace("gapped", in: repo, pinOrder: 7)
        let low = makeWorkspace("low", in: repo, pinOrder: 2)
        let all = [gapped, low]

        controller.move(gapped, by: -1, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["gapped", "low"])
        #expect(gapped.pinOrder == 0)
        #expect(low.pinOrder == 1)
    }

    @Test("A move of more than one place lands the row where it was asked to go")
    func movingSeveralPlacesLandsAtTheOffset() {
        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let third = makeWorkspace("third", in: repo, pinOrder: 2)
        let all = [first, second, third]

        controller.move(third, by: -2, in: all)

        #expect(controller.pinnedWorkspaces(in: all).map(\.name) == ["third", "first", "second"])
        #expect(all.compactMap(\.pinOrder).sorted() == [0, 1, 2])
    }

    @Test("A reordered section survives a round trip through the model store")
    @MainActor
    func reorderedPinOrderPersists() throws {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let repo = makeRepo()
        let first = makeWorkspace("first", in: repo, pinOrder: 0)
        let second = makeWorkspace("second", in: repo, pinOrder: 1)
        let third = makeWorkspace("third", in: repo, pinOrder: 2)
        context.insert(repo)
        for workspace in [first, second, third] {
            context.insert(workspace)
        }

        controller.move(third, by: -2, in: [first, second, third])
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<Workspace>())
        #expect(controller.pinnedWorkspaces(in: refetched).map(\.name) == ["third", "first", "second"])
        #expect(refetched.compactMap(\.pinOrder).sorted() == [0, 1, 2])
    }

    @Test("A snapshot restores exactly the touched pin orders after a failed save")
    func snapshotRestoresTouchedPinOrders() {
        let repo = makeRepo()
        let alpha = makeWorkspace("alpha", in: repo, pinOrder: 0)
        let beta = makeWorkspace("beta", in: repo)
        let workspaces = [alpha, beta]

        let snapshot = controller.pinOrderSnapshot(of: workspaces)
        controller.pin(beta, in: workspaces)
        #expect(beta.pinOrder == 1)

        controller.restore(snapshot, in: workspaces)
        #expect(beta.pinOrder == nil)
        #expect(alpha.pinOrder == 0)
    }
}

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
}

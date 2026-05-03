import Foundation
import Testing

@testable import WorkspaceManager

@Suite("SidebarExpansionStateController")
struct SidebarExpansionStateControllerTests {
    @Test("Repo expansion toggles and explicit expansion is idempotent")
    func repoExpansionTogglesAndExpands() {
        let repoID = UUID()
        var controller = SidebarExpansionStateController()

        #expect(!controller.isRepoExpanded(repoID))

        controller.toggleRepoExpansion(repoID)
        #expect(controller.isRepoExpanded(repoID))

        controller.expandRepo(repoID)
        #expect(controller.isRepoExpanded(repoID))

        controller.toggleRepoExpansion(repoID)
        #expect(!controller.isRepoExpanded(repoID))
    }

    @Test("Workspace expansion is ignored when there are no web sources")
    func workspaceExpansionRequiresWebSources() {
        let workspaceID = UUID()
        var controller = SidebarExpansionStateController()

        controller.toggleWorkspaceExpansion(workspaceID, hasWebSources: false)
        #expect(!controller.isWorkspaceExpanded(workspaceID))

        controller.toggleWorkspaceExpansion(workspaceID, hasWebSources: true)
        #expect(controller.isWorkspaceExpanded(workspaceID))

        controller.toggleWorkspaceExpansion(workspaceID, hasWebSources: true)
        #expect(!controller.isWorkspaceExpanded(workspaceID))
    }

    @Test("Fixture initialization expands all repos only once")
    func fixtureInitializationExpandsAllReposOnce() {
        let repoA = UUID()
        let repoB = UUID()
        let repoC = UUID()
        var controller = SidebarExpansionStateController()

        controller.initializeRepoExpansionIfNeeded(
            repoIDs: [repoA, repoB],
            selectedWorkspaceRepoID: nil,
            isUIFixtureMode: true
        )

        #expect(controller.didInitializeRepoExpansion)
        #expect(controller.isRepoExpanded(repoA))
        #expect(controller.isRepoExpanded(repoB))
        #expect(!controller.isRepoExpanded(repoC))

        controller.initializeRepoExpansionIfNeeded(
            repoIDs: [repoC],
            selectedWorkspaceRepoID: nil,
            isUIFixtureMode: true
        )

        #expect(controller.isRepoExpanded(repoA))
        #expect(controller.isRepoExpanded(repoB))
        #expect(!controller.isRepoExpanded(repoC))
    }

    @Test("Normal initialization expands the selected workspace repo")
    func normalInitializationExpandsSelectedWorkspaceRepo() {
        let selectedRepoID = UUID()
        let otherRepoID = UUID()
        var controller = SidebarExpansionStateController()

        controller.initializeRepoExpansionIfNeeded(
            repoIDs: [selectedRepoID, otherRepoID],
            selectedWorkspaceRepoID: selectedRepoID,
            isUIFixtureMode: false
        )

        #expect(controller.isRepoExpanded(selectedRepoID))
        #expect(!controller.isRepoExpanded(otherRepoID))
    }

    @Test("Selected workspace expands its repo and only expands workspace when web sources exist")
    func selectedWorkspaceExpansionRespectsWebSourcePresence() {
        let repoID = UUID()
        let workspaceWithoutSourcesID = UUID()
        let workspaceWithSourcesID = UUID()
        var controller = SidebarExpansionStateController()

        controller.expandSelectedWorkspace(
            workspaceID: workspaceWithoutSourcesID,
            repoID: repoID,
            hasWebSources: false
        )

        #expect(controller.isRepoExpanded(repoID))
        #expect(!controller.isWorkspaceExpanded(workspaceWithoutSourcesID))

        controller.expandSelectedWorkspace(
            workspaceID: workspaceWithSourcesID,
            repoID: repoID,
            hasWebSources: true
        )

        #expect(controller.isWorkspaceExpanded(workspaceWithSourcesID))
    }

    @Test("Selected web source expands both owner containers when present")
    func selectedWebSourceExpandsOwnerContainers() {
        let repoID = UUID()
        let workspaceID = UUID()
        var controller = SidebarExpansionStateController()

        controller.expandSelectedWebSource(repoID: repoID, workspaceID: workspaceID)

        #expect(controller.isRepoExpanded(repoID))
        #expect(controller.isWorkspaceExpanded(workspaceID))
    }

    @Test("Pruning removes stale repo and workspace expansion IDs")
    func pruningRemovesStaleExpansionIDs() {
        let currentRepoID = UUID()
        let staleRepoID = UUID()
        let currentWorkspaceID = UUID()
        let staleWorkspaceID = UUID()
        var controller = SidebarExpansionStateController()

        controller.expandRepo(currentRepoID)
        controller.expandRepo(staleRepoID)
        controller.expandSelectedWebSource(repoID: nil, workspaceID: currentWorkspaceID)
        controller.expandSelectedWebSource(repoID: nil, workspaceID: staleWorkspaceID)

        controller.prune(
            validRepoIDs: [currentRepoID],
            validWorkspaceIDs: [currentWorkspaceID]
        )

        #expect(controller.isRepoExpanded(currentRepoID))
        #expect(!controller.isRepoExpanded(staleRepoID))
        #expect(controller.isWorkspaceExpanded(currentWorkspaceID))
        #expect(!controller.isWorkspaceExpanded(staleWorkspaceID))
    }
}

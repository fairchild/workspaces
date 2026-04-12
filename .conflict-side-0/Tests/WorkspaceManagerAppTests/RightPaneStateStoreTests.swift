import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("RightPaneStateStore")
struct RightPaneStateStoreTests {
    @Test("Same target preserves state across repeated access")
    func sameTargetPreservesStateAcrossRepeatedAccess() {
        let store = RightPaneStateStore()

        let initial = store.state(for: "workspace-test")
        initial.selectedTab = .changes
        initial.expandedDirectoryPaths = ["src", "Tests"]

        let repeated = store.state(for: "workspace-test")

        #expect(initial === repeated)
        #expect(repeated.selectedTab == .changes)
        #expect(repeated.expandedDirectoryPaths == ["src", "Tests"])
    }

    @Test("Different targets maintain distinct state")
    func differentTargetsMaintainDistinctState() {
        let store = RightPaneStateStore()

        let repoState = store.state(for: "repo-a")
        let workspaceState = store.state(for: "workspace-b")
        repoState.selectedTab = .changes

        #expect(repoState !== workspaceState)
        #expect(workspaceState.selectedTab == .files)
    }

    @Test("Prune removes stale targets and keeps valid ones")
    func pruneRemovesStaleTargetsAndKeepsValidOnes() {
        let store = RightPaneStateStore()

        let kept = store.state(for: "workspace-keep")
        let stale = store.state(for: "workspace-stale")
        kept.expandedDirectoryPaths = ["src"]
        stale.selectedTab = .changes

        store.prune(keeping: ["workspace-keep"])

        let keptAgain = store.state(for: "workspace-keep")
        let staleAgain = store.state(for: "workspace-stale")

        #expect(keptAgain === kept)
        #expect(keptAgain.expandedDirectoryPaths == ["src"])
        #expect(staleAgain !== stale)
        #expect(staleAgain.selectedTab == .files)
    }
}

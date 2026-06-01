import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarWorkspaceController")
struct SidebarViewTests {
    @Test("Preferred repo favors selected workspace source repo")
    func preferredRepoFavorsSelectedWorkspaceSourceRepo() throws {
        let repoA = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let repoB = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))
        let workspace = Workspace(
            name: "feature",
            path: URL(fileURLWithPath: "/tmp/workspaces/beta/feature"),
            sourceRepo: repoB
        )
        repoB.workspaces = [workspace]

        let preferredRepo = SidebarWorkspaceController.preferredRepoForNewWorkspace(
            selectedWorkspace: workspace,
            activeSessionKey: .repoPath(repoA.localURL.path),
            repos: [repoA, repoB],
            normalizeRepoPath: { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )

        #expect(preferredRepo?.id == repoB.id)
    }

    @Test("Preferred repo matches active repo session before falling back")
    func preferredRepoMatchesActiveRepoSessionBeforeFallback() throws {
        let repoA = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let repoB = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let preferredRepo = SidebarWorkspaceController.preferredRepoForNewWorkspace(
            selectedWorkspace: nil,
            activeSessionKey: .repoPath(repoB.localURL.path),
            repos: [repoA, repoB],
            normalizeRepoPath: { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )

        #expect(preferredRepo?.id == repoB.id)
    }

    @Test("Preferred repo falls back to first repo when nothing is selected")
    func preferredRepoFallsBackToFirstRepo() throws {
        let repoA = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let repoB = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let preferredRepo = SidebarWorkspaceController.preferredRepoForNewWorkspace(
            selectedWorkspace: nil,
            activeSessionKey: .defaultHome,
            repos: [repoA, repoB],
            normalizeRepoPath: { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )

        #expect(preferredRepo?.id == repoA.id)
    }

    @Test("Preferred repo ignores backend sessions and falls back")
    func preferredRepoIgnoresBackendSession() throws {
        let repoA = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let repoB = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let preferredRepo = SidebarWorkspaceController.preferredRepoForNewWorkspace(
            selectedWorkspace: nil,
            activeSessionKey: .backendSession(providerID: "lume", instanceID: "vm-123"),
            repos: [repoA, repoB],
            normalizeRepoPath: { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        )

        #expect(preferredRepo?.id == repoA.id)
    }

    @Test("Local creation message matches progress phase")
    func localCreationMessageMatchesPhase() {
        #expect(SidebarWorkspaceController.localCreationMessage(for: .preparing) == "Preparing workspace...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .creatingWorktree) == "Creating git worktree...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .runningSetupScript) == "Running setup script...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .finished) == "Finishing workspace...")
    }
}

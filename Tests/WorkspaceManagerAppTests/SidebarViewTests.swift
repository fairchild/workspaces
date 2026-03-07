import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarWorkspaceController")
struct SidebarViewTests {
    private struct CleanupError: LocalizedError {
        var errorDescription: String? { "cleanup failed" }
    }

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

    @Test("Remote cleanup helper returns nil after successful delete")
    func remoteCleanupHelperReturnsNilAfterSuccessfulDelete() async throws {
        let sandboxID = "sandbox-123"
        let recordedSandboxID = LockedBox<String?>(nil)

        let cleanupError = await SidebarWorkspaceController.cleanupRemoteSandboxAfterFailedPersistence(
            sandboxId: sandboxID,
            deleteSandbox: { requestedSandboxID in
                await recordedSandboxID.set(requestedSandboxID)
            }
        )

        #expect(cleanupError == nil)
        #expect(await recordedSandboxID.value == sandboxID)
    }

    @Test("Remote cleanup helper returns thrown delete error")
    func remoteCleanupHelperReturnsThrownDeleteError() async throws {
        let cleanupError = await SidebarWorkspaceController.cleanupRemoteSandboxAfterFailedPersistence(
            sandboxId: "sandbox-123",
            deleteSandbox: { _ in
                throw CleanupError()
            }
        )

        #expect(cleanupError is CleanupError)
    }

    @Test("Remote cleanup message appends cleanup failure to existing persistence error")
    func remoteCleanupMessageAppendsCleanupFailure() {
        let message = SidebarWorkspaceController.remoteWorkspacePersistenceFailureMessage(
            existingMessage: "Failed to save remote workspace: write failed",
            sandboxId: "sandbox-123",
            cleanupError: CleanupError()
        )

        #expect(message.contains("Failed to save remote workspace: write failed"))
        #expect(message.contains("Cleanup also failed for remote sandbox 'sandbox-123': cleanup failed"))
    }

    @Test("Local creation message matches progress phase")
    func localCreationMessageMatchesPhase() {
        #expect(SidebarWorkspaceController.localCreationMessage(for: .preparing) == "Preparing workspace...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .copyingRepository) == "Copying repository...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .creatingBranch) == "Creating branch...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .runningSetupScript) == "Running setup script...")
        #expect(SidebarWorkspaceController.localCreationMessage(for: .finished) == "Finishing workspace...")
    }
}

private actor LockedBox<Value: Sendable> {
    private var storage: Value

    init(_ storage: Value) {
        self.storage = storage
    }

    func set(_ newValue: Value) {
        storage = newValue
    }

    var value: Value {
        storage
    }
}

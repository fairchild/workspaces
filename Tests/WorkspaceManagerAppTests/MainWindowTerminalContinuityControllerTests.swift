//
//  MainWindowTerminalContinuityControllerTests.swift
//  WorkspaceManagerAppTests
//
//  What the continuity manifest records and what it deliberately leaves out: a selection's
//  launch directory survives to the next run, and an archived workspace's terminal scope does not.
//

// swift-format-ignore-file: NeverForceUnwrap
// Fixtures force-unwrap known-good literals; a failure here is a loud test crash, not a user risk.
import Foundation
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
private final class ManifestBox {
    var rawValue = ""
}

@MainActor
@Suite("MainWindowTerminalContinuityController")
struct MainWindowTerminalContinuityControllerTests {
    private func makeController(
        box: ManifestBox,
        repos: [Repo] = [],
        tileTreeStore: TileTreeStore? = nil
    ) -> MainWindowTerminalContinuityController {
        MainWindowTerminalContinuityController(
            dependencies: MainWindowTerminalContinuityController.Dependencies(
                manifestRawValue: Binding(get: { box.rawValue }, set: { box.rawValue = $0 }),
                repos: { repos },
                tileTreeStore: tileTreeStore ?? TileTreeStore(),
                providerRegistry: WorkspaceProviderRegistry(providers: []),
                terminalMode: { .tmuxPerSession },
                defaultHomeURL: URL(fileURLWithPath: "/tmp/home")
            )
        )
    }

    /// The manifest only answers with directories that still exist, so round-trip tests need real ones.
    private func makeDirectory(_ components: String...) throws -> URL {
        var url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-\(UUID().uuidString)", isDirectory: true)
        for component in components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    @Test("A persisted repo selection restores its launch directory on the next run")
    func repoLaunchDirectoryRoundTrips() throws {
        let box = ManifestBox()
        let repoRoot = try makeDirectory("alpha")
        let launch = repoRoot.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let controller = makeController(box: box, repos: [repo])

        controller.persist(targetKind: .repo, targetID: repo.id, rootURL: repoRoot, launchURL: launch)

        #expect(!box.rawValue.isEmpty)
        #expect(controller.restoredLaunchDirectory(for: repo)?.path == launch.path)
    }

    @Test("A launch directory that no longer exists degrades to the recorded root")
    func staleLaunchDirectoryDegradesToRoot() throws {
        let box = ManifestBox()
        let repoRoot = try makeDirectory("alpha")
        let stale = repoRoot.appendingPathComponent("deleted", isDirectory: true)
        let repo = Repo(name: "alpha", localPath: repoRoot)
        let controller = makeController(box: box, repos: [repo])

        controller.persist(targetKind: .repo, targetID: repo.id, rootURL: repoRoot, launchURL: stale)

        #expect(controller.restoredLaunchDirectory(for: repo)?.path == repoRoot.path)
    }

    @Test("A repo's manifest does not answer for a different repo")
    func launchDirectoryIsScopedToItsTarget() throws {
        let box = ManifestBox()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let other = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))
        let controller = makeController(box: box, repos: [repo, other])

        controller.persist(
            targetKind: .repo,
            targetID: repo.id,
            rootURL: repo.localURL,
            launchURL: repo.localURL
        )

        #expect(controller.restoredLaunchDirectory(for: other) == nil)
    }

    @Test("A remote workspace has no restorable local launch directory")
    func remoteWorkspaceHasNoLaunchDirectory() throws {
        let box = ManifestBox()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "remote",
            path: URL(fileURLWithPath: "/tmp/alpha/remote"),
            sourceRepo: repo,
            backendIdentifier: "daytona"
        )
        let controller = makeController(box: box, repos: [repo])

        controller.persist(
            targetKind: .workspace,
            targetID: workspace.id,
            rootURL: workspace.workspaceURL,
            launchURL: workspace.workspaceURL
        )

        #expect(controller.restoredLaunchDirectory(for: workspace) == nil)
    }

    @Test("Archived local workspaces contribute their terminal scope, active ones do not")
    func archivedScopeKeysCoverOnlyArchivedWorkspaces() throws {
        let box = ManifestBox()
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let active = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/feature-a"),
            sourceRepo: repo
        )
        let archived = Workspace(
            name: "old",
            path: URL(fileURLWithPath: "/tmp/alpha/old"),
            sourceRepo: repo,
            status: .archived
        )
        repo.workspaces = [active, archived]
        let controller = makeController(box: box, repos: [repo])

        let keys = controller.archivedWorkspaceScopeKeys

        #expect(keys.contains(.hostPath(MainWindowPathResolution.normalize(archived.workspaceURL.path))))
        #expect(!keys.contains(.hostPath(MainWindowPathResolution.normalize(active.workspaceURL.path))))
    }

    @Test("A snapshot without a prior manifest still records the current session set")
    func snapshotWritesWithoutPriorManifest() throws {
        let box = ManifestBox()
        let controller = makeController(box: box)

        controller.persistSnapshot()

        #expect(!box.rawValue.isEmpty)
    }
}

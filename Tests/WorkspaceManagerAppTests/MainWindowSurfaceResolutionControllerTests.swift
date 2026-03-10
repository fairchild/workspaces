import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowSurfaceResolutionController")
struct MainWindowSurfaceResolutionControllerTests {
    private let controller = MainWindowSurfaceResolutionController()

    @Test("Deep link resolution takes precedence over perf auto-select and restore")
    func deepLinkTakesPrecedence() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]
        let deepLink = makeDeepLink(cwd: "/tmp/alpha/workspaces/feature-a/Sources/App/main.swift")
        let savedSurface = MainWindowLastSurface(kind: .repoOverview, id: repo.id)

        let action = controller.nextAction(
            context: MainWindowSurfaceResolutionContext(
                environment: ["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1"],
                didRunPerfAutoSelection: false,
                didApplyFixturePreviewBootstrap: false,
                didApplyFixtureWebBootstrap: false,
                didResolveInitialSurface: false,
                pendingRequest: deepLink,
                lastSurfaceRawValue: savedSurface.rawValue,
                previewConfiguration: nil,
                webConfiguration: nil,
                repos: [repo],
                webSources: []
            )
        )

        switch action {
        case .selectDeepLinkedWorkspace(let request, let selectedWorkspace):
            #expect(request == deepLink)
            #expect(selectedWorkspace.id == workspace.id)
        default:
            Issue.record("Expected deep link resolution to take precedence")
        }
    }

    @Test("Resolved initial surface blocks later launch-resolution actions")
    func resolvedInitialSurfaceBlocksLaterActions() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let savedSurface = MainWindowLastSurface(kind: .repoOverview, id: repo.id)

        let action = controller.nextAction(
            context: MainWindowSurfaceResolutionContext(
                environment: ["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1"],
                didRunPerfAutoSelection: false,
                didApplyFixturePreviewBootstrap: false,
                didApplyFixtureWebBootstrap: false,
                didResolveInitialSurface: true,
                pendingRequest: nil,
                lastSurfaceRawValue: savedSurface.rawValue,
                previewConfiguration: nil,
                webConfiguration: nil,
                repos: [repo],
                webSources: []
            )
        )

        switch action {
        case .none:
            _ = Bool(true)
        default:
            Issue.record("Expected no further launch-resolution action after the surface is resolved")
        }
    }

    @Test("Invalid stored surface clears before fallback")
    func invalidStoredSurfaceClearsFirst() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let invalidSurface = MainWindowLastSurface(kind: .repoTerminal, id: UUID())

        let action = controller.nextAction(
            context: MainWindowSurfaceResolutionContext(
                environment: [:],
                didRunPerfAutoSelection: false,
                didApplyFixturePreviewBootstrap: false,
                didApplyFixtureWebBootstrap: false,
                didResolveInitialSurface: false,
                pendingRequest: nil,
                lastSurfaceRawValue: invalidSurface.rawValue,
                previewConfiguration: nil,
                webConfiguration: nil,
                repos: [repo],
                webSources: []
            )
        )

        switch action {
        case .clearInvalidLastSurface:
            _ = Bool(true)
        default:
            Issue.record("Expected invalid stored surface to be cleared before fallback")
        }
    }

    @Test("Preview bootstrap is preferred over restore when unresolved")
    func previewBootstrapPrecedesRestore() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let repo = try makeRepo(name: "skills", at: fixtureRoot, fileManager: fileManager)
        let readmeURL = repo.localURL.appendingPathComponent("README.md")
        try Data("hello\n".utf8).write(to: readmeURL)
        let savedSurface = MainWindowLastSurface(kind: .repoOverview, id: repo.id)

        let action = controller.nextAction(
            context: MainWindowSurfaceResolutionContext(
                environment: [:],
                didRunPerfAutoSelection: false,
                didApplyFixturePreviewBootstrap: false,
                didApplyFixtureWebBootstrap: false,
                didResolveInitialSurface: false,
                pendingRequest: nil,
                lastSurfaceRawValue: savedSurface.rawValue,
                previewConfiguration: UIFixturePreviewBootstrapConfiguration(
                    repoName: "skills",
                    relativePath: "README.md"
                ),
                webConfiguration: nil,
                repos: [repo],
                webSources: []
            )
        )

        switch action {
        case .applyPreviewBootstrap(let configuration, let selectedRepo, let selection):
            #expect(configuration.repoName == "skills")
            #expect(selectedRepo.id == repo.id)
            #expect(selection.relativePath == "README.md")
        default:
            Issue.record("Expected preview bootstrap to run before restore")
        }
    }

    private func makeFixtureRoot(fileManager: FileManager) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wm-surface-resolution-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRepo(
        name: String,
        at root: URL,
        fileManager: FileManager
    ) throws -> Repo {
        let repoURL = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)
        return Repo(name: name, localPath: repoURL)
    }

    private func makeDeepLink(cwd: String) -> WorkspaceDeepLink {
        let encodedCWD = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "workspaces://focus?cwd=\(encodedCWD)")!
        return WorkspaceDeepLink(url: url)!
    }
}

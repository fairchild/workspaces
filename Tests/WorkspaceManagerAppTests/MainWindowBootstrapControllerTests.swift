import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowBootstrapController")
struct MainWindowBootstrapControllerTests {
    private let controller = MainWindowBootstrapController()

    @Test("Deep link waits for repos during cold launch")
    func deepLinkWaitsForRepos() {
        let request = makeDeepLink(cwd: "/tmp/project/workspace")
        let decision = controller.deepLinkDecision(
            pendingRequest: request,
            repos: [],
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )

        switch decision {
        case .waitForRepos(let pendingRequest):
            #expect(pendingRequest == request)
        default:
            Issue.record("Expected deep link decision to wait for repos")
        }
    }

    @Test("Deep link selects matching workspace once repos are loaded")
    func deepLinkSelectsMatchingWorkspace() {
        let repo = Repo(name: "app", localPath: URL(fileURLWithPath: "/tmp/app"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/app/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]

        let request = makeDeepLink(cwd: "/tmp/app/workspaces/feature-a/Sources/App/main.swift")
        let decision = controller.deepLinkDecision(
            pendingRequest: request,
            repos: [repo],
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )

        switch decision {
        case .selectWorkspace(let pendingRequest, let matchedWorkspace):
            #expect(pendingRequest == request)
            #expect(matchedWorkspace.id == workspace.id)
        default:
            Issue.record("Expected deep link decision to select workspace")
        }
    }

    @Test("Deep link selects matching repo when cwd is inside repo root")
    func deepLinkSelectsMatchingRepo() {
        let repo = Repo(name: "app", localPath: URL(fileURLWithPath: "/tmp/app"))
        let request = makeDeepLink(
            cwd: "/tmp/app/Sources/App",
            repoRoot: "/tmp/app"
        )

        let decision = controller.deepLinkDecision(
            pendingRequest: request,
            repos: [repo],
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )

        switch decision {
        case .selectRepo(let pendingRequest, let matchedRepo):
            #expect(pendingRequest == request)
            #expect(matchedRepo.id == repo.id)
        default:
            Issue.record("Expected deep link decision to select repo")
        }
    }

    @Test("Deep link requests repo import when repo root is not tracked")
    func deepLinkRequestsRepoImportForUntrackedRepo() {
        let request = makeDeepLink(
            cwd: "/tmp/app/Sources/App",
            repoRoot: "/tmp/app"
        )

        let decision = controller.deepLinkDecision(
            pendingRequest: request,
            repos: [],
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )

        switch decision {
        case .importRepo(let pendingRequest, let repoRoot):
            #expect(pendingRequest == request)
            #expect(repoRoot == "/tmp/app")
        default:
            Issue.record("Expected deep link decision to request repo import")
        }
    }

    @Test("Perf auto select returns first repo only when enabled and idle")
    func perfAutoSelectReturnsFirstRepoWhenEnabled() {
        let firstRepo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let secondRepo = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let selectedRepo = controller.perfAutoSelectedRepo(
            environment: ["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1"],
            didRun: false,
            pendingRequest: nil,
            repos: [firstRepo, secondRepo]
        )
        #expect(selectedRepo?.id == firstRepo.id)

        let skippedBecausePendingDeepLink = controller.perfAutoSelectedRepo(
            environment: ["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1"],
            didRun: false,
            pendingRequest: makeDeepLink(cwd: "/tmp/alpha"),
            repos: [firstRepo, secondRepo]
        )
        #expect(skippedBecausePendingDeepLink == nil)
    }

    @Test("Perf auto select can target a specific repo path")
    func perfAutoSelectCanTargetSpecificRepoPath() {
        let firstRepo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let secondRepo = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let selectedRepo = controller.perfAutoSelectedRepo(
            environment: [
                "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH": "/tmp/beta",
            ],
            didRun: false,
            pendingRequest: nil,
            repos: [firstRepo, secondRepo]
        )
        #expect(selectedRepo?.id == secondRepo.id)
    }

    @Test("Perf auto select waits when requested repo path is not yet available")
    func perfAutoSelectWaitsForRequestedRepoPath() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        #expect(
            controller.shouldWaitForPerfAutoSelectedRepo(
                environment: [
                    "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                    "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH": "/tmp/beta",
                ],
                didRun: false,
                pendingRequest: nil,
                repos: [repo]
            )
        )

        #expect(
            controller.shouldWaitForPerfAutoSelectedRepo(
                environment: [
                    "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                    "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH": "/tmp/alpha",
                ],
                didRun: false,
                pendingRequest: nil,
                repos: [repo]
            ) == false
        )
    }

    @Test("Perf auto open New Workspace is gated behind both perf flags and idle state")
    func perfAutoOpenNewWorkspaceHonorsFlags() {
        #expect(
            controller.shouldPerfAutoOpenNewWorkspace(
                environment: ["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1"],
                didRun: false,
                pendingRequest: nil
            ) == false
        )

        #expect(
            controller.shouldPerfAutoOpenNewWorkspace(
                environment: [
                    "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                    "WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE": "1",
                ],
                didRun: false,
                pendingRequest: nil
            ) == true
        )

        #expect(
            controller.shouldPerfAutoOpenNewWorkspace(
                environment: [
                    "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                    "WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE": "1",
                ],
                didRun: true,
                pendingRequest: nil
            ) == false
        )

        #expect(
            controller.shouldPerfAutoOpenNewWorkspace(
                environment: [
                    "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO": "1",
                    "WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE": "1",
                ],
                didRun: false,
                pendingRequest: makeDeepLink(cwd: "/tmp/alpha")
            ) == false
        )
    }

    @Test("Preview bootstrap applies resolved file selection")
    func previewBootstrapAppliesResolvedSelection() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let repo = try makeRepo(name: "skills", at: fixtureRoot, fileManager: fileManager)
        let readmeURL = repo.localURL.appendingPathComponent("README.md")
        try Data("hello\n".utf8).write(to: readmeURL)

        let decision = controller.previewBootstrapDecision(
            didApply: false,
            pendingRequest: nil,
            configuration: UIFixturePreviewBootstrapConfiguration(
                repoName: "skills",
                relativePath: "README.md"
            ),
            repos: [repo]
        )

        switch decision {
        case .apply(let configuration, let resolvedRepo, let selection):
            #expect(configuration.repoName == "skills")
            #expect(resolvedRepo.id == repo.id)
            #expect(selection.relativePath == "README.md")
        default:
            Issue.record("Expected preview bootstrap decision to apply")
        }
    }

    @Test("Preview bootstrap records no match when file is missing")
    func previewBootstrapRecordsNoMatch() throws {
        let fileManager = FileManager.default
        let fixtureRoot = try makeFixtureRoot(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        let repo = try makeRepo(name: "skills", at: fixtureRoot, fileManager: fileManager)
        let configuration = UIFixturePreviewBootstrapConfiguration(
            repoName: "skills",
            relativePath: "README.md"
        )

        let decision = controller.previewBootstrapDecision(
            didApply: false,
            pendingRequest: nil,
            configuration: configuration,
            repos: [repo]
        )

        switch decision {
        case .noMatch(let missingConfiguration):
            #expect(missingConfiguration == configuration)
        default:
            Issue.record("Expected preview bootstrap decision to report no match")
        }
    }

    @Test("Web bootstrap prefers exact matches before partial fallback")
    func webBootstrapPrefersExactMatches() {
        let exact = WebSource(
            name: "Swift Docs",
            baseURLString: "https://docs.swift.org",
            allowedHost: "docs.swift.org"
        )
        let partial = WebSource(
            name: "Swift Docs Mirror",
            baseURLString: "https://example.com/swift",
            allowedHost: "example.com"
        )

        let decision = controller.webBootstrapDecision(
            didApply: false,
            pendingRequest: nil,
            configuration: UIFixtureWebBootstrapConfiguration(webSourceName: "Swift Docs"),
            webSources: [partial, exact]
        )

        switch decision {
        case .select(let targetName, let selectedSource):
            #expect(targetName == "Swift Docs")
            #expect(selectedSource.id == exact.id)
        default:
            Issue.record("Expected web bootstrap decision to select an exact match")
        }
    }

    @Test("Restored surface selects repo terminal by stored repo id")
    func restoredSurfaceSelectsRepoTerminal() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let saved = MainWindowLastSurface(kind: .repoTerminal, id: repo.id)

        let decision = controller.restoredSurfaceDecision(
            rawValue: saved.rawValue,
            repos: [repo],
            webSources: []
        )

        switch decision {
        case .select(.repoTerminal(let restoredRepo)):
            #expect(restoredRepo.id == repo.id)
        default:
            Issue.record("Expected restored surface decision to select the repo terminal")
        }
    }

    @Test("Restored surface selects scoped web view by stored id")
    func restoredSurfaceSelectsScopedWebView() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            sourceWorkspace: workspace
        )
        let saved = MainWindowLastSurface(kind: .webView, id: source.id)

        let decision = controller.restoredSurfaceDecision(
            rawValue: saved.rawValue,
            repos: [repo],
            webSources: [source]
        )

        switch decision {
        case .select(.webView(let restoredSource)):
            #expect(restoredSource.id == source.id)
        default:
            Issue.record("Expected restored surface decision to select the web view")
        }
    }

    @Test("Restored surface clears invalid targets")
    func restoredSurfaceClearsInvalidTargets() {
        let saved = MainWindowLastSurface(kind: .repoOverview, id: UUID())

        let decision = controller.restoredSurfaceDecision(
            rawValue: saved.rawValue,
            repos: [],
            webSources: []
        )

        switch decision {
        case .clearInvalid:
            _ = Bool(true)
        default:
            Issue.record("Expected restored surface decision to clear invalid state")
        }
    }

    @Test("Sanitized last surface clears invalid stored targets")
    func sanitizedLastSurfaceClearsInvalidTarget() {
        let saved = MainWindowLastSurface(kind: .repoTerminal, id: UUID())

        let sanitized = controller.sanitizedLastSurfaceRawValue(
            rawValue: saved.rawValue,
            repos: [],
            webSources: []
        )

        #expect(sanitized.isEmpty)
    }

    @Test("Fallback prefers most recent workspace before web or repo")
    func fallbackPrefersMostRecentWorkspace() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let olderWorkspace = Workspace(
            name: "older",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/older"),
            sourceRepo: repo,
            lastAccessedAt: Date(timeIntervalSince1970: 10)
        )
        let newerWorkspace = Workspace(
            name: "newer",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/newer"),
            sourceRepo: repo,
            lastAccessedAt: Date(timeIntervalSince1970: 20)
        )
        repo.workspaces = [olderWorkspace, newerWorkspace]

        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            lastAccessedAt: Date(timeIntervalSince1970: 30)
        )

        let fallback = controller.fallbackSurface(
            repos: [repo],
            webSources: [source]
        )

        switch fallback {
        case .workspace(let workspace):
            #expect(workspace.id == newerWorkspace.id)
        default:
            Issue.record("Expected fallback to prefer the most recent workspace")
        }
    }

    @Test("Fallback prefers most recent web view before first repo when no workspace exists")
    func fallbackPrefersWebViewBeforeRepo() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com",
            lastAccessedAt: Date(timeIntervalSince1970: 30)
        )

        let fallback = controller.fallbackSurface(
            repos: [repo],
            webSources: [source]
        )

        switch fallback {
        case .webView(let selectedSource):
            #expect(selectedSource.id == source.id)
        default:
            Issue.record("Expected fallback to prefer a recent web view")
        }
    }

    @Test("Non-web fallback prefers most recent workspace before repo overview")
    func nonWebFallbackPrefersWorkspace() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "newer",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/newer"),
            sourceRepo: repo,
            lastAccessedAt: Date(timeIntervalSince1970: 20)
        )
        repo.workspaces = [workspace]

        let fallback = controller.nonWebFallbackSurface(repos: [repo])

        switch fallback {
        case .workspace(let selectedWorkspace):
            #expect(selectedWorkspace.id == workspace.id)
        default:
            Issue.record("Expected non-web fallback to prefer the most recent workspace")
        }
    }

    @Test("Removing selected workspace falls back to its repo overview when repo remains")
    func removingSelectedWorkspaceFallsBackToRepoOverview() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        let fallback = controller.fallbackSurfaceAfterRemovingWorkspace(
            repoID: repo.id,
            repos: [repo],
            webSources: []
        )

        switch fallback {
        case .repoOverview(let selectedRepo):
            #expect(selectedRepo.id == repo.id)
        default:
            Issue.record("Expected workspace removal to fall back to the owning repo overview")
        }
    }

    @Test("Removing selected workspace falls back to general surface when repo is gone")
    func removingSelectedWorkspaceFallsBackWhenRepoIsGone() {
        let fallback = controller.fallbackSurfaceAfterRemovingWorkspace(
            repoID: UUID(),
            repos: [],
            webSources: []
        )

        switch fallback {
        case nil:
            _ = Bool(true)
        default:
            Issue.record("Expected workspace removal without a repo to clear back to no surface")
        }
    }

    @Test("Removing workspace-owned web view falls back to its workspace")
    func removingWorkspaceOwnedWebViewFallsBackToWorkspace() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        repo.workspaces = [workspace]

        let fallback = controller.fallbackSurfaceAfterRemovingWebSource(
            ownerWorkspaceID: workspace.id,
            ownerRepoID: repo.id,
            repos: [repo]
        )

        switch fallback {
        case .workspace(let selectedWorkspace):
            #expect(selectedWorkspace.id == workspace.id)
        default:
            Issue.record("Expected workspace-owned web view removal to return to the workspace")
        }
    }

    @Test("Removing repo-owned web view falls back to its repo overview")
    func removingRepoOwnedWebViewFallsBackToRepoOverview() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        let fallback = controller.fallbackSurfaceAfterRemovingWebSource(
            ownerWorkspaceID: nil,
            ownerRepoID: repo.id,
            repos: [repo]
        )

        switch fallback {
        case .repoOverview(let selectedRepo):
            #expect(selectedRepo.id == repo.id)
        default:
            Issue.record("Expected repo-owned web view removal to return to the repo overview")
        }
    }

    private func makeFixtureRoot(fileManager: FileManager) throws -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wm-main-window-bootstrap-\(UUID().uuidString)", isDirectory: true)
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

    private func makeDeepLink(cwd: String, repoRoot: String? = nil) -> WorkspaceDeepLink {
        let encodedCWD = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let encodedRepoRoot = repoRoot?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        let repoRootQuery = encodedRepoRoot.map { "&repo_root=\($0)" } ?? ""
        let url = URL(string: "workspaces://focus?cwd=\(encodedCWD)\(repoRootQuery)")!
        return WorkspaceDeepLink(url: url)!
    }

    private func normalizePath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}

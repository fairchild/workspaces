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
        case .select(let pendingRequest, let matchedWorkspace):
            #expect(pendingRequest == request)
            #expect(matchedWorkspace.id == workspace.id)
        default:
            Issue.record("Expected deep link decision to select workspace")
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

    private func makeDeepLink(cwd: String) -> WorkspaceDeepLink {
        let encodedCWD = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "workspaces://focus?cwd=\(encodedCWD)")!
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

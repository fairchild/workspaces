import Foundation
import WorkspaceManagerCore

struct UIFixturePreviewBootstrapConfiguration: Equatable, Sendable {
    let repoName: String
    let relativePath: String

    static func from(environment: [String: String]) -> Self? {
        guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
        guard environment["WORKSPACES_UI_FIXTURE_OPEN_PREVIEW"] == "1" else { return nil }

        let repoName = normalizedValue(environment["WORKSPACES_UI_FIXTURE_PREVIEW_REPO"]) ?? "skills"
        let relativePath = normalizedValue(environment["WORKSPACES_UI_FIXTURE_PREVIEW_PATH"]) ?? "README.md"
        guard !relativePath.isEmpty else { return nil }

        return Self(
            repoName: repoName,
            relativePath: relativePath
        )
    }

    private static func normalizedValue(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum UIFixturePreviewBootstrap {
    static func resolveSelection(
        configuration: UIFixturePreviewBootstrapConfiguration,
        repos: [Repo],
        fileManager: FileManager = .default
    ) -> (repo: Repo, selection: CodePreviewSelection)? {
        guard let firstRepo = repos.first else { return nil }

        let repo =
            repos.first(where: { $0.name.caseInsensitiveCompare(configuration.repoName) == .orderedSame })
            ?? firstRepo

        let rootURL = repo.localURL
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let fileURL = rootURL
            .appendingPathComponent(configuration.relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard path(fileURL.path, isInside: rootURL.path) else {
            return nil
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return nil
        }

        let relativePath = String(fileURL.path.dropFirst(rootURL.path.count + 1))
        let selection = CodePreviewSelection(
            rootURL: rootURL,
            relativePath: relativePath
        )
        return (repo: repo, selection: selection)
    }

    private static func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}

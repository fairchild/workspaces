import Foundation

struct WorkspaceDeepLink: Equatable {
    let cwd: String
    let repoRoot: String?
    let sessionID: String?
    let source: String?

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "workspaces",
            components.host?.lowercased() == "focus"
        else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        guard let rawCWD = queryItems.first(where: { $0.name == "cwd" })?.value,
            !rawCWD.isEmpty
        else {
            return nil
        }

        guard Self.isAbsolutePathInput(rawCWD) else { return nil }
        let normalizedCWD = Self.normalizePath(rawCWD)
        guard normalizedCWD.hasPrefix("/") else { return nil }

        cwd = normalizedCWD
        if let rawRepoRoot = queryItems.first(where: { $0.name == "repo_root" })?.value,
            !rawRepoRoot.isEmpty,
            Self.isAbsolutePathInput(rawRepoRoot)
        {
            let normalizedRepoRoot = Self.normalizePath(rawRepoRoot)
            repoRoot = normalizedRepoRoot.hasPrefix("/") ? normalizedRepoRoot : nil
        } else {
            repoRoot = nil
        }
        sessionID = queryItems.first(where: { $0.name == "session_id" })?.value
        source = queryItems.first(where: { $0.name == "source" })?.value
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func isAbsolutePathInput(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~")
    }
}

struct WorkspaceDeepLinkState: Equatable {
    var pendingRequest: WorkspaceDeepLink?

    @discardableResult
    mutating func enqueue(url: URL) -> Bool {
        guard let request = WorkspaceDeepLink(url: url) else { return false }
        pendingRequest = request
        return true
    }

    mutating func clearPendingRequest() {
        pendingRequest = nil
    }
}

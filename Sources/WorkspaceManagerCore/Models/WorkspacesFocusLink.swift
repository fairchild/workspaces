import Foundation

public struct WorkspacesFocusLink: Equatable, Sendable {
    public let cwd: String
    public let repoRoot: String?
    public let source: String?

    public init(cwd: String, repoRoot: String? = nil, source: String? = nil) {
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.source = source
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "workspaces"
        components.host = "focus"

        var queryItems = [URLQueryItem(name: "cwd", value: cwd)]
        if let repoRoot {
            queryItems.append(URLQueryItem(name: "repo_root", value: repoRoot))
        }
        if let source {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            preconditionFailure("Failed to build Workspaces focus URL.")
        }
        return url
    }
}

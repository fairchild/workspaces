import Foundation
import WorkspaceManagerCore

enum WebSourceCreationTarget: Identifiable {
    case global
    case repo(Repo)
    case workspace(Workspace)

    var id: String {
        switch self {
        case .global:
            return "global"
        case .repo(let repo):
            return "repo:\(repo.id.uuidString)"
        case .workspace(let workspace):
            return "workspace:\(workspace.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .global:
            return "Add URL Source"
        case .repo, .workspace:
            return "Add Web View"
        }
    }

    var subtitle: String {
        switch self {
        case .global:
            return "Browse a domain inside Workspaces"
        case .repo(let repo):
            return "Attach a web view to \(repo.name)"
        case .workspace(let workspace):
            return "Attach a web view to \(workspace.name)"
        }
    }

    var buttonTitle: String {
        switch self {
        case .global:
            return "Add"
        case .repo, .workspace:
            return "Add Web View"
        }
    }

    var iconName: String {
        "globe.badge.plus"
    }

    var ownershipScope: WebSourceOwnershipScope {
        switch self {
        case .global:
            return .global
        case .repo(let repo):
            return .repo(repo.id)
        case .workspace(let workspace):
            return .workspace(workspace.id)
        }
    }

    var duplicateMessage: String {
        switch self {
        case .global:
            return "That URL source is already in the top-level list."
        case .repo(let repo):
            return "That web view is already attached to '\(repo.name)'."
        case .workspace(let workspace):
            return "That web view is already attached to '\(workspace.name)'."
        }
    }

    var ownerDisplayName: String? {
        switch self {
        case .global:
            return nil
        case .repo(let repo):
            return repo.name
        case .workspace(let workspace):
            return workspace.name
        }
    }
}

enum WebSourceCreationSupport {
    static func normalizedURLString(_ rawURL: String) -> String {
        if let normalized = try? WebSourceValidation.normalizeBaseURL(rawURL) {
            return normalized.baseURL.absoluteString
        }
        return rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func duplicateExists(
        normalizedURL: String,
        target: WebSourceCreationTarget,
        among sources: [WebSource]
    ) -> Bool {
        sources.contains { source in
            self.normalizedURLString(source.baseURLString) == normalizedURL
                && source.ownershipScope == target.ownershipScope
        }
    }

    static func makeSource(
        rawURL: String,
        displayName: String,
        additionalAllowedDomainsRaw: String,
        target: WebSourceCreationTarget,
        existingSources: [WebSource]
    ) throws -> WebSource {
        let normalized = try WebSourceValidation.normalizeBaseURL(rawURL)
        let normalizedURLString = normalized.baseURL.absoluteString
        let parsedAdditionalDomains = try WebSourceValidation.normalizeAdditionalAllowedDomains(
            additionalAllowedDomainsRaw
        )
        let additionalAllowedDomains = parsedAdditionalDomains.filter { domain in
            domain != normalized.allowedHost && domain != "*.\(normalized.allowedHost)"
        }

        if duplicateExists(
            normalizedURL: normalizedURLString,
            target: target,
            among: existingSources
        ) {
            throw WebSourceCreationError.duplicate(target.duplicateMessage)
        }

        let ownership = ownership(target: target)
        return WebSource(
            name: WebSourceValidation.normalizedDisplayName(
                explicitName: displayName,
                baseURL: normalized.baseURL
            ),
            baseURLString: normalizedURLString,
            allowedHost: normalized.allowedHost,
            additionalAllowedDomains: additionalAllowedDomains,
            sourceRepo: ownership.repo,
            sourceWorkspace: ownership.workspace
        )
    }

    private static func ownership(
        target: WebSourceCreationTarget
    ) -> (repo: Repo?, workspace: Workspace?) {
        switch target {
        case .global:
            return (nil, nil)
        case .repo(let repo):
            return (repo, nil)
        case .workspace(let workspace):
            return (nil, workspace)
        }
    }
}

enum WebSourceCreationError: LocalizedError {
    case duplicate(String)

    var errorDescription: String? {
        switch self {
        case .duplicate(let message):
            return message
        }
    }
}

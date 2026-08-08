//
//  CLIPlaneComposer.swift
//  WorkspaceManagerCore
//
//  Composes the CLI's two management planes into one coherent surface: when the running
//  app's operator inventory is reachable, list output derives from the app with
//  CLI-local-only entries labeled, divergence notices explain writes the app cannot see,
//  and workspace tokens resolve against the app as a fallback to the CLI-local store.
//

import Foundation

public enum CLIPlaneComposer {
    /// One CLI-local record row: its display name (`<repo>/<name>` for workspaces, the
    /// repo name for repos) plus its filesystem path, the key both planes share.
    public struct LocalRow: Equatable, Sendable {
        public let displayName: String
        public let path: String

        public init(displayName: String, path: String) {
            self.displayName = displayName
            self.path = path
        }
    }

    /// A workspace resolved from the running app's inventory, carrying enough to act on
    /// locally (spawn a shell at `path`) and to adopt into CLI-local state. `repoName` and
    /// `repoPath` are nil when the app's descriptor has no resolvable repo.
    public struct AppWorkspaceMatch: Equatable, Sendable {
        public let workspaceID: UUID
        public let name: String
        public let repoName: String?
        public let repoPath: String?
        public let path: String
        public let branch: String?

        public init(
            workspaceID: UUID,
            name: String,
            repoName: String?,
            repoPath: String?,
            path: String,
            branch: String?
        ) {
            self.workspaceID = workspaceID
            self.name = name
            self.repoName = repoName
            self.repoPath = repoPath
            self.path = path
            self.branch = branch
        }
    }

    public enum WorkspaceMatchOutcome: Equatable, Sendable {
        case match(AppWorkspaceMatch)
        case ambiguous([String])
        case none
    }

    /// Lines for `ws list`. Without a reachable app the CLI-local rows print in the legacy
    /// bare `name\tpath` format; with one, the app's active workspaces lead (selected row
    /// marked `*`) and CLI-local rows the app cannot see follow under an explicit label.
    public static func workspaceListLines(
        app: AutomationWorkspaceInventory?,
        local: [LocalRow]
    ) -> [String] {
        guard let app else {
            if local.isEmpty {
                return ["No workspaces tracked."]
            }
            return local.map { "\($0.displayName)\t\($0.path)" }
        }

        var lines = ["Workspaces (running app):"]
        let active = app.workspaces.filter { !$0.isArchived }
        if active.isEmpty {
            lines.append("  (none)")
        } else {
            for workspace in active {
                let marker = workspace.isSelected ? "*" : " "
                let branch = workspace.branch ?? "-"
                lines.append("\(marker) \(displayName(for: workspace, in: app))\t\(workspace.path)\t\(branch)")
            }
        }
        // Only the active workspaces count as "the app can see this": a local record whose
        // path matches an *archived* app workspace is still CLI-local as far as the listing
        // above is concerned, so it belongs in the CLI-local section rather than nowhere.
        lines.append(contentsOf: localOnlySection(local: local, appPaths: normalizedPaths(active.map(\.path))))
        return lines
    }

    /// Lines for `repo list`, shaped like `workspaceListLines`. App rows carry the repo id
    /// so a caller can feed `automation workspace create <repo-id> <name>` directly.
    public static func repoListLines(
        app: AutomationWorkspaceInventory?,
        local: [LocalRow]
    ) -> [String] {
        guard let app else {
            if local.isEmpty {
                return ["No repositories tracked."]
            }
            return local.map { "\($0.displayName)\t\($0.path)" }
        }

        var lines = ["Repos (running app):"]
        if app.repos.isEmpty {
            lines.append("  (none)")
        } else {
            for repo in app.repos {
                let marker = repo.isSelected ? "*" : " "
                lines.append("\(marker) \(repo.name)\t\(repo.path)\t\(repo.repoID.uuidString)")
            }
        }
        lines.append(contentsOf: localOnlySection(local: local, appPaths: normalizedPaths(app.repos.map(\.path))))
        return lines
    }

    /// A stderr notice for `repo add` when the app is running but does not track the added
    /// path — the write only landed on the CLI-local plane. Nil when the app tracks it.
    public static func repoAddNotice(app: AutomationWorkspaceInventory, addedRepoPath: String) -> String? {
        let normalizedAdded = CLIPathNormalizer.normalized(addedRepoPath)
        guard !app.repos.contains(where: { CLIPathNormalizer.normalized($0.path) == normalizedAdded }) else {
            return nil
        }
        return "note: the running app does not track this repo; 'repo add' registered it for the "
            + "CLI-local (appless) plane only. Open it in the app ('workspaces \(addedRepoPath)') "
            + "to register it there."
    }

    /// The app is running but mints no operator credential, so its inventory is invisible to
    /// the CLI and every cross-plane hint above stays silent — the exact shape of the
    /// 2026-08-07 probe, where `repo add` landed CLI-local and the app never saw it.
    public static let operatorCredentialMissingHint =
        "note: the WorkSpaces app is running but exposes no operator credential, so the CLI "
        + "cannot see the app's repos or workspaces. Relaunch it with the Automation Operator "
        + "experiment enabled (or WORKSPACES_AUTOMATION_OPERATOR=1) to bridge the two planes."

    /// When a repo token misses the CLI-local store but names a repo the running app tracks
    /// (by name or path), explains the plane split and both ways out. Nil when the app does
    /// not know the token either.
    public static func missingLocalRepoGuidance(
        token: String,
        normalizedTokenPath: String?,
        app: AutomationWorkspaceInventory
    ) -> String? {
        let normalizedToken = normalizedTokenPath.map(CLIPathNormalizer.normalized)
        let matched = app.repos.first { repo in
            if repo.name == token || repo.path == token {
                return true
            }
            return CLIPathNormalizer.normalized(repo.path) == normalizedToken
        }
        guard let matched else {
            return nil
        }
        return "Repository '\(token)' is tracked by the running app but not by the CLI-local store. "
            + "Create the workspace in the app with 'workspaces automation workspace create "
            + "\(matched.repoID.uuidString) <name>', or track it for the CLI-local (appless) plane "
            + "with 'workspaces repo add \(matched.path)'."
    }

    /// Resolves a workspace selector (UUID, `<repo>/<name>`, or unique bare name) against
    /// the app's active (non-archived) workspaces.
    public static func matchWorkspace(
        token: String,
        in app: AutomationWorkspaceInventory
    ) -> WorkspaceMatchOutcome {
        let active = app.workspaces.filter { !$0.isArchived }
        if let uuid = UUID(uuidString: token),
            let byID = active.first(where: { $0.workspaceID == uuid })
        {
            return .match(appMatch(for: byID, in: app))
        }

        let matches: [AutomationWorkspaceDescriptor]
        if token.contains("/") {
            matches = active.filter { displayName(for: $0, in: app) == token }
        } else {
            matches = active.filter { $0.name == token }
        }

        switch matches.count {
        case 0:
            return .none
        case 1:
            return .match(appMatch(for: matches[0], in: app))
        default:
            return .ambiguous(matches.map { displayName(for: $0, in: app) })
        }
    }

    private static func normalizedPaths(_ paths: [String]) -> Set<String> {
        Set(paths.map(CLIPathNormalizer.normalized))
    }

    private static func localOnlySection(local: [LocalRow], appPaths: Set<String>) -> [String] {
        let localOnly = local.filter { !appPaths.contains(CLIPathNormalizer.normalized($0.path)) }
        guard !localOnly.isEmpty else {
            return []
        }
        var lines = ["", "CLI-local only (not visible to the app):"]
        for row in localOnly {
            lines.append("  \(row.displayName)\t\(row.path)")
        }
        return lines
    }

    private static func displayName(
        for workspace: AutomationWorkspaceDescriptor,
        in app: AutomationWorkspaceInventory
    ) -> String {
        guard let repoID = workspace.repoID,
            let repo = app.repos.first(where: { $0.repoID == repoID })
        else {
            return workspace.name
        }
        return "\(repo.name)/\(workspace.name)"
    }

    private static func appMatch(
        for workspace: AutomationWorkspaceDescriptor,
        in app: AutomationWorkspaceInventory
    ) -> AppWorkspaceMatch {
        let repo = workspace.repoID.flatMap { repoID in
            app.repos.first { $0.repoID == repoID }
        }
        return AppWorkspaceMatch(
            workspaceID: workspace.workspaceID,
            name: workspace.name,
            repoName: repo?.name,
            repoPath: repo?.path,
            path: workspace.path,
            branch: workspace.branch
        )
    }
}

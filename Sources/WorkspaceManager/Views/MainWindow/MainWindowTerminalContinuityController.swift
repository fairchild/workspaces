import SwiftUI
import WorkspaceManagerCore
import os.log

private let terminalContinuityLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "TerminalContinuity"
)

/// Reads and writes the terminal-continuity manifest — the record of which surfaces were open,
/// which was active, and where each launched, so the next run reopens where this one left off.
/// Archived workspaces are excluded from every write: a scope the user retired should not come
/// back on launch.
@MainActor
struct MainWindowTerminalContinuityController {
    struct Dependencies {
        let manifestRawValue: Binding<String>
        let repos: @MainActor () -> [Repo]
        let tileTreeStore: TileTreeStore
        let providerRegistry: WorkspaceProviderRegistry
        let terminalMode: @MainActor () -> TerminalMultiplexingMode
        let defaultHomeURL: URL
    }

    let dependencies: Dependencies

    /// Terminal scopes belonging to archived workspaces — excluded from continuity writes and
    /// from the launch-time session restore.
    var archivedWorkspaceScopeKeys: Set<HostTerminalSessionKey> {
        Set(
            dependencies.repos()
                .flatMap(\.workspaces)
                .filter { $0.status == .archived }
                .compactMap(terminalSessionKey(for:))
        )
    }

    func terminalSessionKey(for workspace: Workspace) -> HostTerminalSessionKey? {
        if workspace.backend == .local {
            return .hostPath(MainWindowPathResolution.normalize(workspace.workspaceURL.path))
        }

        guard let provider = dependencies.providerRegistry.provider(for: workspace) else {
            return nil
        }

        return provider.sessionKey(for: WorkspaceProviderTarget(workspace)).normalized()
    }

    private var continuityInputs:
        (
            sessions: [HostTerminalSession],
            activeSessionID: UUID?,
            activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID]
        )
    {
        let excludedScopeKeys = archivedWorkspaceScopeKeys
        let sessions = dependencies.tileTreeStore.sessions.filter { !excludedScopeKeys.contains($0.key) }
        let validSessionIDs = Set(sessions.map(\.id))
        let activeSessionID =
            dependencies.tileTreeStore.activeSessionID.flatMap {
                validSessionIDs.contains($0) ? $0 : sessions.last?.id
            } ?? sessions.last?.id
        let activeSessionIDByScopeKey = dependencies.tileTreeStore.activeSessionIDByScopeKey.filter {
            !excludedScopeKeys.contains($0.key) && validSessionIDs.contains($0.value)
        }

        return (sessions, activeSessionID, activeSessionIDByScopeKey)
    }

    /// Record the surface a selection just landed on, together with the current session set.
    func persist(
        targetKind: TerminalContinuityManifest.TargetKind,
        targetID: UUID,
        rootURL: URL,
        launchURL: URL
    ) {
        let inputs = continuityInputs
        let manifest = TerminalContinuityManifest(
            targetKind: targetKind,
            targetID: targetID,
            rootURL: rootURL,
            launchURL: launchURL,
            terminalMode: dependencies.terminalMode(),
            sessions: inputs.sessions,
            activeSessionID: inputs.activeSessionID,
            activeSessionIDByScopeKey: inputs.activeSessionIDByScopeKey
        )
        dependencies.manifestRawValue.wrappedValue = manifest.rawValue
        terminalContinuityLog.info(
            "[TerminalContinuity] persisted kind=\(targetKind.rawValue, privacy: .public) id=\(targetID.uuidString, privacy: .public) root=\(manifest.rootPath, privacy: .public) launch=\(manifest.launchPath, privacy: .public) tmux_session=\(manifest.tmuxSessionName, privacy: .public) mode=\(manifest.terminalMode.rawValue, privacy: .public)"
        )
    }

    /// Refresh the session set without changing the recorded target — used when sessions change
    /// under a selection that is already recorded.
    func persistSnapshot() {
        let inputs = continuityInputs
        let manifest = TerminalContinuityManifest.snapshot(
            previous: TerminalContinuityManifest.decode(from: dependencies.manifestRawValue.wrappedValue),
            defaultHomeURL: dependencies.defaultHomeURL,
            terminalMode: dependencies.terminalMode(),
            sessions: inputs.sessions,
            activeSessionID: inputs.activeSessionID,
            activeSessionIDByScopeKey: inputs.activeSessionIDByScopeKey
        )
        dependencies.manifestRawValue.wrappedValue = manifest.rawValue
    }

    func restoredLaunchDirectory(for repo: Repo) -> URL? {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()
        return TerminalContinuityManifest.decode(from: dependencies.manifestRawValue.wrappedValue)?
            .launchDirectory(
                for: .repo,
                targetID: repo.id,
                rootURL: repoDirectory
            )
    }

    func restoredLaunchDirectory(for workspace: Workspace) -> URL? {
        guard workspace.backend == .local else { return nil }
        let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        return TerminalContinuityManifest.decode(from: dependencies.manifestRawValue.wrappedValue)?
            .launchDirectory(
                for: .workspace,
                targetID: workspace.id,
                rootURL: workspaceDirectory
            )
    }
}

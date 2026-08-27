//
//  MainWindowOpenSurfaceReattachController.swift
//  WorkspaceManager
//
//  Decides which of the previous run's terminal scopes a launch rejoins. The continuity
//  manifest already records every scope that was open at quit and launch recreates those
//  session records, but a record is inert until its surface is realized — so nothing
//  reattaches to its surviving tmux session until the scope is clicked (#1374). This picks
//  the records worth realizing: one per scope, tmux-backed, still on disk, and bounded.
//

import Foundation
import WorkspaceManagerCore

/// Whether a launch rejoins the previous run's other scopes at all.
///
/// On by default — a relaunch that leaves live sessions dark is the bug (#1374). Two
/// environments opt out: `CI`, where a runner has no prior desktop session to rejoin and
/// a dozen extra shells is only noise, and an explicit `WORKSPACES_DISABLE_OPEN_SURFACE_REATTACH`
/// for a launch that wants the window and nothing else.
enum MainWindowOpenSurfaceReattachPolicy {
    static let disableEnvironmentKey = "WORKSPACES_DISABLE_OPEN_SURFACE_REATTACH"

    /// Whether this launch's rejoin pass is still unclaimed, claiming it if so.
    ///
    /// Every window restores the same continuity manifest into its own store, so the pass is
    /// scoped to the process rather than the window: without this, a second window would start
    /// a second shell per scope and attach a second client to every surviving tmux session.
    /// A restore the user accepts is a separate, explicit act and is not gated here.
    @MainActor
    static func claimLaunchPass() -> Bool {
        guard !didClaimLaunchPass else { return false }
        didClaimLaunchPass = true
        return true
    }

    @MainActor
    static func releaseLaunchPassForTesting() {
        didClaimLaunchPass = false
    }

    @MainActor
    private static var didClaimLaunchPass = false

    static func isEnabled(environment: [String: String]) -> Bool {
        guard environment["CI"] == nil else { return false }
        switch environment[disableEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        {
        case "1", "true", "yes", "on":
            return false
        default:
            return true
        }
    }
}

/// The reattach decision, split into the part that reads state (`candidates`) and the part
/// that consumes a tmux liveness answer (`reattachableSessionIDs`). The split is what keeps
/// the whole decision synchronous and testable: probing tmux is the only async step, and it
/// happens between the two calls.
struct MainWindowOpenSurfaceReattachController {
    /// What put the session records in front of the pass. `launch` is the window coming up on
    /// the continuity manifest and runs once per process; `restore` is the user accepting a
    /// restore plan, which is an explicit act in one window and always runs.
    enum Trigger: String, Sendable {
        case launch
        case restore
    }

    /// A restored session whose scope is worth rejoining, paired with the tmux session name
    /// its surface would attach to.
    struct Candidate: Equatable, Sendable {
        let sessionID: UUID
        let key: HostTerminalSessionKey
        let tmuxSessionName: String
    }

    /// Upper bound on the surfaces one launch realizes. Each realization starts a shell and
    /// attaches a tmux client, so a window that accumulated scopes over a long run cannot turn
    /// one launch into dozens of process starts.
    static let maximumSurfaces = 12

    /// The scopes this launch should rejoin, in `sessions` order — which is the order the
    /// previous run opened them, since that is the order the manifest records and restore
    /// replays. Past `limit` the tail is dropped, so a long-lived set of scopes keeps its
    /// oldest members rather than churning on whichever was touched last; the dropped ones
    /// open on demand.
    ///
    /// Only `.tmuxPerSession` produces candidates: in Ghostty-managed mode a surface's shell
    /// died with the previous process, so realizing its record would start a fresh shell
    /// rather than rejoin anything — work the user did not ask for.
    ///
    /// One candidate per scope key (the scope's active session), because a scope shows one
    /// terminal at a time; the rest of its tabs realize when the user switches to them.
    func candidates(
        sessions: [HostTerminalSession],
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID],
        excludedSessionIDs: Set<UUID>,
        excludedScopeKeys: Set<HostTerminalSessionKey>,
        terminalMode: TerminalMultiplexingMode,
        limit: Int = MainWindowOpenSurfaceReattachController.maximumSurfaces,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        guard terminalMode == .tmuxPerSession, limit > 0 else { return [] }

        var seenScopeKeys: Set<HostTerminalSessionKey> = []
        var candidates: [Candidate] = []

        for session in sessions {
            guard candidates.count < limit else { break }
            guard !excludedScopeKeys.contains(session.key) else { continue }
            guard !seenScopeKeys.contains(session.key) else { continue }

            // The scope's active session is the one its detail view would show; a sibling
            // tab is not what the user left in front of them. Reaching it settles the
            // scope either way — an excluded or unrejoinable active session means this
            // scope contributes nothing, not that a sibling stands in for it.
            if let activeSessionID = activeSessionIDByScopeKey[session.key],
                activeSessionID != session.id
            {
                continue
            }
            seenScopeKeys.insert(session.key)

            guard !excludedSessionIDs.contains(session.id) else { continue }
            guard isReattachable(session, fileManager: fileManager) else { continue }

            candidates.append(
                Candidate(
                    sessionID: session.id,
                    key: session.key,
                    tmuxSessionName: session.effectiveTmuxSessionName
                )
            )
        }

        return candidates
    }

    /// The candidates whose recorded tmux session is actually alive, in candidate order.
    ///
    /// Liveness is the whole safety argument: attaching to a session that survived is what
    /// the user means by "my workspaces are still open", while realizing a surface with no
    /// session behind it would spawn a shell they never asked for. A scope whose session is
    /// gone still opens on demand the moment it is selected.
    func reattachableSessionIDs(
        candidates: [Candidate],
        liveTmuxSessionNames: Set<String>
    ) -> [UUID] {
        candidates
            .filter { liveTmuxSessionNames.contains($0.tmuxSessionName) }
            .map(\.sessionID)
    }

    /// Whether a session is the kind a launch may rejoin without side effects the user did
    /// not ask for: a directory-backed local scope, still on disk, carrying no command of
    /// its own. A remote (`customCommand`) session would re-run its SSH invocation, and an
    /// `initialCommand` session would re-run an agent — both are explicit acts, not restore.
    private func isReattachable(_ session: HostTerminalSession, fileManager: FileManager) -> Bool {
        guard session.customCommand == nil, session.initialCommand == nil else { return false }

        switch session.key {
        case .defaultHome, .repoPath, .hostPath:
            break
        case .backendSession:
            return false
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: session.directoryPath, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}

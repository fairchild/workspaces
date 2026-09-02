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

/// Whether the window the rejoin pass is working for is still there.
///
/// The pass awaits subprocess probes and a perf-interval wait, and the launch task that runs it
/// is unstructured — closing the window neither cancels nor completes it. A reference type in
/// `@State` outlives the view value, so the pass can re-check after each suspension and stop
/// instead of realizing surfaces into a store that is being torn down.
@MainActor
final class MainWindowLaunchWorkLifetime {
    private(set) var isWindowTornDown = false

    func noteWindowAppeared() {
        isWindowTornDown = false
    }

    func noteWindowTornDown() {
        isWindowTornDown = true
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

    /// The scopes this launch should rejoin, in `sessions` order, with the tail past `limit`
    /// dropped. That order is whatever put the records there — the manifest replays the order
    /// the previous run opened them, an accepted restore plan replays newest-first — so the
    /// cap is a bound, not a ranking. Dropped scopes open on demand.
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

    /// The reattachable set split by what realizing each scope would actually do.
    struct Split: Equatable, Sendable {
        /// Scopes with no surface yet: realizing one is what attaches its tmux client.
        let toRealize: [UUID]
        /// Scopes already showing a live surface when the pass reached them.
        let alreadyLive: [UUID]
    }

    /// Separate the scopes this pass attaches from the ones that were already attached when it
    /// got there.
    ///
    /// A restore plan realizes the scopes it covers, so on a launch whose plan covers the whole
    /// open set every candidate is a live surface by the time the pass runs. Realizing one
    /// again is a no-op, and counting it as rejoined reported work the pass had not done —
    /// which is the one question the diagnostic exists to answer (#1398).
    func split(
        reattachableSessionIDs: [UUID],
        isSurfaceRealized: (UUID) -> Bool
    ) -> Split {
        var toRealize: [UUID] = []
        var alreadyLive: [UUID] = []
        for sessionID in reattachableSessionIDs {
            if isSurfaceRealized(sessionID) {
                alreadyLive.append(sessionID)
            } else {
                toRealize.append(sessionID)
            }
        }
        return Split(toRealize: toRealize, alreadyLive: alreadyLive)
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

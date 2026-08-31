//
//  TerminalRestorePlanner.swift
//  WorkspaceManagerCore
//
//  Turns the durable-session read model (LocalStateStore continuity rows plus the
//  latest layout snapshot) into an ordered RestorePlan for cold-start restore.
//  Pure and dependency-injected: SwiftData target resolution, tmux liveness, and
//  Claude transcript resumability are supplied by the caller so the ladder logic
//  stays unit-testable. Producing a plan performs no launches — wiring into
//  startup is a later slice.
//

import Foundation

/// A per-surface restore instruction. The chosen rung determines how the surface
/// comes back; `directory` is the effective working directory for that rung.
public enum RestoreSurfaceAction: Sendable, Equatable {
    /// Reattach to a live tmux session that survived (same-login-session continuity).
    case reattachTmux(sessionName: String)
    /// Relaunch a Claude Code conversation from its still-present transcript.
    case resumeClaude(agentSessionID: String)
    /// Start a plain shell — no live process and no resumable conversation.
    case freshShell
}

/// One surface to restore, carrying the persisted host-session identity, the
/// canonical session key resolved against current data, the effective launch
/// directory, and the action to take.
public struct RestoreSurfacePlan: Sendable, Equatable, Identifiable {
    public let hostSessionID: UUID
    public let key: HostTerminalSessionKey
    public let directory: URL
    public let action: RestoreSurfaceAction
    /// True when the recorded launch directory no longer exists and `directory` is
    /// the resolved target root instead. The wiring layer reports this instead of
    /// switching silently — for a reattach it means the surface launches somewhere
    /// other than where the surviving tmux session was recorded.
    public let launchDirectoryFellBack: Bool

    public var id: UUID { hostSessionID }

    public init(
        hostSessionID: UUID,
        key: HostTerminalSessionKey,
        directory: URL,
        action: RestoreSurfaceAction,
        launchDirectoryFellBack: Bool = false
    ) {
        self.hostSessionID = hostSessionID
        self.key = key
        self.directory = directory
        self.action = action
        self.launchDirectoryFellBack = launchDirectoryFellBack
    }
}

/// The full ordered restore plan. `surfaces` preserves read-model order (newest
/// `last_seen_at` first). `selectedHostSessionID` is advisory — which surface to
/// focus after restore — and is honored by the wiring slice, not here.
/// `previousRunID` identifies the prior app run the plan was built from, so the
/// banner can avoid re-offering a run the user already restored or dismissed.
public struct RestorePlan: Sendable, Equatable {
    public let surfaces: [RestoreSurfacePlan]
    public let selectedHostSessionID: UUID?
    public let previousRunID: String?

    public init(
        surfaces: [RestoreSurfacePlan],
        selectedHostSessionID: UUID?,
        previousRunID: String? = nil
    ) {
        self.surfaces = surfaces
        self.selectedHostSessionID = selectedHostSessionID
        self.previousRunID = previousRunID
    }

    /// Whether this plan's prior run was already handled (restored or dismissed).
    /// A plan without a run identity is never considered handled — when in doubt,
    /// offer the banner rather than silently drop a restorable session set.
    public func wasHandled(handledRunID: String?) -> Bool {
        guard let previousRunID, let handledRunID else { return false }
        return previousRunID == handledRunID
    }

    /// Whether the plan restores anything beyond what a fresh launch already
    /// provides. Startup seeds a plain shell on `seedKey` at `seedDirectory`
    /// before restore runs, so a plan consisting only of fresh shells matching
    /// both duplicates the seed and is not worth a banner. A fresh shell on the
    /// seed key at a different directory is still a real restore (the default
    /// host directory can change between runs) and keeps the banner.
    public func offersMoreThanLaunchSeed(
        seedKey: HostTerminalSessionKey,
        seedDirectory: URL
    ) -> Bool {
        let normalizedSeedPath = seedDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return surfaces.contains { surface in
            surface.action != .freshShell
                || surface.key != seedKey
                || surface.directory.standardizedFileURL.resolvingSymlinksInPath().path
                    != normalizedSeedPath
        }
    }
}

/// A continuity row that resolved against current SwiftData state. The resolver
/// owns key reconstruction (it has the model context) and guarantees
/// `rootDirectory` exists, so the planner can treat it as a validated fallback.
public struct ResolvedRestoreTarget: Sendable, Equatable {
    public let key: HostTerminalSessionKey
    public let rootDirectory: URL

    public init(key: HostTerminalSessionKey, rootDirectory: URL) {
        self.key = key
        self.rootDirectory = rootDirectory
    }
}

/// Builds a `RestorePlan` from continuity rows. All environment access is
/// injected; the planner itself is pure and `Sendable`.
public struct TerminalRestorePlanner: Sendable {
    /// Resolve a row to a live target, or `nil` to drop it (missing/archived
    /// SwiftData row, or a conservatively-excluded remote/backend session).
    public typealias TargetResolver = @Sendable (TerminalSessionContinuityRow) -> ResolvedRestoreTarget?
    /// Whether a tmux session with the given deterministic name is alive.
    public typealias TmuxLivenessProbe = @Sendable (_ tmuxSessionName: String) -> Bool
    /// Whether a Claude transcript for this session id and cwd is still present.
    public typealias TranscriptResumabilityCheck = @Sendable (_ agentSessionID: String, _ cwd: String) -> Bool
    /// Whether a directory currently exists (defaults to a `FileManager` probe).
    public typealias DirectoryExistenceCheck = @Sendable (_ path: String) -> Bool
    /// The newest Claude transcript id recorded for `cwd`, skipping ids already
    /// claimed by an earlier surface in this plan. Returns `nil` when the directory
    /// has no unclaimed transcript.
    public typealias TranscriptIdentityResolver = @Sendable (_ cwd: String, _ claimed: Set<String>) -> String?

    private let resolveTarget: TargetResolver
    private let isTmuxSessionAlive: TmuxLivenessProbe
    private let isTranscriptResumable: TranscriptResumabilityCheck
    private let directoryExists: DirectoryExistenceCheck
    private let newestTranscriptID: TranscriptIdentityResolver

    public init(
        resolveTarget: @escaping TargetResolver,
        isTmuxSessionAlive: @escaping TmuxLivenessProbe,
        isTranscriptResumable: @escaping TranscriptResumabilityCheck,
        directoryExists: @escaping DirectoryExistenceCheck = Self.defaultDirectoryExists,
        newestTranscriptID: @escaping TranscriptIdentityResolver = { _, _ in nil }
    ) {
        self.resolveTarget = resolveTarget
        self.isTmuxSessionAlive = isTmuxSessionAlive
        self.isTranscriptResumable = isTranscriptResumable
        self.directoryExists = directoryExists
        self.newestTranscriptID = newestTranscriptID
    }

    public func plan(
        rows: [TerminalSessionContinuityRow],
        layout: TerminalLayoutSnapshotRow?,
        previousRunID: String? = nil
    ) -> RestorePlan {
        var surfaces: [RestoreSurfacePlan] = []
        // Every id any row records, reserved before allocation begins. A row that
        // reattaches its tmux session never reaches the resume rung, so it claims
        // nothing as it goes — yet the conversation it is rejoining is live in that
        // pane, and an inferred fallback elsewhere would happily hand the same
        // transcript to a second surface. Reserving up front also makes allocation
        // order irrelevant, so an unrecorded row cannot take an id that a row further
        // down the list has positive evidence for.
        let recordedAgentSessionIDs = Set(rows.compactMap(\.agentSessionID))
        // Ids actually handed out so far, which is what stops two fallbacks in one
        // directory from resuming the same conversation into two panes.
        var usedAgentSessionIDs: Set<String> = []
        for row in rows {
            guard row.endedAt == nil, row.isActive else { continue }
            guard let resolved = resolveTarget(row) else { continue }
            let decision = decideAction(
                row: row,
                resolved: resolved,
                usedAgentSessionIDs: usedAgentSessionIDs,
                recordedAgentSessionIDs: recordedAgentSessionIDs
            )
            if case .resumeClaude(let agentSessionID) = decision.action {
                usedAgentSessionIDs.insert(agentSessionID)
            }
            surfaces.append(
                RestoreSurfacePlan(
                    hostSessionID: row.hostSessionID,
                    key: resolved.key,
                    directory: decision.directory,
                    action: decision.action,
                    launchDirectoryFellBack: decision.fellBack
                )
            )
        }
        return RestorePlan(
            surfaces: surfaces,
            selectedHostSessionID: layout?.activeHostSessionID,
            previousRunID: previousRunID
        )
    }

    /// The restore ladder: live tmux → resumable Claude transcript → fresh shell.
    private func decideAction(
        row: TerminalSessionContinuityRow,
        resolved: ResolvedRestoreTarget,
        usedAgentSessionIDs: Set<String>,
        recordedAgentSessionIDs: Set<String>
    ) -> (action: RestoreSurfaceAction, directory: URL, fellBack: Bool) {
        if let tmuxSessionName = row.tmuxSessionName, isTmuxSessionAlive(tmuxSessionName) {
            let (directory, fellBack) = nearestValidDirectory(row: row, resolved: resolved)
            return (.reattachTmux(sessionName: tmuxSessionName), directory, fellBack)
        }

        // The cwd Claude reported for this session when known, else the recorded
        // launch directory — a session whose hooks never landed still ran somewhere.
        let agentCwd = row.agentCwd ?? row.directoryPath
        if directoryExists(agentCwd),
            let agentSessionID = resumableAgentSessionID(
                row: row,
                cwd: agentCwd,
                usedAgentSessionIDs: usedAgentSessionIDs,
                recordedAgentSessionIDs: recordedAgentSessionIDs
            )
        {
            return (.resumeClaude(agentSessionID: agentSessionID), URL(fileURLWithPath: agentCwd), false)
        }

        let (directory, fellBack) = nearestValidDirectory(row: row, resolved: resolved)
        return (.freshShell, directory, fellBack)
    }

    /// The Claude session this surface can resume, preferring the id the store
    /// recorded and falling back to the newest unclaimed transcript in `cwd`.
    ///
    /// The fallback exists because a surface whose launch lost its environment never
    /// reported an id at all (#889), so the store has nothing to offer for exactly
    /// the sessions restore most needs to recover. Reading the directory is what the
    /// user otherwise does by hand.
    private func resumableAgentSessionID(
        row: TerminalSessionContinuityRow,
        cwd: String,
        usedAgentSessionIDs: Set<String>,
        recordedAgentSessionIDs: Set<String>
    ) -> String? {
        if row.agentKind == AgentKind.claudeCode.rawValue,
            let recorded = row.agentSessionID,
            Self.isWellFormedAgentSessionID(recorded),
            !usedAgentSessionIDs.contains(recorded),
            isTranscriptResumable(recorded, cwd)
        {
            return recorded
        }
        // The fallback reads a Claude transcript directory, so it may only answer for
        // a session that was Claude or was never identified at all. A directory where
        // Claude once ran would otherwise hand `claude --resume` to a surface the
        // store knows was running a different agent.
        guard row.agentKind == nil || row.agentKind == AgentKind.claudeCode.rawValue else { return nil }
        // Never infer an identity another row records: that row's conversation may be
        // live in the pane it is reattaching, and resuming it here would be a second
        // agent writing one transcript.
        let unavailable = usedAgentSessionIDs.union(recordedAgentSessionIDs)
        guard let recovered = newestTranscriptID(cwd, unavailable),
            Self.isWellFormedAgentSessionID(recovered)
        else { return nil }
        return isTranscriptResumable(recovered, cwd) ? recovered : nil
    }

    /// Whether `value` has the shape of a Claude session id.
    ///
    /// The id ends up interpolated into a shell command the user presses Return on,
    /// and it arrives from places this process does not control — a hook payload, or
    /// a filename in the transcripts directory that anything can write. A transcript
    /// named `x; rm -rf ~;.jsonl` would otherwise become exactly that command. Claude
    /// session ids are UUIDs, so the shape is checked at read and rejected outright
    /// rather than escaped on the way out.
    static func isWellFormedAgentSessionID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// Prefer the recorded launch directory when it still exists; otherwise fall
    /// back to the resolved (validated) target root, reporting the fallback.
    private func nearestValidDirectory(
        row: TerminalSessionContinuityRow,
        resolved: ResolvedRestoreTarget
    ) -> (URL, fellBack: Bool) {
        if directoryExists(row.directoryPath) {
            return (URL(fileURLWithPath: row.directoryPath), false)
        }
        return (resolved.rootDirectory, true)
    }

    /// Default directory-existence probe: true only for an existing directory.
    public static let defaultDirectoryExists: DirectoryExistenceCheck = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

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

    public var id: UUID { hostSessionID }

    public init(
        hostSessionID: UUID,
        key: HostTerminalSessionKey,
        directory: URL,
        action: RestoreSurfaceAction
    ) {
        self.hostSessionID = hostSessionID
        self.key = key
        self.directory = directory
        self.action = action
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

    private let resolveTarget: TargetResolver
    private let isTmuxSessionAlive: TmuxLivenessProbe
    private let isTranscriptResumable: TranscriptResumabilityCheck
    private let directoryExists: DirectoryExistenceCheck

    public init(
        resolveTarget: @escaping TargetResolver,
        isTmuxSessionAlive: @escaping TmuxLivenessProbe,
        isTranscriptResumable: @escaping TranscriptResumabilityCheck,
        directoryExists: @escaping DirectoryExistenceCheck = Self.defaultDirectoryExists
    ) {
        self.resolveTarget = resolveTarget
        self.isTmuxSessionAlive = isTmuxSessionAlive
        self.isTranscriptResumable = isTranscriptResumable
        self.directoryExists = directoryExists
    }

    public func plan(
        rows: [TerminalSessionContinuityRow],
        layout: TerminalLayoutSnapshotRow?,
        previousRunID: String? = nil
    ) -> RestorePlan {
        var surfaces: [RestoreSurfacePlan] = []
        for row in rows {
            guard row.endedAt == nil, row.isActive else { continue }
            guard let resolved = resolveTarget(row) else { continue }
            let (action, directory) = decideAction(row: row, resolved: resolved)
            surfaces.append(
                RestoreSurfacePlan(
                    hostSessionID: row.hostSessionID,
                    key: resolved.key,
                    directory: directory,
                    action: action
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
        resolved: ResolvedRestoreTarget
    ) -> (RestoreSurfaceAction, URL) {
        if let tmuxSessionName = row.tmuxSessionName, isTmuxSessionAlive(tmuxSessionName) {
            return (.reattachTmux(sessionName: tmuxSessionName), nearestValidDirectory(row: row, resolved: resolved))
        }

        if row.agentKind == AgentKind.claudeCode.rawValue,
            let agentSessionID = row.agentSessionID,
            let agentCwd = row.agentCwd,
            directoryExists(agentCwd),
            isTranscriptResumable(agentSessionID, agentCwd)
        {
            return (.resumeClaude(agentSessionID: agentSessionID), URL(fileURLWithPath: agentCwd))
        }

        return (.freshShell, nearestValidDirectory(row: row, resolved: resolved))
    }

    /// Prefer the recorded launch directory when it still exists; otherwise fall
    /// back to the resolved (validated) target root.
    private func nearestValidDirectory(
        row: TerminalSessionContinuityRow,
        resolved: ResolvedRestoreTarget
    ) -> URL {
        if directoryExists(row.directoryPath) {
            return URL(fileURLWithPath: row.directoryPath)
        }
        return resolved.rootDirectory
    }

    /// Default directory-existence probe: true only for an existing directory.
    public static let defaultDirectoryExists: DirectoryExistenceCheck = { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

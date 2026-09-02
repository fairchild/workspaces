//
//  TmuxSessionOwnership.swift
//  WorkspaceManagerCore
//
//  Establishes which tmux sessions on the shared `-L workspaces` socket this app
//  may terminate. Ownership comes from creation — the session id tmux assigned when
//  the app's own launch brought the session up — rather than from the session's
//  name, which is a directory derivation any co-resident tool arrives at on its own
//  (#1267).
//

import Foundation

/// A live tmux session as the server describes it: the id it assigned, the name it
/// currently answers to, when it was created, and which server it lives on.
///
/// The id is the identity. A name is a claim two parties can make at once; an id is
/// the server's own record of a session it created, unique for that server's
/// lifetime and never reused within it.
public struct TmuxLiveSession: Sendable, Equatable {
    /// tmux's `#{session_id}` — always `$` followed by digits.
    public let sessionID: String
    /// `#{session_name}` at the moment of the read. Names change hands; this one is
    /// carried so a kill can confirm the id still holds the name it was chosen for.
    public let name: String
    /// `#{session_created}`, which tmux reports in whole seconds.
    public let createdAt: Date
    /// `#{pid}` — the tmux server's own pid, or `nil` on a tmux that did not report
    /// it. Distinguishes ids from different server lifetimes, which both start at `$0`.
    public let serverPID: Int?

    public init(sessionID: String, name: String, createdAt: Date, serverPID: Int? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.createdAt = createdAt
        self.serverPID = serverPID
    }

    /// Whether `value` has the shape tmux gives a session id: `$` and at least one
    /// digit, nothing else. Guards the kill target, where an empty string is not an
    /// inert no-op but an instruction to kill the current session.
    public static func isWellFormedSessionID(_ value: String) -> Bool {
        guard value.hasPrefix("$") else { return false }
        let digits = value.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}

/// How a surface came to be attached to the tmux session backing it.
public enum TmuxSessionProvenance: Sendable, Equatable {
    /// The app's own launch created this session: it did not exist when the surface
    /// started, so nothing else can hold a claim on it.
    case createdByThisLaunch
    /// `new-session -A` joined a session that was already running — a survivor of a
    /// previous app run, or a session that had nothing to do with this app and merely
    /// held the name the surface's directory derives.
    case adopted
}

/// What the app knows about the tmux session behind one host terminal session.
public struct TmuxSessionOwnership: Sendable, Equatable {
    public let identity: TmuxLiveSession
    public let provenance: TmuxSessionProvenance

    public init(identity: TmuxLiveSession, provenance: TmuxSessionProvenance) {
        self.identity = identity
        self.provenance = provenance
    }
}

/// The app's record of which tmux session backs each of its surfaces, and whether it
/// created that session or joined one already running.
///
/// Every kill path resolves through here. Before this existed each path asked its own
/// question of a *name* — "is this name in the set this launch holds", "is this name
/// shaped like a split pane's", "is this surface in tmux mode and local" — and a name
/// answers none of them, because `-L workspaces` is same-user shared and every name on
/// it is derived from a directory two parties can both be working in.
///
/// The ledger is per-run and in memory. A session this process never observed is one it
/// cannot attribute, and an unattributable session is never killed. That is the
/// conservative direction: the cost of forgetting is a session left running, and the
/// cost of guessing is someone else's shell.
///
/// Entries are never removed. A host session id is a UUID that is never reissued, so a
/// record for a retired surface can only ever be consulted by a caller naming that same
/// retired surface — and the kill it would authorize is re-checked against a fresh read
/// of the socket anyway. Growth is one small value per tmux-backed surface opened in a
/// run, which is bounded by what a person does in a sitting.
@MainActor
public final class TmuxSessionOwnershipLedger {
    private var ownershipByHostSessionID: [UUID: TmuxSessionOwnership] = [:]

    public init() {}

    /// Classify and record the session found backing `hostSessionID`.
    ///
    /// `launchedAt` is when the app started the surface whose shell execs
    /// `new-session -A`. A session older than that launch was there to be adopted; one
    /// created at or after it is the launch's own. tmux reports `session_created` in
    /// whole seconds, so the comparison floors `launchedAt` to its second — erring, in
    /// the sub-second window where the two are indistinguishable, toward calling the
    /// session ours. That window is bounded by one second and by the surface having just
    /// launched; the case this defends against is a session a person or another agent
    /// left running, which predates the launch by far more than that.
    @discardableResult
    public func record(
        hostSessionID: UUID,
        identity: TmuxLiveSession,
        launchedAt: Date
    ) -> TmuxSessionOwnership {
        let launchSecond = Date(timeIntervalSince1970: launchedAt.timeIntervalSince1970.rounded(.down))
        let ownership = TmuxSessionOwnership(
            identity: identity,
            provenance: identity.createdAt < launchSecond ? .adopted : .createdByThisLaunch
        )
        ownershipByHostSessionID[hostSessionID] = ownership
        return ownership
    }

    public func ownership(forHostSessionID hostSessionID: UUID) -> TmuxSessionOwnership? {
        ownershipByHostSessionID[hostSessionID]
    }

    /// The session id a kill for `hostSessionID` may target, or `nil` when the app
    /// cannot prove the session is still the one it recorded.
    ///
    /// `liveSessions` is the caller's *fresh* read of the socket, not a remembered one.
    /// Three things have to agree before a kill is authorized: the app recorded an
    /// identity for this surface, that id is still live, and it still answers to the
    /// name it was recorded under. The last check is what stops a kill aimed at a
    /// session that has since been renamed out from under the record.
    ///
    /// `requiringCreation` is the launch-time posture: the pre-restore pass exists only
    /// to clear away seeds this launch made moments earlier, so it accepts nothing else.
    /// Teardown paths run because a person asked for this surface to go, and accept an
    /// adopted session too — the surface is bound to it either way.
    public func authorizedKillTarget(
        forHostSessionID hostSessionID: UUID,
        liveSessions: [TmuxLiveSession],
        requiringCreation: Bool
    ) -> String? {
        guard let ownership = ownershipByHostSessionID[hostSessionID] else { return nil }
        if requiringCreation, ownership.provenance != .createdByThisLaunch { return nil }
        guard
            let live = liveSessions.first(where: { $0.sessionID == ownership.identity.sessionID }),
            live.name == ownership.identity.name
        else {
            return nil
        }
        return live.sessionID
    }
}

/// The single authority that ends a tmux session the app owns. Every teardown path
/// goes through it, so "may this die" is answered once rather than three times in
/// three different vocabularies.
///
/// It resolves the socket immediately before each kill rather than acting on the
/// identity it recorded at launch. A recorded id is a claim about the past; the kill
/// happens now, and in between a session can exit, be renamed, or have its name taken
/// by something else. Re-reading costs one `list-sessions` per kill and removes the
/// narrower race that survives id-based authorization on its own.
@MainActor
public struct TmuxOwnedSessionTerminator {
    /// What one authorized termination attempt did, in enough detail to log why
    /// nothing died when nothing died.
    public enum Outcome: Sendable, Equatable {
        /// The session ended. Carries what died, for the caller's report.
        case killed(sessionID: String, name: String)
        /// The app holds no ownership record for this surface, or holds one that
        /// forbids the kill. Nothing was touched.
        case notAttributable
        /// Ownership is on record but the socket no longer shows that session under
        /// that name — it exited, or the name moved. Nothing was touched.
        case notLive
        /// tmux did not answer the enumerating read, so nothing could be attributed.
        case socketUnavailable
        /// The kill was authorized and issued, and tmux reported failure.
        case killFailed(sessionID: String)

        public var didKill: Bool {
            if case .killed = self { return true }
            return false
        }
    }

    private let ledger: TmuxSessionOwnershipLedger
    private let probe: TmuxSessionProbe

    public init(ledger: TmuxSessionOwnershipLedger, probe: TmuxSessionProbe = TmuxSessionProbe()) {
        self.ledger = ledger
        self.probe = probe
    }

    /// End the tmux session backing `hostSessionID`, if ownership proves the app may.
    ///
    /// `requiringCreation` is the launch-time posture: the pre-restore pass clears away
    /// seeds this launch made moments earlier and must accept nothing else. Teardown
    /// paths run because a person asked this surface to go, so a session the surface
    /// adopted counts as theirs to end.
    public func terminate(
        hostSessionID: UUID,
        requiringCreation: Bool
    ) async -> Outcome {
        guard let ownership = ledger.ownership(forHostSessionID: hostSessionID) else {
            return .notAttributable
        }
        guard let liveSessions = await probe.liveSessions() else { return .socketUnavailable }
        guard
            let target = ledger.authorizedKillTarget(
                forHostSessionID: hostSessionID,
                liveSessions: liveSessions,
                requiringCreation: requiringCreation
            )
        else {
            // Distinguish "the app may not kill this" from "there is nothing left to
            // kill": the first is the #1267 defense reporting for duty, the second is
            // ordinary housekeeping, and a reader of the log needs to tell them apart.
            let stillLive = liveSessions.contains { $0.sessionID == ownership.identity.sessionID }
            return stillLive ? .notAttributable : .notLive
        }
        let name = liveSessions.first { $0.sessionID == target }?.name ?? ownership.identity.name
        return await probe.killSession(id: target)
            ? .killed(sessionID: target, name: name)
            : .killFailed(sessionID: target)
    }
}

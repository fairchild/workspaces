//
//  TmuxSessionNameSharing.swift
//  WorkspaceManagerCore
//
//  Decides which restored surface keeps a tmux name that several recorded surfaces
//  share. Tabs once launched on their primary's directory-derived name, so two tabs
//  were two views of one shell; restoring both onto that name would carry the mirror
//  forward forever. One keeps the live session and the rest move to names of their own.
//

import Foundation

public enum TmuxSessionNameSharing {
    public struct Claim: Sendable, Equatable {
        public let hostSessionID: UUID
        public let tmuxSessionName: String

        public init(hostSessionID: UUID, tmuxSessionName: String) {
            self.hostSessionID = hostSessionID
            self.tmuxSessionName = tmuxSessionName
        }
    }

    /// Names more than one claim holds.
    public static func sharedNames(in claims: [Claim]) -> Set<String> {
        var counts: [String: Int] = [:]
        for claim in claims {
            counts[claim.tmuxSessionName, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// The claims that must leave their name: for each shared name, every claimant but one.
    ///
    /// The keeper is the claimant `reportedHolder` names — the host-session id the live
    /// session's environment carries, which is the id its processes post under — when that
    /// id is among the claimants, and otherwise the first claimant in order. Only shared
    /// names are looked up.
    public static func displacedClaims(
        _ claims: [Claim],
        reportedHolder: (String) -> UUID?
    ) -> Set<UUID> {
        let shared = sharedNames(in: claims)
        guard !shared.isEmpty else { return [] }
        var displaced: Set<UUID> = []
        for name in shared {
            let claimants = claims.filter { $0.tmuxSessionName == name }.map(\.hostSessionID)
            let reported = reportedHolder(name)
            let keeper = claimants.first { $0 == reported } ?? claimants[0]
            displaced.formUnion(claimants.filter { $0 != keeper })
        }
        return displaced
    }

    /// The name a displaced surface launches on instead: the same pane-scoped shape a new
    /// tab or split gets, so closing it later reclaims only its own session.
    public static func replacementName(for directory: URL, hostSessionID: UUID) -> String {
        TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: hostSessionID)
    }
}

//
//  TmuxSessionNameSharing.swift
//  WorkspaceManagerCore
//
//  Decides which restored surface keeps a tmux name that several recorded surfaces
//  share. Tabs once launched on their primary's directory-derived name, so two tabs
//  were two views of one shell; restoring both onto that name would carry the mirror
//  forward forever. One keeps the live session and the rest move fresh shells onto names of
//  their own.
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

    /// The claims that must leave their name: for each shared name, every claimant but the
    /// first in `claims`' order. Callers order claims by which one should keep the session.
    public static func displacedClaims(_ claims: [Claim]) -> Set<UUID> {
        let shared = sharedNames(in: claims)
        guard !shared.isEmpty else { return [] }
        var displaced: Set<UUID> = []
        for name in shared {
            let claimants = claims.filter { $0.tmuxSessionName == name }.map(\.hostSessionID)
            displaced.formUnion(claimants.dropFirst())
        }
        return displaced
    }

    /// A name for a displaced surface's fresh shell: the pane-scoped shape a new tab or split
    /// gets, so closing it later reclaims only its own session, minted new each time so it
    /// cannot land on a session an earlier restore left behind.
    public static func replacementName(for directory: URL) -> String {
        TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: UUID())
    }
}

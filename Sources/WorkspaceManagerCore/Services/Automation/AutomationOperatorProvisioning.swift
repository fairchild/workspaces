//
//  AutomationOperatorProvisioning.swift
//  WorkspaceManagerCore
//
//  Makes operator provisioning idempotent and its outcome nameable. Minting once
//  at listener start ties the operator scope to the instant a launch bound its
//  socket, while the experiment behind it is a live-readable toggle — so the two
//  can disagree, and nothing said which was in force. `refresh` can run on every
//  configure pass, and `Outcome` is what `automation health` reports.
//

import Foundation

@MainActor
public enum AutomationOperatorProvisioning {

    /// What a refresh pass settled on. Reported over `/v1/health`, so a caller that
    /// finds no credential learns whether this launch declined to mint one, failed
    /// to, or minted one that has since been removed.
    public enum Outcome: String, Codable, Sendable, Equatable {
        /// Opted in, and a fresh credential was written for this launch.
        case minted
        /// Opted in, and the credential already on disk still resolves against this
        /// launch's registry — re-minting would only invalidate a handle in use.
        case reused
        /// Not opted in. Any stale credential was removed, which is the fail-closed
        /// state, not a failure.
        case notOptedIn = "not_opted_in"
        /// Opted in, and the mint did not produce a readable credential — a write
        /// that failed, or a rollback. The one outcome that warrants a loud log.
        case mintFailed = "mint_failed"

        public var isCredentialAvailable: Bool {
            self == .minted || self == .reused
        }
    }

    public struct Result: Sendable, Equatable {
        public let credential: AutomationOperatorCredential?
        public let outcome: Outcome

        public init(credential: AutomationOperatorCredential?, outcome: Outcome) {
            self.credential = credential
            self.outcome = outcome
        }
    }

    /// Brings the on-disk credential in line with the launch's current opt-in state.
    ///
    /// Reusing rather than re-minting is the load-bearing half: a caller that read
    /// the credential a moment ago must not have its handle invalidated by a routine
    /// configure pass. A credential is reusable only when it names this launch's
    /// socket *and* its handle still resolves as an operator entry in the live
    /// registry — the same fail-closed test a stale credential from a crashed launch
    /// already fails.
    @discardableResult
    public static func refresh(
        optedIn: Bool,
        registry: AutomationHandleRegistry,
        socketPath: String,
        appScopeID: String,
        credentialURL: URL
    ) -> Result {
        if optedIn,
            let existing = AutomationOperatorCredentialStore.load(from: credentialURL),
            existing.socketPath == socketPath,
            registry.resolve(existing.handle)?.isOperator == true
        {
            return Result(credential: existing, outcome: .reused)
        }

        // Read before provisioning clears the file: opting out has to revoke the handle a
        // caller may already be holding, and after the write the handle's name is gone.
        let outgoing = optedIn ? nil : AutomationOperatorCredentialStore.load(from: credentialURL)

        let minted = AutomationOperatorProvisioner.provision(
            optedIn: optedIn,
            registry: registry,
            socketPath: socketPath,
            appScopeID: appScopeID,
            credentialURL: credentialURL
        )

        if let minted {
            return Result(credential: minted, outcome: .minted)
        }
        if let outgoing {
            revoke(handle: outgoing.handle, in: registry)
        }
        if !optedIn {
            // The credential names one handle, but a repair pass can have minted others while
            // an earlier one stayed registered. Opting out has to close all of them (#1391).
            registry.removeAllOperators()
        }
        return Result(credential: nil, outcome: optedIn ? .mintFailed : .notOptedIn)
    }

    /// Removing the file alone is not revocation: a process that read the credential a
    /// moment ago keeps calling with a handle the registry still honors. Turning the
    /// experiment off has to close that door, which is the whole point of turning it off.
    private static func revoke(handle: String, in registry: AutomationHandleRegistry) {
        guard let entry = registry.resolve(handle), entry.isOperator else { return }
        registry.remove(hostSessionID: entry.hostSessionID)
    }
}

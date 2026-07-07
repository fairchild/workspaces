//
//  AutomationOperatorCredentialStore.swift
//  WorkspaceManagerCore
//
//  Reads and writes the per-launch operator credential file (`[A1]`). The file lives next to
//  `automation.sock` under the user-private application-support directory, is user-only (0600),
//  and is removed when the launch ends. Provisioning ties minting to the opt-in gate: opted-in
//  launches mint a handle and write the file; every other launch clears any stale file so a
//  non-opted-in app never leaves an operator credential behind.
//

import Foundation

public enum AutomationOperatorCredentialStore {
    public static let fileName = "automation-operator.json"

    /// The credential file's default location — next to `automation.sock`, so its directory
    /// inherits the same user-private (0700) parent the listener already hardens.
    public static func defaultURL(bundleIdentifier: String) -> URL {
        AutomationListener.defaultSocketURL(bundleIdentifier: bundleIdentifier)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Writes the credential atomically and clamps it to owner-only read/write (0600). The parent
    /// directory is created 0700 if missing (mirrors the listener), so the credential is never
    /// group- or world-readable.
    public static func write(_ credential: AutomationOperatorCredential, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(credential)
        try data.write(to: url, options: [.atomic])
        // `atomic` writes via a temp file + rename, so set the mode after the rename lands.
        chmod(url.path, 0o600)
    }

    public static func load(from url: URL) -> AutomationOperatorCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AutomationOperatorCredential.self, from: data)
    }

    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Ties operator minting to the opt-in gate. This is the single decision point so the same rule is
/// testable in isolation and reused by the app lifecycle: opted-in ⇒ mint a handle in the registry
/// and write the credential; not opted-in ⇒ clear any stale credential and mint nothing.
public enum AutomationOperatorProvisioner {
    @MainActor
    @discardableResult
    public static func provision(
        optedIn: Bool,
        registry: AutomationHandleRegistry,
        socketPath: String,
        appScopeID: String,
        credentialURL: URL
    ) -> AutomationOperatorCredential? {
        guard optedIn else {
            AutomationOperatorCredentialStore.remove(at: credentialURL)
            return nil
        }
        let entry = registry.registerOperator(appScopeID: appScopeID)
        let credential = AutomationOperatorCredential(
            socketPath: socketPath,
            handle: entry.handle,
            capabilities: entry.capabilities
        )
        try? AutomationOperatorCredentialStore.write(credential, to: credentialURL)
        return credential
    }
}

//
//  AutomationOperatorProvisioningTests.swift
//  WorkspaceManagerTests
//
//  The property that matters here is idempotence with a memory: a refresh pass must
//  make the credential match the launch's current opt-in state without invalidating a
//  handle a caller is already holding, and must name which of those it did — that
//  name is what `automation health` reports and what the CLI's failure advice branches
//  on.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("AutomationOperatorProvisioning")
@MainActor
struct AutomationOperatorProvisioningTests {
    private static let socketPath = "/tmp/wm-provisioning.sock"
    private static let appScopeID = "workspaces.local"

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-refresh-\(UUID().uuidString.prefix(8)).json")
    }

    @Test("An opted-in launch with nothing on disk mints")
    func mintsWhenAbsent() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let result = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: AutomationHandleRegistry(),
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )

        #expect(result.outcome == .minted)
        #expect(result.outcome.isCredentialAvailable)
        #expect(AutomationOperatorCredentialStore.load(from: url) == result.credential)
    }

    /// The load-bearing half: a second pass over a live registry must not invalidate the
    /// handle a caller read a moment ago.
    @Test("A second pass over the same registry reuses the credential rather than re-minting")
    func reusesLiveCredential() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }
        let registry = AutomationHandleRegistry()

        let first = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        let second = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )

        #expect(second.outcome == .reused)
        #expect(second.credential == first.credential)
        #expect(registry.resolve(try #require(first.credential).handle)?.isOperator == true)
    }

    /// A credential left by a crashed launch names a handle no live registry knows.
    /// Reusing it would hand back something that fails closed at the first call.
    @Test("A credential whose handle no longer resolves is replaced, not reused")
    func replacesStaleCredential() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let stale = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: AutomationHandleRegistry(),
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        let staleHandle = try #require(stale.credential).handle

        let freshRegistry = AutomationHandleRegistry()
        let refreshed = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: freshRegistry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )

        #expect(refreshed.outcome == .minted)
        #expect(try #require(refreshed.credential).handle != staleHandle)
        #expect(freshRegistry.resolve(staleHandle) == nil)
    }

    @Test("A credential naming a different socket is replaced")
    func replacesCredentialForAnotherSocket() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }
        let registry = AutomationHandleRegistry()

        AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: "/tmp/wm-other.sock",
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        let refreshed = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )

        #expect(refreshed.outcome == .minted)
        #expect(try #require(refreshed.credential).socketPath == Self.socketPath)
    }

    /// The regression this closes: minting used to happen once, at listener start, so a
    /// launch that started with the toggle off stayed credential-less for its whole life
    /// even as health reported the experiment on. A refresh pass is what a later
    /// configure can run.
    @Test("Turning opt-in on after a pass that declined mints on the next pass")
    func optInAfterDeclineMintsOnRefresh() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }
        let registry = AutomationHandleRegistry()

        let declined = AutomationOperatorProvisioning.refresh(
            optedIn: false,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        #expect(declined.outcome == .notOptedIn)
        #expect(!declined.outcome.isCredentialAvailable)
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)

        let enabled = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        #expect(enabled.outcome == .minted)
        #expect(AutomationOperatorCredentialStore.load(from: url) != nil)
    }

    @Test("Turning opt-in off clears the credential and says so")
    func optOutClearsCredential() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }
        let registry = AutomationHandleRegistry()

        AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )
        let cleared = AutomationOperatorProvisioning.refresh(
            optedIn: false,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: url
        )

        #expect(cleared.outcome == .notOptedIn)
        #expect(cleared.credential == nil)
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)
    }

    /// The state that used to be indistinguishable from "never opted in": opted in, no
    /// credential, and nothing anywhere saying why.
    @Test("An opted-in launch that cannot write reports mintFailed rather than nothing")
    func unwritablePathReportsMintFailure() throws {
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-blocker-\(UUID().uuidString.prefix(8))")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        let result = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: AutomationHandleRegistry(),
            socketPath: Self.socketPath,
            appScopeID: Self.appScopeID,
            credentialURL: parentFile.appendingPathComponent("automation-operator.json")
        )

        #expect(result.outcome == .mintFailed)
        #expect(result.credential == nil)
        #expect(!result.outcome.isCredentialAvailable)
    }

    @Test("The health payload carries the outcome, and an older payload without it decodes as unreported")
    func healthDescriptorCarriesOutcome() throws {
        let descriptor = AutomationServerDescriptor(
            pid: 42,
            launchedAt: "2026-08-24T00:00:00Z",
            appVersion: "0.25.0",
            build: "release",
            experiments: ["automationAPI", "automationOperator"],
            operatorCredential: .minted
        )
        let encoded = try JSONEncoder().encode(descriptor)
        #expect(try JSONDecoder().decode(AutomationServerDescriptor.self, from: encoded) == descriptor)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"operatorCredential\":\"minted\""))

        // The field is additive: an app that predates it answers health without the key,
        // and a caller must read that as "this build cannot say", not as "no credential".
        let legacy = """
            {"pid":42,"launchedAt":"2026-08-24T00:00:00Z","appVersion":"0.24.0","build":"release",
             "experiments":["automationAPI"],"protocolVersion":1}
            """
        let decoded = try JSONDecoder().decode(
            AutomationServerDescriptor.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.operatorCredential == nil)
    }
}

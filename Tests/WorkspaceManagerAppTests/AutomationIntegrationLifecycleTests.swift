//
//  AutomationIntegrationLifecycleTests.swift
//  Verifies the App Intents operator gate (Shortcuts mint an operator handle only while the operator
//  experiment is on, re-checked on every call) and where the plane's files live: a lifecycle given a
//  scratch root keeps its socket and credential there, and never removes a credential another launch
//  minted — the path by which `swift test` deleted the installed app's (#1607).
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationIntegrationLifecycle", .serialized)
struct AutomationIntegrationLifecycleTests {
    /// A scratch automation directory with the installed app's file names in it. Short, because the
    /// socket path has to fit `sun_path`.
    private func makeScratchPlane() throws -> (root: URL, files: AutomationPlaneFiles) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let installed = AutomationPlaneFiles.bundled("com.cloudcompute.workspaces")
        func inRoot(_ url: URL) -> URL { root.appendingPathComponent(url.lastPathComponent) }
        let files = AutomationPlaneFiles(
            socketURL: inRoot(installed.socketURL),
            auditURL: inRoot(installed.auditURL),
            credentialURL: inRoot(installed.credentialURL)
        )
        return (root, files)
    }

    @Test("Shortcuts mint is gated on the operator experiment and re-checked per call")
    func appIntentMintGate() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isAutomationAPIEnabled: { false })
        await lifecycle.configure(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        // Gate off: the Shortcuts path fails closed with a clear disabled error and mints nothing.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the disabled operator experiment to fail closed.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
            #expect(error.response.message.contains("Automation Operator Scope"))
        }

        // Gate on: mints one operator handle and reuses it across calls.
        let first = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(lifecycle.handleRegistry.resolve(first.handle)?.isOperator == true)
        let second = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(second.handle == first.handle)

        // The gate runs before the cached-handle fast path: flipping the experiment off
        // mid-launch cuts Shortcuts off even though a handle is already minted.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the re-checked gate to fail closed despite a cached handle.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }

        await lifecycle.stop()
    }

    /// The injected files have to reach the listener and the credential store, not merely be held:
    /// a lifecycle still resolving its bundle's directory binds and mints beside the installed app.
    @Test("A lifecycle given a scratch root listens and mints there, and stopping removes what it minted")
    func planeStaysInsideItsRoot() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let socketPath = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let minted = AutomationOperatorCredentialStore.load(from: plane.files.credentialURL)
        // Stop before asserting, so a failed expectation cannot leave the listener bound.
        await lifecycle.stop()

        #expect(socketPath == plane.files.socketURL.path)
        #expect(minted?.socketPath == socketPath)
        #expect(AutomationOperatorCredentialStore.load(from: plane.files.credentialURL) == nil)
    }

    /// `stop()` releases the socket lock before it clears the credential, so another launch can take
    /// the lock and mint at the same path in between. What this launch removes has to be the
    /// credential it minted, not whatever sits at that path by then.
    @Test("Stopping leaves a credential another launch wrote over the one this launch minted")
    func leavesAReplacedCredential() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let socketPath = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let minted = AutomationOperatorCredentialStore.load(from: plane.files.credentialURL)
        let replacement = AutomationOperatorCredential(socketPath: socketPath, handle: "another-launch")
        try? AutomationOperatorCredentialStore.write(replacement, to: plane.files.credentialURL)
        await lifecycle.stop()

        #expect(minted != nil)
        #expect(AutomationOperatorCredentialStore.load(from: plane.files.credentialURL) == replacement)
    }

    /// #1607 inside a scratch root: the installed app's credential sits at the path this lifecycle
    /// resolves, and the lifecycle is configured and stopped with the Automation API off, as it is in
    /// the test process. Neither pass may remove a file this launch did not mint.
    @Test("Configuring and stopping leaves a credential this launch did not mint")
    func leavesAnotherLaunchsCredential() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let installedAppsCredential = Data(#"{"handle":"installed-app"}"#.utf8)
        try installedAppsCredential.write(to: plane.files.credentialURL)
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isAutomationAPIEnabled: { false })

        await lifecycle.configure(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        #expect(FileManager.default.contents(atPath: plane.files.credentialURL.path) == installedAppsCredential)

        await lifecycle.stop()
        #expect(FileManager.default.contents(atPath: plane.files.credentialURL.path) == installedAppsCredential)
    }
}

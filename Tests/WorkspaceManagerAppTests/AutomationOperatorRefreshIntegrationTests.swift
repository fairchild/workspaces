//
//  AutomationOperatorRefreshIntegrationTests.swift
//  WorkspaceManagerAppTests
//
//  Closes the loop the unit tests leave open. `AutomationOperatorProvisioningTests`
//  proves a refresh pass writes a file and registers a handle; this proves the handle
//  in that file is one a real `AutomationController` accepts for an operator route —
//  which is the claim a caller actually depends on, and the one that was silently
//  false whenever the credential went missing.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Operator credential refresh, end to end")
struct AutomationOperatorRefreshIntegrationTests {
    private static let socketPath = "/tmp/wm-refresh-integration.sock"

    private func scratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-e2e-\(UUID().uuidString.prefix(8)).json")
    }

    private func controller(registry: AutomationHandleRegistry) -> AutomationController {
        AutomationController(
            handleRegistry: registry,
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            workspaceInventory: { AutomationWorkspaceInventory() }
        )
    }

    /// The whole point of the credential: a same-user process reads the file and calls an
    /// operator route with what it found. A refreshed credential has to survive that
    /// round trip, not merely exist on disk.
    @Test("A credential read back off disk is accepted by the live controller for an operator route")
    func refreshedCredentialIsAcceptedByTheController() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let registry = AutomationHandleRegistry()
        let result = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(result.outcome == .minted)

        // Read it the way the CLI does, not from the value refresh returned.
        let fromDisk = try #require(AutomationOperatorCredentialStore.load(from: url))
        #expect(fromDisk.socketPath == Self.socketPath)

        let controller = controller(registry: registry)
        #expect(controller.automationHandleIsOperator(fromDisk.handle))
        // The route the brief's proof runs: `workspaces automation workspace list`.
        let workspaces = try controller.automationWorkspaces(for: fromDisk.handle)
        #expect(workspaces.system.capabilities.contains(.workspaceRead))
    }

    /// The regression, stated as behavior: a launch that provisioned with operator scope
    /// off used to stay unusable for its whole life. A later pass now makes it work
    /// without a relaunch, and the handle it hands out is accepted.
    @Test("A pass after the toggle goes on yields a handle the controller accepts")
    func togglingOnMidLaunchYieldsAUsableHandle() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let registry = AutomationHandleRegistry()
        let controller = controller(registry: registry)

        let declined = AutomationOperatorProvisioning.refresh(
            optedIn: false,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(declined.outcome == .notOptedIn)
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)

        let enabled = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(enabled.outcome == .minted)

        let fromDisk = try #require(AutomationOperatorCredentialStore.load(from: url))
        #expect(try controller.automationWorkspaces(for: fromDisk.handle).system.capabilities.contains(.workspaceRead))
    }

    /// Reuse has to keep the handle valid, not merely keep the file. A pass that
    /// re-minted here would invalidate a handle a caller is already holding.
    @Test("A reused credential's handle stays the one the controller accepts")
    func reusedCredentialKeepsWorking() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let registry = AutomationHandleRegistry()
        let controller = controller(registry: registry)
        let first = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        let heldHandle = try #require(first.credential).handle

        let second = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(second.outcome == .reused)

        // The handle a caller took before the second pass still works after it.
        #expect(controller.automationHandleIsOperator(heldHandle))
        #expect(try controller.automationWorkspaces(for: heldHandle).system.capabilities.contains(.workspaceRead))
    }

    /// Opting out mid-launch has to revoke, not merely stop advertising: the file goes
    /// and the handle stops resolving.
    @Test("Opting out revokes the handle as well as the file")
    func optingOutRevokes() throws {
        let url = scratchURL()
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let registry = AutomationHandleRegistry()
        let controller = controller(registry: registry)
        let minted = AutomationOperatorProvisioning.refresh(
            optedIn: true,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        let handle = try #require(minted.credential).handle
        #expect(controller.automationHandleIsOperator(handle))

        AutomationOperatorProvisioning.refresh(
            optedIn: false,
            registry: registry,
            socketPath: Self.socketPath,
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)
        #expect(!controller.automationHandleIsOperator(handle))
    }
}

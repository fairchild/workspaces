// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
private final class FakeWorkspacesAppIntentController: AutomationControlling {
    var inventoryHandles: [String] = []
    var selectCalls: [(handle: String, workspaceID: String)] = []
    var createCalls: [(handle: String, request: AutomationWorkspaceCreateRequest)] = []
    var createResult: AutomationWorkspaceCreateResult?
    var createError: AutomationServiceError?

    let repoID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let workspaceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let surfaceID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!

    func automationContext(for handle: String) throws -> AutomationContextResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWindows(for handle: String) throws -> AutomationWindowsResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult {
        guard handle == "operator" else {
            throw AutomationServiceError(.capabilityDenied, "Missing workspace.read.")
        }
        inventoryHandles.append(handle)
        return AutomationWorkspacesResult(
            repos: [
                AutomationRepoDescriptor(
                    repoID: repoID,
                    name: "workspaces",
                    path: "/Users/test/workspaces",
                    isSelected: true
                )
            ],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: workspaceID,
                    repoID: repoID,
                    name: "feature-a",
                    path: "/Users/test/workspaces/feature-a",
                    branch: "feature-a",
                    status: "active",
                    isArchived: false,
                    backend: "local",
                    isSelected: true
                )
            ]
        )
    }

    func automationSelectWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult {
        guard handle == "operator" else {
            throw AutomationServiceError(.capabilityDenied, "Missing workspace.select.")
        }
        selectCalls.append((handle, workspaceID))
        return AutomationWorkspaceSelectResult(
            workspaceID: workspaceID,
            outcome: .completed,
            changed: true,
            selectedWorkspaceID: UUID(uuidString: workspaceID),
            attachedTerminal: true,
            attachedSurfaceID: surfaceID.uuidString
        )
    }

    func automationCreateWorkspace(
        for handle: String,
        request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult {
        guard handle == "operator" else {
            throw AutomationServiceError(.capabilityDenied, "Missing workspace.create.")
        }
        if let createError {
            throw createError
        }
        createCalls.append((handle, request))
        return createResult
            ?? AutomationWorkspaceCreateResult(
                repoID: request.repoID,
                workspaceID: UUID(uuidString: "88888888-8888-8888-8888-888888888888"),
                workspaceName: request.name,
                workspacePath: "/Users/test/workspaces/\(request.name)",
                outcome: .completed,
                changed: true,
                selectedWorkspaceID: UUID(uuidString: "88888888-8888-8888-8888-888888888888"),
                attachedTerminal: true,
                attachedSurfaceID: surfaceID.uuidString
            )
    }

    func automationArchiveWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceArchiveResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWindowSnapshot(
        for handle: String,
        windowID: String
    ) async throws -> AutomationWindowSnapshotResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationReadSurface(
        for handle: String,
        request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWebSurfaceSnapshot(
        for handle: String,
        sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationCloseTile(for handle: String) throws -> AutomationMutationResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationWriteInput(
        for handle: String,
        text: String,
        submit: Bool
    ) throws -> AutomationInputWriteResult {
        throw AutomationServiceError(.unsupported, "Not used by App Intents.")
    }

    func automationHandleIsOperator(_ handle: String) -> Bool {
        handle == "operator"
    }
}

@MainActor
@Suite("Workspaces App Intents")
struct WorkspacesAppIntentsTests {
    @Test("shortcuts provider registers list select and create")
    func shortcutsProviderRegistersAllShippedVerbs() {
        #expect(WorkspacesAppShortcutsProvider.appShortcuts.count == 3)
    }

    @Test("list inventory calls the shared automation workspace route")
    func listUsesAutomationWorkspaceRoute() throws {
        let controller = FakeWorkspacesAppIntentController()
        let client = WorkspacesAppIntentAutomationClient {
            (controller, "operator")
        }

        let inventory = try client.inventory()

        #expect(controller.inventoryHandles == ["operator"])
        #expect(inventory.repos.map(\.repoID) == [controller.repoID])
        #expect(inventory.workspaces.map(\.workspaceID) == [controller.workspaceID])
    }

    @Test("select calls the shared automation select route")
    func selectUsesAutomationSelectRoute() async throws {
        let controller = FakeWorkspacesAppIntentController()
        let client = WorkspacesAppIntentAutomationClient {
            (controller, "operator")
        }

        let result = try await client.select(workspaceID: controller.workspaceID.uuidString)

        #expect(controller.selectCalls.map(\.handle) == ["operator"])
        #expect(controller.selectCalls.map(\.workspaceID) == [controller.workspaceID.uuidString])
        #expect(result.outcome == .completed)
        #expect(result.attachedTerminal)
        #expect(result.attachedSurfaceID == controller.surfaceID.uuidString)
    }

    @Test("create confirmation stays structured for the intent confirmation prompt")
    func createConfirmationSurfacesAsIntentOutcome() async throws {
        let controller = FakeWorkspacesAppIntentController()
        let confirmation = AutomationConfirmationRequirement(
            action: "workspace.create",
            title: "Set Up Provider",
            message: "Create workspace requires provider setup.",
            providerID: "lume",
            providerDisplayName: "Lume",
            primaryButtonTitle: "Set Up"
        )
        controller.createResult = AutomationWorkspaceCreateResult(
            repoID: controller.repoID.uuidString,
            workspaceName: "vm-workspace",
            outcome: .confirmationRequired,
            changed: false,
            confirmation: confirmation,
            message: confirmation.message
        )
        let client = WorkspacesAppIntentAutomationClient {
            (controller, "operator")
        }

        let outcome = try await client.create(
            repoID: controller.repoID.uuidString,
            name: "vm-workspace",
            providerID: "lume",
            guestOS: .macOS
        )

        #expect(controller.createCalls.count == 1)
        #expect(controller.createCalls.first?.request.providerID == "lume")
        #expect(controller.createCalls.first?.request.guestOS == .macOS)
        guard case .confirmationRequired(let requirement) = outcome else {
            Issue.record("Expected confirmationRequired, got \(outcome).")
            return
        }
        #expect(requirement == confirmation)
    }

    @Test("unsupported automation errors become clear intent errors")
    func unsupportedMapsToIntentError() async throws {
        let controller = FakeWorkspacesAppIntentController()
        controller.createError = AutomationServiceError(
            .unsupported,
            "No WorkSpaces window is attached; workspace.create requires a live window."
        )
        let client = WorkspacesAppIntentAutomationClient {
            (controller, "operator")
        }

        do {
            _ = try await client.create(
                repoID: controller.repoID.uuidString,
                name: "blocked",
                providerID: nil,
                guestOS: nil
            )
            Issue.record("Expected unsupported to map to a WorkspacesAppIntentError.")
        } catch let error as WorkspacesAppIntentError {
            guard case .automation(let response) = error else {
                Issue.record("Expected automation error, got \(error).")
                return
            }
            #expect(response.code == .unsupported)
            #expect(response.message.contains("workspace.create requires a live window"))
        }
    }
}

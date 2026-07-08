//
//  AutomationArchiveVerbTests.swift
//  WorkspaceManagerAppTests
//
//  Exercises the real AutomationController.automationArchiveWorkspace against a real handle registry:
//  operator-scope capability enforcement, completed/unsupported/invalid_request outcome mapping, and
//  the selected-workspace fallback reported after the real archive gesture runs.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationController workspace.archive")
struct AutomationArchiveVerbTests {
    private func expectFailure(
        _ code: AutomationErrorCode,
        _ body: () async throws -> some Any
    ) async {
        do {
            _ = try await body()
            Issue.record("Expected \(code.rawValue) but the call succeeded.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == code)
        } catch {
            Issue.record("Expected AutomationServiceError but got \(error).")
        }
    }

    private func operatorController(
        gestureVerbs: AutomationGestureVerbs?
    ) -> (AutomationController, registry: AutomationHandleRegistry, operatorHandle: String) {
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: gestureVerbs
        )
        return (controller, registry, entry.handle)
    }

    @Test("operator handle with a live archive layer completes and reports selected fallback")
    func operatorCompletes() async throws {
        let id = UUID()
        let selected = UUID()
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in
                $0 == id
                    ? AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                    : nil
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { target in
                .completed(
                    AutomationWorkspaceArchiveEffect(
                        workspaceID: target.workspaceID,
                        selectedWorkspaceID: selected))
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationArchiveWorkspace(
            for: handle, workspaceID: id.uuidString)

        #expect(result.outcome == .completed)
        #expect(result.changed)
        #expect(result.archivedWorkspaceID == id)
        #expect(result.selectedWorkspaceID == selected)
        #expect(result.system.capabilities.contains(.workspaceArchive))
    }

    @Test("a tile handle lacks workspace.archive and is denied")
    func tileHandleDenied() async throws {
        let (controller, registry, _) = operatorController(gestureVerbs: nil)
        let tile = registry.upsert(
            hostSessionID: UUID(),
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "workspaces.local"
        )

        await expectFailure(.capabilityDenied) {
            try await controller.automationArchiveWorkspace(
                for: tile.handle, workspaceID: UUID().uuidString)
        }
    }

    @Test("no live gesture layer is unsupported")
    func noWindowUnsupported() async throws {
        let (controller, _, handle) = operatorController(gestureVerbs: nil)

        await expectFailure(.unsupported) {
            try await controller.automationArchiveWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
    }

    @Test("detaching the gesture layer makes archive unsupported")
    func detachedGestureLayerIsUnsupported() async throws {
        var drove = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: {
                AutomationGestureVerbs.WorkspaceTarget(workspaceID: $0, name: "ws", isArchived: false)
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { target in
                drove = true
                return .completed(
                    AutomationWorkspaceArchiveEffect(workspaceID: target.workspaceID, selectedWorkspaceID: nil))
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        controller.detachGestureVerbs()

        await expectFailure(.unsupported) {
            try await controller.automationArchiveWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
        #expect(!drove)
    }

    @Test("a non-UUID id is invalid_request")
    func badUUIDInvalid() async throws {
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { _ in .unsupported("should not run") }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationArchiveWorkspace(for: handle, workspaceID: "not-a-uuid")
        }
    }

    @Test("a well-shaped but unknown id is invalid_request and never drives the gesture")
    func unknownIDInvalid() async throws {
        var performed = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { _ in
                performed = true
                return .unsupported("should not run")
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationArchiveWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
        #expect(!performed)
    }
}

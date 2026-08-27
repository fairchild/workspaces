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
    /// One window installs the layer these suites drive; a teardown names it, so an
    /// overlapping window's teardown cannot clear it (#1375).
    private static let windowOwner = UUID()

    private func expectFailure(
        _ code: AutomationErrorCode,
        retryable: Bool? = nil,
        _ body: () async throws -> some Any
    ) async {
        do {
            _ = try await body()
            Issue.record("Expected \(code.rawValue) but the call succeeded.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == code)
            #expect(error.response.retryable == retryable)
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
            gestureVerbs: gestureVerbs,
            windowBoundOwner: Self.windowOwner
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
            performArchive: { target, _ in
                .completed(
                    AutomationWorkspaceArchiveEffect(
                        workspaceID: target.workspaceID,
                        selectedWorkspaceID: selected))
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationArchiveWorkspace(
            for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: id.uuidString))

        #expect(result.outcome == .completed)
        #expect(result.changed)
        #expect(result.archivedWorkspaceID == id)
        #expect(result.selectedWorkspaceID == selected)
        #expect(result.teardown == nil)
        #expect(result.system.capabilities.contains(.workspaceArchive))
    }

    @Test("teardownTerminals rides the command into the gesture and the report rides the result")
    func teardownCommandAndReport() async throws {
        let id = UUID()
        let report = AutomationWorkspaceArchiveTeardownReport(
            retiredSurfaceIDs: [UUID().uuidString, UUID().uuidString],
            killedTmuxSessions: ["wm-ws-12345678"]
        )
        var receivedCommand: AutomationWorkspaceArchiveCommand?
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
            performArchive: { target, command in
                receivedCommand = command
                return .completed(
                    AutomationWorkspaceArchiveEffect(
                        workspaceID: target.workspaceID,
                        selectedWorkspaceID: nil,
                        teardown: report))
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationArchiveWorkspace(
            for: handle,
            request: AutomationWorkspaceArchiveRequest(
                workspaceID: id.uuidString, teardownTerminals: true))

        #expect(receivedCommand?.teardownTerminals == true)
        #expect(receivedCommand?.workspaceID == id)
        #expect(result.outcome == .completed)
        #expect(result.teardown == report)
    }

    @Test("terminal-still-live maps to typed terminal_active with retryable true")
    func terminalActiveIsTypedRetryable() async throws {
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: {
                AutomationGestureVerbs.WorkspaceTarget(workspaceID: $0, name: "ws", isArchived: false)
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { _, _ in
                .terminalActive("Terminal 'ws' did not exit before the workspace lifecycle timeout.")
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.terminalActive, retryable: true) {
            try await controller.automationArchiveWorkspace(
                for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: UUID().uuidString))
        }
    }

    @Test("confirmation-blocked teardown maps to typed close_blocked_by_confirmation, not retryable")
    func closeBlockedByConfirmationIsTypedNonRetryable() async throws {
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: {
                AutomationGestureVerbs.WorkspaceTarget(workspaceID: $0, name: "ws", isArchived: false)
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            performArchive: { _, _ in
                .closeBlockedByConfirmation("Terminal teardown was blocked by the close confirmation.")
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.closeBlockedByConfirmation, retryable: false) {
            try await controller.automationArchiveWorkspace(
                for: handle,
                request: AutomationWorkspaceArchiveRequest(
                    workspaceID: UUID().uuidString, teardownTerminals: true))
        }
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
                for: tile.handle, request: AutomationWorkspaceArchiveRequest(workspaceID: UUID().uuidString))
        }
    }

    @Test("no live gesture layer is unsupported")
    func noWindowUnsupported() async throws {
        let (controller, _, handle) = operatorController(gestureVerbs: nil)

        await expectFailure(.unsupported) {
            try await controller.automationArchiveWorkspace(
                for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: UUID().uuidString))
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
            performArchive: { target, _ in
                drove = true
                return .completed(
                    AutomationWorkspaceArchiveEffect(workspaceID: target.workspaceID, selectedWorkspaceID: nil))
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        controller.detachGestureVerbs(owner: Self.windowOwner)

        await expectFailure(.unsupported) {
            try await controller.automationArchiveWorkspace(
                for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: UUID().uuidString))
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
            performArchive: { _, _ in .unsupported("should not run") }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationArchiveWorkspace(
                for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: "not-a-uuid"))
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
            performArchive: { _, _ in
                performed = true
                return .unsupported("should not run")
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationArchiveWorkspace(
                for: handle, request: AutomationWorkspaceArchiveRequest(workspaceID: UUID().uuidString))
        }
        #expect(!performed)
    }
}

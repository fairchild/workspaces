//
//  AutomationSelectVerbTests.swift
//  WorkspaceManagerAppTests
//
//  Exercises the real AutomationController.automationSelectWorkspace against a real handle registry
//  and a real TileTreeStore: operator-scope capability enforcement, the completed/unsupported/
//  invalid_request outcome mapping, and the named wrong-PTY regression — selecting workspace A then B
//  makes each workspace's own terminal the active surface a following input would land in.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationController workspace.select")
struct AutomationSelectVerbTests {
    /// Runs `body` expecting it to throw an `AutomationServiceError` with `code`, matching the
    /// do/catch assertion style used elsewhere in the automation tests.
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

    @Test("operator handle with a live gesture layer completes and reports the attach")
    func operatorCompletes() async throws {
        let id = UUID()
        let surface = UUID()
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in
                $0 == id
                    ? AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                    : nil
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: id, attachedSurfaceID: surface, attachedTerminal: true)
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationSelectWorkspace(
            for: handle, workspaceID: id.uuidString)

        #expect(result.outcome == .completed)
        #expect(result.changed)
        #expect(result.attachedTerminal)
        #expect(result.attachedSurfaceID == surface.uuidString)
        #expect(result.selectedWorkspaceID == id)
        #expect(result.system.capabilities.contains(.workspaceSelect))
    }

    @Test("a tile handle lacks workspace.select and is denied")
    func tileHandleDenied() async throws {
        let (controller, registry, _) = operatorController(gestureVerbs: nil)
        // A tile handle carries the v1 tile capabilities but not workspace.select.
        let tile = registry.upsert(
            hostSessionID: UUID(),
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "workspaces.local"
        )

        await expectFailure(.capabilityDenied) {
            try await controller.automationSelectWorkspace(
                for: tile.handle, workspaceID: UUID().uuidString)
        }
    }

    @Test("no live gesture layer is unsupported, never a data-layer fallback")
    func noWindowUnsupported() async throws {
        let (controller, _, handle) = operatorController(gestureVerbs: nil)

        await expectFailure(.unsupported) {
            try await controller.automationSelectWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
    }

    @Test("a non-UUID id is invalid_request")
    func badUUIDInvalid() async throws {
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationSelectWorkspace(for: handle, workspaceID: "not-a-uuid")
        }
    }

    @Test("a well-shaped but unknown id is invalid_request and never drives the gesture")
    func unknownIDInvalid() async throws {
        var performed = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                performed = true
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        await expectFailure(.invalidRequest) {
            try await controller.automationSelectWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
        #expect(!performed)
    }

    /// Wrong-PTY regression against a real TileTreeStore: the gesture activates the selected
    /// workspace's own host session, so the store's active session — where a following input lands —
    /// follows the select. Selecting A makes A's session active; selecting B switches it to B, leaving
    /// no stale A surface to misroute the next write.
    @Test("selecting workspace A then workspace B routes input to each workspace's own PTY")
    func selectingWorkspaceAThenInputLandsInASPTY() async throws {
        let store = TileTreeStore()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let pathA = "/tmp/wrong-pty-smoke/workspace-a"
        let pathB = "/tmp/wrong-pty-smoke/workspace-b"
        let pathByID = [workspaceA: pathA, workspaceB: pathB]

        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { id in
                pathByID[id].map {
                    _ in AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                }
            },
            performSelection: { target in
                let path = pathByID[target.workspaceID]!
                // The real selection gesture attaches (and activates) the workspace's terminal.
                let session = store.activateSession(
                    key: .hostPath(path), directory: URL(fileURLWithPath: path)
                ).session
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: target.workspaceID,
                    attachedSurfaceID: store.activeSessionID,
                    attachedTerminal: session.id == store.activeSessionID
                )
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let selectA = try await controller.automationSelectWorkspace(
            for: handle, workspaceID: workspaceA.uuidString)
        let sessionA = try #require(store.activeSessionID)
        #expect(selectA.attachedSurfaceID == sessionA.uuidString)
        // Input now targets the active surface, which is A's session.
        #expect(store.sessions.first(where: { $0.id == sessionA })?.directoryPath == pathA)

        let selectB = try await controller.automationSelectWorkspace(
            for: handle, workspaceID: workspaceB.uuidString)
        let sessionB = try #require(store.activeSessionID)
        #expect(selectB.attachedSurfaceID == sessionB.uuidString)
        #expect(sessionB != sessionA)
        // The active surface switched to B — a following input lands in B's PTY, not A's stale one.
        #expect(store.sessions.first(where: { $0.id == sessionB })?.directoryPath == pathB)
    }
}

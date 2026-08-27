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
    /// One window installs the layer these suites drive; a teardown names it, so an
    /// overlapping window's teardown cannot clear it (#1375).
    private static let windowOwner = UUID()

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
            gestureVerbs: gestureVerbs,
            windowBoundOwner: Self.windowOwner
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

    /// Windows are not exclusive and their lifecycles overlap: a second window installs its own
    /// layer while the first is still up, and a replaced window's teardown lands after its
    /// successor's configure. Clearing on any teardown left the app answering `unsupported` to
    /// every mutation verb while a window was open and focused, until the app was restarted
    /// (#1375).
    @Test("a departed window's teardown leaves the live window's gesture layer alone")
    func teardownFromAnotherWindowLeavesTheLayerInstalled() async throws {
        let id = UUID()
        var drove = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in
                $0 == id
                    ? AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                    : nil
            },
            performSelection: { _ in
                drove = true
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: id, attachedSurfaceID: UUID(), attachedTerminal: true)
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        // A different window — one that never installed this layer — goes away.
        controller.detachGestureVerbs(owner: UUID())

        let result = try await controller.automationSelectWorkspace(
            for: handle, workspaceID: id.uuidString)

        #expect(result.outcome == .completed)
        #expect(drove)
    }

    /// The owner is what a teardown is checked against, so a window that installs, hands the
    /// layer to a successor, and only then tears down must not take the successor's layer with it.
    @Test("a superseded window's teardown does not clear its successor's layer")
    func supersededWindowTeardownDoesNotClearSuccessor() async throws {
        let firstWindow = UUID()
        let secondWindow = UUID()
        let id = UUID()
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { [id] in
                $0 == id
                    ? AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                    : nil
            },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: id, attachedSurfaceID: UUID(), attachedTerminal: true)
            }
        )
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let store = TileTreeStore()
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: verbs,
            windowBoundOwner: firstWindow
        )

        // The successor installs its own layer, then the superseded window finally tears down.
        controller.update(
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: verbs,
            windowBoundOwner: secondWindow
        )
        controller.detachGestureVerbs(owner: firstWindow)

        let result = try await controller.automationSelectWorkspace(
            for: entry.handle, workspaceID: id.uuidString)
        #expect(result.outcome == .completed)

        // The successor's own teardown still closes the layer.
        controller.detachGestureVerbs(owner: secondWindow)
        await expectFailure(.unsupported) {
            try await controller.automationSelectWorkspace(for: entry.handle, workspaceID: id.uuidString)
        }
    }

    /// The case a single slot could not express: two windows are open, the newer one closes, and
    /// the older is still on screen. Clearing on its teardown left the app answering `unsupported`
    /// to a window the user was looking at (#1375).
    @Test("closing the newer window leaves the older live window driveable")
    func closingNewerWindowLeavesOlderWindowDriveable() async throws {
        let olderWindow = UUID()
        let newerWindow = UUID()
        let id = UUID()
        var droveThrough: [String] = []
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let store = TileTreeStore()
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: selectVerbs(id: id, label: "older", into: { droveThrough.append($0) }),
            windowBoundOwner: olderWindow
        )
        controller.update(
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: selectVerbs(id: id, label: "newer", into: { droveThrough.append($0) }),
            windowBoundOwner: newerWindow
        )

        controller.detachGestureVerbs(owner: newerWindow)

        let result = try await controller.automationSelectWorkspace(
            for: entry.handle, workspaceID: id.uuidString)
        #expect(result.outcome == .completed)
        // The surviving window is the one that drives, not the closed one.
        #expect(droveThrough == ["older"])

        // And when it too closes, nothing is left to drive.
        controller.detachGestureVerbs(owner: olderWindow)
        await expectFailure(.unsupported) {
            try await controller.automationSelectWorkspace(for: entry.handle, workspaceID: id.uuidString)
        }
    }

    /// A `configure` that suspended on the listener can land after its window is gone. The install
    /// is allowed — nothing cancels it — but a dead window's layer must never be the one a verb
    /// runs through (#1375).
    @Test("a configure landing after its window closed does not resurrect it")
    func lateConfigureFromAClosedWindowIsNotDriveable() async {
        let departedWindow = UUID()
        let id = UUID()
        var drove = false
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let store = TileTreeStore()
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        // The window has already torn down by the time its configure completes.
        controller.update(
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: selectVerbs(id: id, label: "departed", into: { _ in drove = true }),
            windowBoundOwner: departedWindow,
            isWindowLive: { false }
        )

        await expectFailure(.unsupported) {
            try await controller.automationSelectWorkspace(for: entry.handle, workspaceID: id.uuidString)
        }
        #expect(!drove)
    }

    private func selectVerbs(
        id: UUID,
        label: String,
        into record: @escaping @MainActor (String) -> Void
    ) -> AutomationGestureVerbs {
        AutomationGestureVerbs(
            resolveWorkspace: { [id] in
                $0 == id
                    ? AutomationGestureVerbs.WorkspaceTarget(workspaceID: id, name: "ws", isArchived: false)
                    : nil
            },
            performSelection: { _ in
                record(label)
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: id, attachedSurfaceID: UUID(), attachedTerminal: true)
            }
        )
    }

    @Test("detaching the gesture layer (window gone) makes select unsupported, not a stale drive")
    func detachedGestureLayerIsUnsupported() async throws {
        var drove = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: {
                AutomationGestureVerbs.WorkspaceTarget(workspaceID: $0, name: "ws", isArchived: false)
            },
            performSelection: { _ in
                drove = true
                return AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        // The window that installed the gesture layer disappears (the app lingers as an accessory).
        controller.detachGestureVerbs(owner: Self.windowOwner)

        await expectFailure(.unsupported) {
            try await controller.automationSelectWorkspace(
                for: handle, workspaceID: UUID().uuidString)
        }
        // Fail closed: the stale gesture is never driven after detach.
        #expect(!drove)
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

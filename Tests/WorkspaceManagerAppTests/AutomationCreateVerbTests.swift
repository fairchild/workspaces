//
//  AutomationCreateVerbTests.swift
//  WorkspaceManagerAppTests
//
//  Exercises the real AutomationController.automationCreateWorkspace against a real handle registry
//  and TileTreeStore: operator-scope capability enforcement, completed/confirmation/unsupported
//  outcome mapping, and the wrong-PTY guard for a newly created workspace.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationController workspace.create")
struct AutomationCreateVerbTests {
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

    @Test("operator handle with a live create layer completes and reports the attach")
    func operatorCompletes() async throws {
        let repoID = UUID()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "repo", path: "/tmp/repo")
                    : nil
            },
            performCreation: { _, command in
                #expect(command.shouldSelect)
                #expect(command.fromRef == nil)
                return .completed(
                    AutomationWorkspaceCreateEffect(
                        repoID: repoID,
                        workspaceID: workspaceID,
                        workspaceName: command.name,
                        workspacePath: "/tmp/repo/\(command.name)",
                        selectedWorkspaceID: workspaceID,
                        attachedSurfaceID: surfaceID,
                        attachedTerminal: true
                    )
                )
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationCreateWorkspace(
            for: handle,
            request: AutomationWorkspaceCreateRequest(repoID: repoID.uuidString, name: "created")
        )

        #expect(result.outcome == .completed)
        #expect(result.changed)
        #expect(result.workspaceID == workspaceID)
        #expect(result.attachedTerminal)
        #expect(result.attachedSurfaceID == surfaceID.uuidString)
        #expect(result.selectedWorkspaceID == workspaceID)
        #expect(result.system.capabilities.contains(.workspaceCreate))
    }

    @Test("select false creates without changing the active surface")
    func selectFalsePreservesActiveSurface() async throws {
        let store = TileTreeStore()
        let repoID = UUID()
        let workspaceID = UUID()
        let staleSession = store.activateSession(
            key: .repoPath("/tmp/repo"),
            directory: URL(fileURLWithPath: "/tmp/repo")
        ).session
        var observedCommand: AutomationWorkspaceCreateCommand?

        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "repo", path: "/tmp/repo")
                    : nil
            },
            performCreation: { _, command in
                observedCommand = command
                return .completed(
                    AutomationWorkspaceCreateEffect(
                        repoID: repoID,
                        workspaceID: workspaceID,
                        workspaceName: command.name,
                        workspacePath: "/tmp/repo/\(command.name)",
                        selectedWorkspaceID: nil,
                        attachedSurfaceID: nil,
                        attachedTerminal: false
                    )
                )
            }
        )
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: verbs
        )

        let result = try await controller.automationCreateWorkspace(
            for: entry.handle,
            request: AutomationWorkspaceCreateRequest(
                repoID: repoID.uuidString,
                name: "created",
                select: false,
                fromRef: "origin/main"
            )
        )

        #expect(observedCommand?.shouldSelect == false)
        #expect(observedCommand?.fromRef == "origin/main")
        #expect(result.outcome == .completed)
        #expect(result.workspaceID == workspaceID)
        #expect(result.selectedWorkspaceID == nil)
        #expect(!result.attachedTerminal)
        #expect(result.attachedSurfaceID == nil)
        #expect(store.activeSessionID == staleSession.id)
    }

    @Test("a tile handle lacks workspace.create and is denied")
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
            try await controller.automationCreateWorkspace(
                for: tile.handle,
                request: AutomationWorkspaceCreateRequest(repoID: UUID().uuidString, name: "created")
            )
        }
    }

    @Test("no live gesture layer is unsupported")
    func noWindowUnsupported() async throws {
        let (controller, _, handle) = operatorController(gestureVerbs: nil)

        await expectFailure(.unsupported) {
            try await controller.automationCreateWorkspace(
                for: handle,
                request: AutomationWorkspaceCreateRequest(repoID: UUID().uuidString, name: "created")
            )
        }
    }

    @Test("detaching the gesture layer makes create unsupported")
    func detachedGestureLayerIsUnsupported() async throws {
        var drove = false
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: {
                AutomationGestureVerbs.RepoTarget(repoID: $0, name: "repo", path: "/tmp/repo")
            },
            performCreation: { _, _ in
                drove = true
                return .unsupported("should not run")
            }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        controller.detachGestureVerbs(owner: Self.windowOwner)

        await expectFailure(.unsupported) {
            try await controller.automationCreateWorkspace(
                for: handle,
                request: AutomationWorkspaceCreateRequest(repoID: UUID().uuidString, name: "created")
            )
        }
        #expect(!drove)
    }

    @Test("confirmation requirements return a structured success outcome")
    func confirmationRequired() async throws {
        let repoID = UUID()
        let confirmation = AutomationConfirmationRequirement(
            action: "workspace.create",
            title: "Set Up Provider",
            message: "Create workspace requires setup confirmation.",
            providerID: "provider",
            providerDisplayName: "Provider",
            primaryButtonTitle: "Set Up"
        )
        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "repo", path: "/tmp/repo")
                    : nil
            },
            performCreation: { _, _ in .confirmationRequired(confirmation) }
        )
        let (controller, _, handle) = operatorController(gestureVerbs: verbs)

        let result = try await controller.automationCreateWorkspace(
            for: handle,
            request: AutomationWorkspaceCreateRequest(repoID: repoID.uuidString, name: "created")
        )

        #expect(result.outcome == .confirmationRequired)
        #expect(!result.changed)
        #expect(result.confirmation == confirmation)
        #expect(result.message == confirmation.message)
    }

    @Test("input after create targets the newly created workspace surface")
    func createThenInputTargetsCreatedWorkspacePTY() async throws {
        let store = TileTreeStore()
        let repoID = UUID()
        let workspaceID = UUID()
        let staleSession = store.activateSession(
            key: .repoPath("/tmp/repo"),
            directory: URL(fileURLWithPath: "/tmp/repo")
        ).session
        let workspacePath = "/tmp/repo/workspaces/created"

        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "repo", path: "/tmp/repo")
                    : nil
            },
            performCreation: { _, command in
                let session = store.activateSession(
                    key: .hostPath(workspacePath),
                    directory: URL(fileURLWithPath: workspacePath)
                ).session
                return .completed(
                    AutomationWorkspaceCreateEffect(
                        repoID: repoID,
                        workspaceID: workspaceID,
                        workspaceName: command.name,
                        workspacePath: workspacePath,
                        selectedWorkspaceID: workspaceID,
                        attachedSurfaceID: session.id,
                        attachedTerminal: true
                    )
                )
            }
        )
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: verbs
        )

        let result = try await controller.automationCreateWorkspace(
            for: entry.handle,
            request: AutomationWorkspaceCreateRequest(repoID: repoID.uuidString, name: "created")
        )
        let activeSessionID = try #require(store.activeSessionID)

        #expect(result.attachedSurfaceID == activeSessionID.uuidString)
        #expect(activeSessionID != staleSession.id)
        #expect(store.sessions.first(where: { $0.id == activeSessionID })?.directoryPath == workspacePath)
    }

    @Test("surface.read reads any live terminal surface for operator handles; tile handles stay denied")
    func surfaceReadIsOperatorScopedAcrossLiveSurfaces() async throws {
        let store = TileTreeStore()
        let repoID = UUID()
        let workspaceID = UUID()
        let otherSession = store.activateSession(
            key: .repoPath("/tmp/repo"),
            directory: URL(fileURLWithPath: "/tmp/repo")
        ).session
        var createdSurfaceID: UUID?
        var reads: [UUID] = []

        let verbs = AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "repo", path: "/tmp/repo")
                    : nil
            },
            performCreation: { _, command in
                let session = store.activateSession(
                    key: .hostPath("/tmp/repo/workspaces/\(command.name)"),
                    directory: URL(fileURLWithPath: "/tmp/repo/workspaces/\(command.name)")
                ).session
                createdSurfaceID = session.id
                return .completed(
                    AutomationWorkspaceCreateEffect(
                        repoID: repoID,
                        workspaceID: workspaceID,
                        workspaceName: command.name,
                        workspacePath: session.directoryPath,
                        selectedWorkspaceID: workspaceID,
                        attachedSurfaceID: session.id,
                        attachedTerminal: true
                    )
                )
            }
        )
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let operatorEntry = registry.registerOperator(appScopeID: "workspaces.local")
        let otherOperator = registry.registerOperator(appScopeID: "workspaces.local")
        let tile = registry.upsert(
            hostSessionID: otherSession.id,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "workspaces.local"
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            surfaceTextReader: { _, surfaceID in
                reads.append(surfaceID)
                return "one\ntwo\nthree"
            },
            gestureVerbs: verbs
        )

        _ = try await controller.automationCreateWorkspace(
            for: operatorEntry.handle,
            request: AutomationWorkspaceCreateRequest(repoID: repoID.uuidString, name: "created")
        )
        let surfaceID = try #require(createdSurfaceID)

        let result = try controller.automationReadSurface(
            for: operatorEntry.handle,
            request: AutomationSurfaceReadRequest(surfaceID: surfaceID.uuidString, lines: 2)
        )
        #expect(result.text == "two\nthree")
        #expect(result.returnedLines == 2)
        #expect(reads == [surfaceID])

        // Operator reach is any live terminal surface, not only created-this-launch ones:
        // surface.read is read-only, opt-in per launch, and audited per call, and the wait
        // primitive's text/prompt conditions need the same reach (#1225 relaxation).
        let crossOperator = try controller.automationReadSurface(
            for: otherOperator.handle,
            request: AutomationSurfaceReadRequest(surfaceID: surfaceID.uuidString, lines: 2)
        )
        #expect(crossOperator.text == "two\nthree")
        let nonCreated = try controller.automationReadSurface(
            for: operatorEntry.handle,
            request: AutomationSurfaceReadRequest(surfaceID: otherSession.id.uuidString, lines: 2)
        )
        #expect(nonCreated.surfaceID == otherSession.id.uuidString)

        // Tile handles never carry surface.read — the operator-scope boundary is unchanged.
        await expectFailure(.capabilityDenied) {
            try controller.automationReadSurface(
                for: tile.handle,
                request: AutomationSurfaceReadRequest(surfaceID: surfaceID.uuidString, lines: 2)
            )
        }
    }

    @Test("surface.read clamps over-cap line requests and byte output")
    func surfaceReadClampsLinesAndBytes() throws {
        let store = TileTreeStore()
        let session = store.activateSession(
            key: .repoPath("/tmp/repo"),
            directory: URL(fileURLWithPath: "/tmp/repo")
        ).session
        let registry = AutomationHandleRegistry()
        let operatorEntry = registry.registerOperator(appScopeID: "workspaces.local")
        registry.recordWorkspaceCreation(operatorHandle: operatorEntry.handle, hostSessionID: session.id)
        let longLines = (0..<600).map { index in
            "\(index)-" + String(repeating: "x", count: 1024)
        }.joined(separator: "\n")
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: store,
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            surfaceTextReader: { _, _ in longLines }
        )

        let result = try controller.automationReadSurface(
            for: operatorEntry.handle,
            request: AutomationSurfaceReadRequest(surfaceID: session.id.uuidString, lines: 10_000)
        )

        #expect(result.requestedLines == 10_000)
        #expect(result.lines == AutomationAPI.surfaceReadMaxLines)
        #expect(result.returnedLines <= AutomationAPI.surfaceReadMaxLines)
        #expect(result.byteCount <= AutomationAPI.surfaceReadMaxUTF8Bytes)
        #expect(result.text.contains("599-"))
    }
}

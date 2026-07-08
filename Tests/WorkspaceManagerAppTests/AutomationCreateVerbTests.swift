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

        controller.detachGestureVerbs()

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
}

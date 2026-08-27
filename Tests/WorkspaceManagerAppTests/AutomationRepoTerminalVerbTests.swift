//
//  AutomationRepoTerminalVerbTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for `repo.terminal` (#1375): the repo-scoped terminal was reachable by click but by
//  no verb, so an agent that wanted a shell in a repo had to create a workspace it did not want.
//  What is asserted here is that the verb drives the real gesture, reports the surface it actually
//  attached, and fails closed when no window installed the path.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("AutomationController repo.terminal")
struct AutomationRepoTerminalVerbTests {
    /// One window installs the layer these cases drive; a teardown names it (#1375).
    private static let windowOwner = UUID()

    private func operatorController(
        gestureVerbs: AutomationGestureVerbs?
    ) -> (AutomationController, operatorHandle: String) {
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
        return (controller, entry.handle)
    }

    private func verbs(
        repoID: UUID,
        effect: AutomationRepoTerminalEffect,
        onOpen: @escaping @MainActor () -> Void = {}
    ) -> AutomationGestureVerbs {
        AutomationGestureVerbs(
            resolveWorkspace: { _ in nil },
            performSelection: { _ in
                AutomationWorkspaceSelectEffect(
                    selectedWorkspaceID: nil, attachedSurfaceID: nil, attachedTerminal: false)
            },
            resolveRepo: { [repoID] in
                $0 == repoID
                    ? AutomationGestureVerbs.RepoTarget(repoID: repoID, name: "acme", path: "/repos/acme")
                    : nil
            },
            performRepoTerminal: { _ in
                onOpen()
                return effect
            }
        )
    }

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
            Issue.record("Expected AutomationServiceError, got \(error).")
        }
    }

    @Test("the verb drives the real gesture and reports the surface it attached")
    func completesAndReportsTheAttach() async throws {
        let repoID = UUID()
        let surface = UUID()
        var drove = false
        let controller = operatorController(
            gestureVerbs: verbs(
                repoID: repoID,
                effect: AutomationRepoTerminalEffect(
                    attachedSurfaceID: surface,
                    attachedTerminal: true,
                    directoryPath: "/repos/acme"
                ),
                onOpen: { drove = true }
            )
        )

        let result = try await controller.0.automationOpenRepoTerminal(
            for: controller.operatorHandle,
            request: AutomationRepoTerminalRequest(repoID: repoID.uuidString)
        )

        #expect(drove)
        #expect(result.outcome == .completed)
        #expect(result.repoID == repoID)
        #expect(result.repoName == "acme")
        #expect(result.attachedSurfaceID == surface)
        #expect(result.attachedTerminal)
        #expect(result.directoryPath == "/repos/acme")
    }

    /// A gesture that ran but landed nowhere reports no surface rather than implying a terminal
    /// that is not there — the same honesty `workspace.select` keeps.
    @Test("a gesture that attached nothing says so")
    func reportsNoAttachWhenTheGestureLandedElsewhere() async throws {
        let repoID = UUID()
        let controller = operatorController(
            gestureVerbs: verbs(
                repoID: repoID,
                effect: AutomationRepoTerminalEffect(
                    attachedSurfaceID: nil,
                    attachedTerminal: false,
                    directoryPath: "/repos/acme"
                )
            )
        )

        let result = try await controller.0.automationOpenRepoTerminal(
            for: controller.operatorHandle,
            request: AutomationRepoTerminalRequest(repoID: repoID.uuidString)
        )

        #expect(result.outcome == .completed)
        #expect(result.attachedSurfaceID == nil)
        #expect(!result.attachedTerminal)
    }

    @Test("an unknown repo id is an invalid request, not a completed no-op")
    func unknownRepoIsInvalidRequest() async {
        let controller = operatorController(
            gestureVerbs: verbs(
                repoID: UUID(),
                effect: AutomationRepoTerminalEffect(
                    attachedSurfaceID: nil, attachedTerminal: false, directoryPath: "/repos/acme")
            )
        )

        await expectFailure(.invalidRequest) {
            try await controller.0.automationOpenRepoTerminal(
                for: controller.operatorHandle,
                request: AutomationRepoTerminalRequest(repoID: UUID().uuidString)
            )
        }
    }

    @Test("a non-UUID repo id is rejected before any gesture runs")
    func nonUUIDRepoIDIsRejected() async {
        var drove = false
        let controller = operatorController(
            gestureVerbs: verbs(
                repoID: UUID(),
                effect: AutomationRepoTerminalEffect(
                    attachedSurfaceID: nil, attachedTerminal: false, directoryPath: "/repos/acme"),
                onOpen: { drove = true }
            )
        )

        await expectFailure(.invalidRequest) {
            try await controller.0.automationOpenRepoTerminal(
                for: controller.operatorHandle,
                request: AutomationRepoTerminalRequest(repoID: "not-a-uuid")
            )
        }
        #expect(!drove)
    }

    /// No window means no gesture path was installed, so the verb fails closed rather than
    /// driving something stale — the same rule every mutation verb follows.
    @Test("no live window makes the verb unsupported")
    func noWindowIsUnsupported() async {
        let controller = operatorController(gestureVerbs: nil)

        await expectFailure(.unsupported) {
            try await controller.0.automationOpenRepoTerminal(
                for: controller.operatorHandle,
                request: AutomationRepoTerminalRequest(repoID: UUID().uuidString)
            )
        }
    }

    @Test("a tile handle cannot open a repo terminal")
    func tileHandleIsDenied() async {
        let repoID = UUID()
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let entry = registry.upsert(
            hostSessionID: UUID(),
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "workspaces.local"
        )
        let controller = AutomationController(
            handleRegistry: registry,
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in },
            gestureVerbs: verbs(
                repoID: repoID,
                effect: AutomationRepoTerminalEffect(
                    attachedSurfaceID: UUID(), attachedTerminal: true, directoryPath: "/repos/acme")
            ),
            windowBoundOwner: Self.windowOwner
        )

        await expectFailure(.capabilityDenied) {
            try await controller.automationOpenRepoTerminal(
                for: entry.handle,
                request: AutomationRepoTerminalRequest(repoID: repoID.uuidString)
            )
        }
    }
}

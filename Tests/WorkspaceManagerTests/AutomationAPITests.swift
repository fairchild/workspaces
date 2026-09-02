// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
private final class FakeAutomationController: AutomationControlling {
    struct InputWrite: Equatable {
        let handle: String
        let text: String
        let submit: Bool
    }

    var contextCalls: [String] = []
    var focusDirections: [AutomationTileFocusDirection] = []
    var splitDirections: [AutomationTileSplitDirection] = []
    var closeHandles: [String] = []
    var inputWrites: [InputWrite] = []

    func automationContext(for handle: String) throws -> AutomationContextResult {
        contextCalls.append(handle)
        guard handle == "live" else {
            throw AutomationServiceError(.staleHandle, "stale")
        }
        return AutomationContextResult(
            surface: AutomationSurfaceDescriptor(
                surfaceID: "surface-1",
                tileID: "tile-1",
                kind: .terminal,
                hostSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
                title: "Terminal",
                cwd: "/tmp/repo",
                isCaller: true,
                isActive: true,
                isVisible: true
            ),
            scope: AutomationScopeDescriptor(
                app: "workspaces.local",
                window: "window-1",
                scopeKey: "repoPath(/tmp/repo)",
                primaryHostSessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")
            )
        )
    }

    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult {
        _ = try automationContext(for: handle)
        return AutomationSurfacesResult(surfaces: [])
    }

    var windowCalls: [String] = []

    func automationWindows(for handle: String) throws -> AutomationWindowsResult {
        // Only an operator handle carries window.read; a tile handle ("live") fails closed, and an
        // unknown handle is stale — mirrors the real controller's operator-scope projection.
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include window.read.")
        }
        windowCalls.append(handle)
        return AutomationWindowsResult(
            windows: [
                AutomationWindowDescriptor(
                    windowID: "42",
                    title: "WorkSpaces",
                    subtitle: "Development Build",
                    isMain: true,
                    isKey: true,
                    isVisible: true,
                    x: 0,
                    y: 0,
                    width: 1400,
                    height: 900
                )
            ]
        )
    }

    var workspaceCalls: [String] = []
    var archivedWorkspaceIDs: Set<String> = []
    static let inventoryRepoID = "55555555-5555-5555-5555-555555555555"
    static let inventoryWorkspaceID = "66666666-6666-6666-6666-666666666666"

    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult {
        // Only an operator handle carries workspace.read; a tile handle ("live") fails closed, and an
        // unknown handle is stale — mirrors the real controller's operator-scope projection.
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include workspace.read.")
        }
        workspaceCalls.append(handle)
        let workspaceID = Self.inventoryWorkspaceID
        let archived = archivedWorkspaceIDs.contains(workspaceID)
        return AutomationWorkspacesResult(
            repos: [
                AutomationRepoDescriptor(
                    repoID: UUID(uuidString: Self.inventoryRepoID)!,
                    name: "workspaces",
                    path: "/Users/test/workspaces",
                    isSelected: true
                )
            ],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: UUID(uuidString: workspaceID)!,
                    repoID: UUID(uuidString: Self.inventoryRepoID)!,
                    name: "feature-a",
                    path: "/Users/test/workspaces/feature-a",
                    branch: "feature-a",
                    status: archived ? "archived" : "active",
                    isArchived: archived,
                    backend: "local",
                    isSelected: true
                )
            ]
        )
    }

    var selectCalls: [String] = []
    var createCalls: [AutomationWorkspaceCreateRequest] = []
    var archiveCalls: [AutomationWorkspaceArchiveRequest] = []

    /// Named ids the fake maps to each projected outcome, so router tests can drive the wire mapping
    /// without a live app. A well-shaped-but-unknown id and a non-UUID id both project to
    /// `invalid_request`; the no-window id projects to `unsupported`.
    static let selectUnknownID = "00000000-0000-0000-0000-000000000000"
    static let selectNoWindowID = "11111111-1111-1111-1111-111111111111"
    static let selectAttachedSurfaceID = "22222222-2222-2222-2222-222222222222"
    static let createUnknownRepoID = "33333333-3333-3333-3333-333333333333"
    static let createNoWindowRepoID = "44444444-4444-4444-4444-444444444444"
    static let createConfirmationRepoID = "55555555-5555-5555-5555-555555555555"
    static let createWorkspaceID = "88888888-8888-8888-8888-888888888888"
    static let createAttachedSurfaceID = "99999999-9999-9999-9999-999999999999"
    static let archiveUnknownID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    static let archiveNoWindowID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    static let archiveSelectedWorkspaceID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    static let archiveTerminalActiveID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    static let archiveRetiredSurfaceID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"

    func automationSelectWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult {
        // Mirrors the operator-scope projection: only an operator handle carries workspace.select; a
        // tile handle ("live") is capability_denied and any other handle is stale.
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include workspace.select.")
        }
        guard UUID(uuidString: workspaceID) != nil else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }
        if workspaceID == Self.selectUnknownID {
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(workspaceID) is tracked by the app.")
        }
        if workspaceID == Self.selectNoWindowID {
            throw AutomationServiceError(
                .unsupported, "No WorkSpaces window is attached; workspace.select requires a live window.")
        }
        selectCalls.append(workspaceID)
        return AutomationWorkspaceSelectResult(
            workspaceID: workspaceID,
            outcome: .completed,
            changed: true,
            selectedWorkspaceID: UUID(uuidString: workspaceID),
            attachedTerminal: true,
            attachedSurfaceID: Self.selectAttachedSurfaceID
        )
    }

    func automationCreateWorkspace(
        for handle: String,
        request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult {
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include workspace.create.")
        }
        guard UUID(uuidString: request.repoID) != nil else {
            throw AutomationServiceError(.invalidRequest, "repoID must be a UUID.")
        }
        if request.repoID == Self.createUnknownRepoID {
            throw AutomationServiceError(
                .invalidRequest, "No repo with id \(request.repoID) is tracked by the app.")
        }
        if request.repoID == Self.createNoWindowRepoID {
            throw AutomationServiceError(
                .unsupported, "No WorkSpaces window is attached; workspace.create requires a live window.")
        }
        if request.repoID == Self.createConfirmationRepoID {
            return AutomationWorkspaceCreateResult(
                repoID: request.repoID,
                workspaceName: request.name,
                outcome: .confirmationRequired,
                changed: false,
                confirmation: AutomationConfirmationRequirement(
                    action: "workspace.create",
                    title: "Set Up Lume",
                    message: "Create workspace '\(request.name)' requires Lume setup confirmation.",
                    providerID: "lume",
                    providerDisplayName: "Lume",
                    primaryButtonTitle: "Set Up Lume"
                ),
                message: "Create workspace '\(request.name)' requires Lume setup confirmation."
            )
        }
        createCalls.append(request)
        return AutomationWorkspaceCreateResult(
            repoID: request.repoID,
            workspaceID: UUID(uuidString: Self.createWorkspaceID),
            workspaceName: request.name,
            workspacePath: "/Users/test/workspaces/\(request.name)",
            outcome: .completed,
            changed: true,
            selectedWorkspaceID: UUID(uuidString: Self.createWorkspaceID),
            attachedTerminal: true,
            attachedSurfaceID: Self.createAttachedSurfaceID
        )
    }

    func automationArchiveWorkspace(
        for handle: String,
        request: AutomationWorkspaceArchiveRequest
    ) async throws -> AutomationWorkspaceArchiveResult {
        let workspaceID = request.workspaceID
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include workspace.archive.")
        }
        guard UUID(uuidString: workspaceID) != nil else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }
        if workspaceID == Self.archiveUnknownID {
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(workspaceID) is tracked by the app.")
        }
        if workspaceID == Self.archiveNoWindowID {
            throw AutomationServiceError(
                .unsupported, "No WorkSpaces window is attached; workspace.archive requires a live window.")
        }
        if workspaceID == Self.archiveTerminalActiveID {
            throw AutomationServiceError(
                .terminalActive,
                "Terminal 'ws' did not exit before the workspace lifecycle timeout.",
                retryable: true)
        }
        archiveCalls.append(request)
        archivedWorkspaceIDs.insert(workspaceID)
        return AutomationWorkspaceArchiveResult(
            workspaceID: workspaceID,
            outcome: .completed,
            changed: true,
            archivedWorkspaceID: UUID(uuidString: workspaceID),
            selectedWorkspaceID: UUID(uuidString: Self.archiveSelectedWorkspaceID),
            teardown: request.teardownTerminals == true
                ? AutomationWorkspaceArchiveTeardownReport(
                    retiredSurfaceIDs: [Self.archiveRetiredSurfaceID],
                    killedTmuxSessions: ["wm-ws-12345678"])
                : nil
        )
    }

    var noteCalls: [AutomationWorkspaceNoteRequest] = []
    static let noteUnknownID = "00000000-0000-0000-0000-0000000000E1"

    /// Mirrors the operator-scope projection: only an operator handle carries
    /// workspace.note; a tile handle ("live") is capability_denied and any other handle
    /// is stale. The stored note is the normalized one, which is what the wire reports.
    func automationOpenRepoTerminal(
        for handle: String,
        request: AutomationRepoTerminalRequest
    ) async throws -> AutomationRepoTerminalResult {
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include repo.terminal.")
        }
        guard let repoID = UUID(uuidString: request.repoID) else {
            throw AutomationServiceError(.invalidRequest, "repoID must be a UUID.")
        }
        return AutomationRepoTerminalResult(
            outcome: .completed,
            repoID: repoID,
            repoName: "repo",
            attachedSurfaceID: UUID(),
            attachedTerminal: true,
            directoryPath: "/tmp/repo"
        )
    }

    func automationSetWorkspaceNote(
        for handle: String,
        request: AutomationWorkspaceNoteRequest
    ) async throws -> AutomationWorkspaceNoteResult {
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include workspace.note.")
        }
        guard UUID(uuidString: request.workspaceID) != nil else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }
        if request.workspaceID == Self.noteUnknownID {
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(request.workspaceID) is tracked by the app.")
        }
        noteCalls.append(request)
        return AutomationWorkspaceNoteResult(
            workspaceID: request.workspaceID,
            workspaceName: "feature-auth",
            note: WorkspaceNote.normalized(request.note),
            changed: true
        )
    }

    var windowSnapshotCalls: [String] = []
    var surfaceReadCalls: [AutomationSurfaceReadRequest] = []

    func automationWindowSnapshot(
        for handle: String,
        windowID: String
    ) async throws -> AutomationWindowSnapshotResult {
        // Mirrors the operator-scope projection: only an operator handle carries window.snapshot; a
        // tile handle ("live") is capability_denied and any other handle is stale.
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include window.snapshot.")
        }
        windowSnapshotCalls.append(windowID)
        return AutomationWindowSnapshotResult(
            windowID: windowID,
            width: 2,
            height: 1,
            byteCount: 4,
            data: "AQID"
        )
    }

    func automationReadSurface(
        for handle: String,
        request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult {
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include surface.read.")
        }
        surfaceReadCalls.append(request)
        let effectiveLines = min(request.lines, AutomationAPI.surfaceReadMaxLines)
        return AutomationSurfaceReadResult(
            surfaceID: request.surfaceID,
            requestedLines: request.lines,
            lines: effectiveLines,
            returnedLines: 2,
            byteCount: 11,
            text: "hello\nworld"
        )
    }

    func automationHandleIsOperator(_ handle: String) -> Bool {
        handle == "operator"
    }

    var webSurfaceCalls: [String] = []

    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult {
        guard handle != "nobrowser" else {
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include browser.read.")
        }
        _ = try automationContext(for: handle)
        webSurfaceCalls.append(handle)
        return AutomationWebSurfacesResult(
            webSurfaces: [
                AutomationWebSurfaceDescriptor(
                    sourceID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    scope: .repo,
                    ownerID: UUID(uuidString: "44444444-4444-4444-4444-444444444444"),
                    displayName: "Docs",
                    configuredURL: "https://example.test/docs",
                    liveURL: nil,
                    title: nil,
                    isLive: false,
                    isLoading: nil
                )
            ]
        )
    }

    var snapshotCalls: [UUID] = []

    func automationWebSurfaceSnapshot(
        for handle: String,
        sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult {
        guard handle != "nobrowser" else {
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include browser.read.")
        }
        _ = try automationContext(for: handle)
        snapshotCalls.append(sourceID)
        return AutomationWebSurfaceSnapshotResult(
            sourceID: sourceID,
            width: 2,
            height: 1,
            byteCount: 4,
            data: "AQID"
        )
    }

    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        _ = try automationContext(for: handle)
        focusDirections.append(direction)
        return AutomationMutationResult(changed: true, focusedSurfaceID: "surface-2")
    }

    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult {
        _ = try automationContext(for: handle)
        splitDirections.append(direction)
        return AutomationMutationResult(changed: true, createdSurfaceID: "surface-2")
    }

    func automationCloseTile(for handle: String) throws -> AutomationMutationResult {
        _ = try automationContext(for: handle)
        closeHandles.append(handle)
        return AutomationMutationResult(changed: false, outcome: .requested, closedSurfaceID: "surface-1")
    }

    func automationWriteInput(
        for handle: String,
        text: String,
        submit: Bool
    ) throws -> AutomationInputWriteResult {
        guard handle != "nowrite" else {
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include input.write.")
        }
        _ = try automationContext(for: handle)
        inputWrites.append(InputWrite(handle: handle, text: text, submit: submit))
        return AutomationInputWriteResult(accepted: true, byteCount: text.utf8.count, surfaceID: "surface-1")
    }

    var waitPlans: [AutomationWaitPlan] = []
    var focusCalls: [String] = []

    /// Named ids the fake maps to each projected wait outcome, so router tests can drive the
    /// wire mapping without a live app.
    static let waitTimedOutWorkspaceID = "77777777-7777-7777-7777-777777777777"
    static let waitNotApplicableWorkspaceID = "ffffffff-ffff-ffff-ffff-ffffffffffff"

    func automationWait(
        for handle: String,
        plan: AutomationWaitPlan
    ) async throws -> AutomationWaitResult {
        // Mirrors the operator-scope projection: only an operator handle carries the wait's
        // read capabilities; a tile handle ("live") is capability_denied, others are stale.
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(
                .capabilityDenied, "The automation handle does not include workspace.read.")
        }
        waitPlans.append(plan)
        let outcome: AutomationWaitOutcomeKind
        let observed: AutomationWaitObservation
        switch plan.condition {
        case .workspaceSelected(let workspaceID)
        where workspaceID == UUID(uuidString: Self.waitTimedOutWorkspaceID):
            outcome = .timedOut
            observed = AutomationWaitObservation(workspaceSelected: false)
        case .workspaceSelected(let workspaceID)
        where workspaceID == UUID(uuidString: Self.waitNotApplicableWorkspaceID):
            outcome = .notApplicable
            observed = AutomationWaitObservation(workspaceSelected: false, targetWorkspaceArchived: true)
        default:
            outcome = .satisfied
            observed = AutomationWaitObservation(surfaceAttached: true, attachedSurfaceID: "surface-1")
        }
        return AutomationWaitResult(
            condition: plan.condition.kind,
            outcome: outcome,
            waitedMS: outcome == .timedOut ? plan.effectiveTimeoutMS : 0,
            requestedTimeoutMS: plan.requestedTimeoutMS,
            effectiveTimeoutMS: plan.effectiveTimeoutMS,
            observed: observed
        )
    }

    func automationFocus(for handle: String) throws -> AutomationFocusResult {
        guard handle == "operator" else {
            guard handle == "live" else {
                throw AutomationServiceError(.staleHandle, "stale")
            }
            throw AutomationServiceError(.capabilityDenied, "The automation handle does not include window.read.")
        }
        focusCalls.append(handle)
        return AutomationFocusResult(
            state: AutomationFocusState(
                appIsActive: false,
                keyWindowID: "42",
                firstResponderSurfaceID: nil,
                focusPossible: false
            )
        )
    }
}

@Suite("Automation API")
struct AutomationAPITests {
    @Test("Response envelopes encode stable v1 success and failure shapes")
    func responseEnvelopeShapes() throws {
        let success = AutomationResponseEnvelope(result: AutomationHealthResult())
        let successData = try AutomationJSON.encoder.encode(success)
        let successText = String(data: successData, encoding: .utf8)
        #expect(
            successText
                == #"{"ok":true,"result":{"status":"ok","system":{"capabilities":["context.read","surfaces.read","tile.focus","tile.split","tile.close","browser.read"]}},"v":1}"#
        )

        let failure = AutomationResponseEnvelope<AutomationEmptyResult>(
            error: AutomationErrorResponse(code: .missingHandle, message: "Missing handle.")
        )
        let failureData = try AutomationJSON.encoder.encode(failure)
        let failureText = String(data: failureData, encoding: .utf8)
        #expect(failureText == #"{"error":{"code":"missing_handle","message":"Missing handle."},"ok":false,"v":1}"#)
    }

    @Test("Handle registry resolves live handles and drops stale mappings")
    @MainActor
    func handleRegistryLookup() {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let registry = AutomationHandleRegistry(makeHandle: { "handle-1" })
        let entry = registry.upsert(
            hostSessionID: firstID,
            tileID: TileID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            surfaceKind: .terminal,
            windowScopeID: "window-1",
            appScopeID: "app"
        )

        #expect(entry.handle == "handle-1")
        #expect(registry.resolve("handle-1")?.hostSessionID == firstID)
        #expect(registry.handle(for: firstID) == "handle-1")

        registry.remove(hostSessionID: firstID)
        #expect(registry.resolve("handle-1") == nil)
        #expect(registry.handle(for: firstID) == nil)
    }

    @Test("Router allows unauthenticated health and blocks scoped requests when disabled")
    @MainActor
    func routerHealthAndDisabled() async throws {
        let controller = FakeAutomationController()
        let server = AutomationServerDescriptor(
            pid: 7301,
            launchedAt: "2026-07-08T08:35:44Z",
            appVersion: "1.2.3",
            build: "debug",
            experiments: ["automationAPI", "automationInputWrite", "automationOperator"],
            protocolVersion: AutomationAPI.version
        )
        let health = await AutomationHTTPRouter.route(
            HTTPRequest(method: "GET", path: "/v1/health", headers: [:], body: Data()),
            controller: controller,
            enabled: false,
            healthServer: server
        )
        let healthEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationHealthResult>.self,
            from: health.body
        )
        #expect(health.status == 200)
        #expect(healthEnvelope.ok)
        #expect(healthEnvelope.result?.server == server)
        #expect(healthEnvelope.result?.server?.protocolVersion == AutomationAPI.version)

        let context = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/context",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: false
        )
        let contextEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: context.body
        )
        #expect(context.status == 403)
        #expect(contextEnvelope.error?.code == .disabled)
    }

    @Test("Router rejects missing and stale handles")
    @MainActor
    func routerHandleFailures() async throws {
        let controller = FakeAutomationController()
        let missing = await AutomationHTTPRouter.route(
            HTTPRequest(method: "GET", path: "/v1/context", headers: [:], body: Data()),
            controller: controller,
            enabled: true
        )
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: missing.body
        )
        #expect(missing.status == 401)
        #expect(missingEnvelope.error?.code == .missingHandle)

        let stale = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/context",
                headers: [AutomationAPI.handleHeader: "stale"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let staleEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: stale.body
        )
        #expect(stale.status == 401)
        #expect(staleEnvelope.error?.code == .staleHandle)
    }

    @Test("Router rejects malformed body and caller-supplied target identifiers")
    @MainActor
    func routerRejectsMalformedAndTargetIDs() async throws {
        let controller = FakeAutomationController()
        let malformed = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/tile/focus",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data("{".utf8)
            ),
            controller: controller,
            enabled: true
        )
        let malformedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: malformed.body
        )
        #expect(malformed.status == 400)
        #expect(malformedEnvelope.error?.code == .malformedJSON)

        let targetID = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/tile/focus",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data(#"{"direction":"right","tileID":"forged"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let targetEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: targetID.body
        )
        #expect(targetID.status == 400)
        #expect(targetEnvelope.error?.code == .invalidRequest)
        #expect(controller.focusDirections.isEmpty)
    }

    @Test("Router maps focus split and close verbs")
    @MainActor
    func routerMapsMutationVerbs() async throws {
        let controller = FakeAutomationController()

        _ = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/tile/focus",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data(#"{"direction":"previous"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        _ = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/tile/split",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data(#"{"direction":"down"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        _ = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/tile/close",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )

        #expect(controller.focusDirections == [.previous])
        #expect(controller.splitDirections == [.down])
        #expect(controller.closeHandles == ["live"])
    }

    @Test("Router maps input write and returns the result envelope")
    @MainActor
    func routerInputWriteHappyPath() async throws {
        let controller = FakeAutomationController()
        let response = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/input/write",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data(#"{"text":"echo hi","submit":true}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let envelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationInputWriteResult>.self,
            from: response.body
        )

        #expect(response.status == 200)
        #expect(envelope.result?.accepted == true)
        #expect(envelope.result?.byteCount == "echo hi".utf8.count)
        #expect(
            controller.inputWrites == [
                FakeAutomationController.InputWrite(handle: "live", text: "echo hi", submit: true)
            ]
        )
    }

    @Test("Router validates input write bodies before reaching the controller")
    @MainActor
    func routerInputWriteValidation() async throws {
        let controller = FakeAutomationController()
        let oversizeText = String(repeating: "a", count: AutomationAPI.inputWriteMaxUTF8Bytes + 1)
        let invalidBodies: [Data] = [
            Data(),
            Data(#"{"submit":true}"#.utf8),
            Data(#"{"text":""}"#.utf8),
            Data(#"{"text":"\#(oversizeText)"}"#.utf8),
            Data(#"{"text":"echo hi","surfaceID":"forged"}"#.utf8),
        ]

        for body in invalidBodies {
            let response = await AutomationHTTPRouter.route(
                HTTPRequest(
                    method: "POST",
                    path: "/v1/input/write",
                    headers: [AutomationAPI.handleHeader: "live"],
                    body: body
                ),
                controller: controller,
                enabled: true
            )
            let envelope = try AutomationJSON.decoder.decode(
                AutomationResponseEnvelope<AutomationEmptyResult>.self,
                from: response.body
            )
            #expect(response.status == 400)
            #expect(envelope.error?.code == .invalidRequest)
        }
        #expect(controller.inputWrites.isEmpty)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/input/write",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("Router surfaces capability denial for under-capable input write handles")
    @MainActor
    func routerInputWriteCapabilityDenied() async throws {
        let controller = FakeAutomationController()
        let response = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/input/write",
                headers: [AutomationAPI.handleHeader: "nowrite"],
                body: Data(#"{"text":"echo hi"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let envelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: response.body
        )

        #expect(response.status == 403)
        #expect(envelope.error?.code == .capabilityDenied)
        #expect(controller.inputWrites.isEmpty)
    }

    @Test("Router lists web surfaces, denies under-capable handles, and rejects non-GET")
    @MainActor
    func routerWebSurfaces() async throws {
        let controller = FakeAutomationController()

        let listed = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let listedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWebSurfacesResult>.self,
            from: listed.body
        )
        #expect(listed.status == 200)
        #expect(listedEnvelope.result?.webSurfaces.count == 1)
        #expect(listedEnvelope.result?.webSurfaces.first?.displayName == "Docs")
        // Fail-closed: an inactive source lists without a fabricated live URL/title.
        #expect(listedEnvelope.result?.webSurfaces.first?.isLive == false)
        #expect(listedEnvelope.result?.webSurfaces.first?.liveURL == nil)
        #expect(controller.webSurfaceCalls == ["live"])

        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces",
                headers: [AutomationAPI.handleHeader: "nobrowser"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/web-surfaces",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("Snapshot encoder base64-encodes a captured PNG and reports raw byte count")
    func snapshotEncoderCaptured() throws {
        let sourceID = UUID()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let result = try WebSurfaceSnapshotEncoder.result(
            from: .captured(pngData: png, width: 320, height: 200),
            sourceID: sourceID,
            capabilities: AutomationAPI.v1Capabilities
        )
        #expect(result.sourceID == sourceID)
        #expect(result.encoding == "png")
        #expect(result.width == 320)
        #expect(result.height == 200)
        #expect(result.byteCount == png.count)
        #expect(Data(base64Encoded: result.data) == png)
        #expect(result.system.capabilities.contains(.browserRead))
    }

    @Test("Snapshot encoder rejects a capture over the raw byte cap as unsupported")
    func snapshotEncoderOverCap() throws {
        let png = Data(repeating: 0xAB, count: 64)
        do {
            _ = try WebSurfaceSnapshotEncoder.result(
                from: .captured(pngData: png, width: 10, height: 10),
                sourceID: UUID(),
                maxRawBytes: 32,
                capabilities: AutomationAPI.v1Capabilities
            )
            Issue.record("Expected an over-cap capture to be rejected")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .unsupported)
            #expect(error.response.message.contains("cap"))
        }
    }

    @Test("Snapshot encoder maps each failure outcome to its structured error code")
    func snapshotEncoderFailureMapping() throws {
        let sourceID = UUID()
        func code(_ outcome: WebSnapshotOutcome) -> AutomationErrorCode? {
            do {
                _ = try WebSurfaceSnapshotEncoder.result(
                    from: outcome,
                    sourceID: sourceID,
                    capabilities: AutomationAPI.v1Capabilities
                )
                return nil
            } catch let error as AutomationServiceError {
                return error.response.code
            } catch {
                return nil
            }
        }
        #expect(code(.unknownSource) == .invalidRequest)
        #expect(code(.notLive) == .unsupported)
        #expect(code(.timedOut) == .unsupported)
        #expect(code(.captureFailed("boom")) == .internalError)
    }

    @Test("Router captures a web-surface snapshot, rejects a bad id, wrong method, and under-capable handle")
    @MainActor
    func routerWebSurfaceSnapshot() async throws {
        let controller = FakeAutomationController()
        let sourceID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        let ok = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces/\(sourceID.uuidString)/snapshot",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWebSurfaceSnapshotResult>.self,
            from: ok.body
        )
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.sourceID == sourceID)
        #expect(okEnvelope.result?.encoding == "png")
        #expect(controller.snapshotCalls == [sourceID])

        let badID = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces/not-a-uuid/snapshot",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let badIDEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: badID.body
        )
        #expect(badID.status == 400)
        #expect(badIDEnvelope.error?.code == .invalidRequest)

        // An empty id (`/v1/web-surfaces//snapshot`) is a well-shaped snapshot path with a
        // bad id, so it reports invalid_request rather than falling through to route_not_found.
        let emptyID = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces//snapshot",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let emptyIDEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: emptyID.body
        )
        #expect(emptyID.status == 400)
        #expect(emptyIDEnvelope.error?.code == .invalidRequest)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/web-surfaces/\(sourceID.uuidString)/snapshot",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)

        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/web-surfaces/\(sourceID.uuidString)/snapshot",
                headers: [AutomationAPI.handleHeader: "nobrowser"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)
    }

    @Test("Registry mints an operator handle carrying read/capture plus workspace gesture verbs")
    @MainActor
    func registryRegistersOperatorHandle() {
        let registry = AutomationHandleRegistry(makeHandle: { "op-1" })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")

        #expect(entry.handle == "op-1")
        #expect(entry.isOperator)
        #expect(entry.tileID == nil)
        #expect(
            entry.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .workspaceNote, .repoTerminal, .uiRead,
            ])
        // Operator mutation capabilities are reviewed gesture verbs; an operator handle still never
        // carries tile mutation or input.write.
        #expect(!entry.capabilities.contains(.tileClose))
        #expect(!entry.capabilities.contains(.inputWrite))
        #expect(registry.resolve("op-1")?.isOperator == true)

        // The handle dies with the launch: once the registry is cleared it no longer resolves,
        // so a credential left behind by a crashed launch fails closed against a fresh registry.
        registry.removeAll()
        #expect(registry.resolve("op-1") == nil)
    }

    @Test("Re-registering an operator under the same host session evicts the prior handle")
    @MainActor
    func registryOperatorReRegisterEvictsPriorHandle() {
        var counter = 0
        let registry = AutomationHandleRegistry(makeHandle: {
            counter += 1
            return "op-\(counter)"
        })
        let hostSessionID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let createdSurfaceID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

        let first = registry.registerOperator(appScopeID: "workspaces.local", hostSessionID: hostSessionID)
        registry.recordWorkspaceCreation(operatorHandle: first.handle, hostSessionID: createdSurfaceID)
        let second = registry.registerOperator(appScopeID: "workspaces.local", hostSessionID: hostSessionID)

        // Registry invariant: every resolvable handle stays reachable through a host-session
        // mapping, so a re-mint under the same host session id must evict the prior entry —
        // otherwise the replaced handle leaks as permanently resolvable and un-revocable.
        #expect(first.handle != second.handle)
        #expect(registry.resolve(first.handle) == nil)
        #expect(registry.resolve(second.handle)?.isOperator == true)
        #expect(registry.handle(for: hostSessionID) == second.handle)
        // Creation attributions die with the evicted handle instead of dangling.
        #expect(!registry.operatorHandle(first.handle, createdHostSessionID: createdSurfaceID))

        registry.remove(hostSessionID: hostSessionID)
        #expect(registry.resolve(second.handle) == nil)
    }

    @Test("tile.close result encodes the typed requested outcome without claiming a change")
    func mutationResultEncodesRequestedOutcome() throws {
        let result = AutomationMutationResult(
            changed: false,
            outcome: .requested,
            closedSurfaceID: "surface-1"
        )
        let text = String(data: try AutomationJSON.encoder.encode(result), encoding: .utf8)
        #expect(text?.contains(#""outcome":"requested""#) == true)
        #expect(text?.contains(#""changed":false"#) == true)
    }

    @Test("tile.focus and tile.split results omit the outcome key entirely on the wire")
    func mutationResultOmitsOutcomeKeyForFocusAndSplit() throws {
        func encodedKeys(of result: AutomationMutationResult) throws -> Set<String> {
            let data = try AutomationJSON.encoder.encode(result)
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Set(object.keys)
        }

        // Pin the wire-compat claim at the key level: the optional outcome field added for
        // tile.close must stay absent (not null, not defaulted) from focus and split payloads.
        let focusKeys = try encodedKeys(
            of: AutomationMutationResult(changed: true, focusedSurfaceID: "surface-2"))
        #expect(!focusKeys.contains("outcome"))
        #expect(focusKeys.contains("changed"))
        #expect(focusKeys.contains("focusedSurfaceID"))

        let splitKeys = try encodedKeys(
            of: AutomationMutationResult(
                changed: true, focusedSurfaceID: "surface-2", createdSurfaceID: "surface-2"))
        #expect(!splitKeys.contains("outcome"))
        #expect(splitKeys.contains("changed"))
        #expect(splitKeys.contains("createdSurfaceID"))
    }

    @Test("GET /v1/windows succeeds for an operator handle and denies a tile handle")
    @MainActor
    func routerWindows() async throws {
        let controller = FakeAutomationController()

        let ok = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/windows",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWindowsResult>.self,
            from: ok.body
        )
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.windows.count == 1)
        #expect(okEnvelope.result?.windows.first?.windowID == "42")
        #expect(
            okEnvelope.result?.system.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .workspaceNote, .repoTerminal, .uiRead,
            ])
        #expect(controller.windowCalls == ["operator"])

        // A tile handle holds the v1 tile capabilities but not window.read → capability_denied.
        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/windows",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let missing = await AutomationHTTPRouter.route(
            HTTPRequest(method: "GET", path: "/v1/windows", headers: [:], body: Data()),
            controller: controller,
            enabled: true
        )
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: missing.body
        )
        #expect(missing.status == 401)
        #expect(missingEnvelope.error?.code == .missingHandle)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/windows",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("GET /v1/workspaces succeeds for an operator handle and denies a tile handle")
    @MainActor
    func routerWorkspaces() async throws {
        let controller = FakeAutomationController()

        let ok = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/workspaces",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspacesResult>.self,
            from: ok.body
        )
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.repos.count == 1)
        #expect(okEnvelope.result?.repos.first?.name == "workspaces")
        #expect(okEnvelope.result?.repos.first?.isSelected == true)
        #expect(okEnvelope.result?.workspaces.count == 1)
        #expect(okEnvelope.result?.workspaces.first?.name == "feature-a")
        #expect(okEnvelope.result?.workspaces.first?.status == "active")
        #expect(okEnvelope.result?.workspaces.first?.backend == "local")
        #expect(okEnvelope.result?.workspaces.first?.isSelected == true)
        #expect(
            okEnvelope.result?.system.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .workspaceNote, .repoTerminal, .uiRead,
            ])
        #expect(controller.workspaceCalls == ["operator"])

        // A tile handle holds the v1 tile capabilities but not workspace.read → capability_denied.
        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/workspaces",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let missing = await AutomationHTTPRouter.route(
            HTTPRequest(method: "GET", path: "/v1/workspaces", headers: [:], body: Data()),
            controller: controller,
            enabled: true
        )
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: missing.body
        )
        #expect(missing.status == 401)
        #expect(missingEnvelope.error?.code == .missingHandle)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/workspaces",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("Window-snapshot encoder base64-encodes a captured PNG and reports raw byte count")
    func windowSnapshotEncoderCaptured() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let result = try WindowSnapshotEncoder.result(
            from: .captured(pngData: png, width: 2800, height: 1800),
            windowID: "42",
            capabilities: AutomationAPI.operatorCapabilities
        )
        #expect(result.windowID == "42")
        #expect(result.encoding == "png")
        #expect(result.width == 2800)
        #expect(result.height == 1800)
        #expect(result.byteCount == png.count)
        #expect(Data(base64Encoded: result.data) == png)
        #expect(result.system.capabilities.contains(.windowSnapshot))
    }

    @Test("Window-snapshot encoder rejects a capture over the raw byte cap as unsupported")
    func windowSnapshotEncoderOverCap() throws {
        let png = Data(repeating: 0xAB, count: 64)
        do {
            _ = try WindowSnapshotEncoder.result(
                from: .captured(pngData: png, width: 10, height: 10),
                windowID: "42",
                maxRawBytes: 32,
                capabilities: AutomationAPI.operatorCapabilities
            )
            Issue.record("Expected an over-cap capture to be rejected")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .unsupported)
            #expect(error.response.message.contains("cap"))
        }
    }

    @Test("Window-snapshot encoder maps each failure outcome to its structured error code")
    func windowSnapshotEncoderFailureMapping() throws {
        func code(_ outcome: WindowSnapshotOutcome) -> AutomationErrorCode? {
            do {
                _ = try WindowSnapshotEncoder.result(
                    from: outcome,
                    windowID: "42",
                    capabilities: AutomationAPI.operatorCapabilities
                )
                return nil
            } catch let error as AutomationServiceError {
                return error.response.code
            } catch {
                return nil
            }
        }
        #expect(code(.unknownWindow) == .invalidRequest)
        #expect(code(.notCapturable) == .unsupported)
        #expect(code(.captureFailed("boom")) == .internalError)
    }

    @Test("POST /v1/workspace/select projects the gesture outcome and enforces the capability")
    @MainActor
    func routerWorkspaceSelect() async throws {
        let controller = FakeAutomationController()
        let validID = "77777777-7777-7777-7777-777777777777"

        func post(_ handle: String?, body: Data) async -> AutomationHTTPResult {
            var headers: [String: String] = [:]
            if let handle { headers[AutomationAPI.handleHeader] = handle }
            return await AutomationHTTPRouter.route(
                HTTPRequest(method: "POST", path: "/v1/workspace/select", headers: headers, body: body),
                controller: controller,
                enabled: true
            )
        }

        func body(_ id: String) -> Data {
            Data("{\"workspaceID\":\"\(id)\"}".utf8)
        }

        // Operator handle + valid id → completed, attached, and the controller was actually driven.
        let ok = await post("operator", body: body(validID))
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceSelectResult>.self, from: ok.body)
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.outcome == .completed)
        #expect(okEnvelope.result?.changed == true)
        #expect(okEnvelope.result?.attachedTerminal == true)
        #expect(okEnvelope.result?.attachedSurfaceID == FakeAutomationController.selectAttachedSurfaceID)
        #expect(okEnvelope.result?.system.capabilities.contains(.workspaceSelect) == true)
        #expect(controller.selectCalls == [validID])

        // A tile handle holds tile mutation but not workspace.select → capability_denied.
        let denied = await post("live", body: body(validID))
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: denied.body)
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        // Unknown handle is stale; missing handle is missing.
        let stale = await post("ghost", body: body(validID))
        #expect(stale.status == 401)
        let missing = await post(nil, body: body(validID))
        #expect(missing.status == 401)
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: missing.body)
        #expect(missingEnvelope.error?.code == .missingHandle)

        // A well-shaped-but-unknown id and a non-UUID id both project to invalid_request.
        let unknown = await post("operator", body: body(FakeAutomationController.selectUnknownID))
        #expect(unknown.status == 400)
        let badUUID = await post("operator", body: body("not-a-uuid"))
        let badUUIDEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: badUUID.body)
        #expect(badUUID.status == 400)
        #expect(badUUIDEnvelope.error?.code == .invalidRequest)

        // No live window → unsupported (the verb never falls back to a data-layer write).
        let noWindow = await post("operator", body: body(FakeAutomationController.selectNoWindowID))
        let noWindowEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: noWindow.body)
        #expect(noWindow.status == 409)
        #expect(noWindowEnvelope.error?.code == .unsupported)

        // An empty body is invalid_request; GET is method_not_allowed.
        let empty = await post("operator", body: Data())
        #expect(empty.status == 400)
        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET", path: "/v1/workspace/select",
                headers: [AutomationAPI.handleHeader: "operator"], body: Data()),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongMethod.body)
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("workspace-select result encodes the structured outcome kind on the wire")
    func workspaceSelectResultEncoding() throws {
        let confirmation = AutomationWorkspaceSelectResult(
            workspaceID: "abc", outcome: .confirmationRequired, changed: false,
            message: "Confirm?")
        let data = try AutomationJSON.encoder.encode(AutomationResponseEnvelope(result: confirmation))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"outcome\":\"confirmation_required\""))
        #expect(json.contains("\"message\":\"Confirm?\""))

        let completed = AutomationWorkspaceSelectResult(
            workspaceID: "abc", outcome: .completed, changed: true, attachedTerminal: true)
        let completedJSON = try #require(
            String(data: try AutomationJSON.encoder.encode(completed), encoding: .utf8))
        #expect(completedJSON.contains("\"outcome\":\"completed\""))
    }

    @Test("POST /v1/workspace/create projects completed and confirmation outcomes")
    @MainActor
    func routerWorkspaceCreate() async throws {
        let controller = FakeAutomationController()
        let validRepoID = "77777777-7777-7777-7777-777777777777"

        func post(_ handle: String?, body: Data) async -> AutomationHTTPResult {
            var headers: [String: String] = [:]
            if let handle { headers[AutomationAPI.handleHeader] = handle }
            return await AutomationHTTPRouter.route(
                HTTPRequest(method: "POST", path: "/v1/workspace/create", headers: headers, body: body),
                controller: controller,
                enabled: true
            )
        }

        func body(repoID: String, name: String = "created") throws -> Data {
            try AutomationJSON.encoder.encode(
                AutomationWorkspaceCreateRequest(repoID: repoID, name: name)
            )
        }

        let ok = await post("operator", body: try body(repoID: validRepoID))
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceCreateResult>.self, from: ok.body)
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.outcome == .completed)
        #expect(okEnvelope.result?.changed == true)
        #expect(okEnvelope.result?.workspaceID?.uuidString == FakeAutomationController.createWorkspaceID)
        #expect(okEnvelope.result?.attachedTerminal == true)
        #expect(okEnvelope.result?.attachedSurfaceID == FakeAutomationController.createAttachedSurfaceID)
        #expect(okEnvelope.result?.system.capabilities.contains(.workspaceCreate) == true)
        #expect(controller.createCalls == [AutomationWorkspaceCreateRequest(repoID: validRepoID, name: "created")])

        let withOptions = await post(
            "operator",
            body: try AutomationJSON.encoder.encode(
                AutomationWorkspaceCreateRequest(
                    repoID: validRepoID,
                    name: "from-ref",
                    select: false,
                    fromRef: "origin/main"
                )
            )
        )
        #expect(withOptions.status == 200)
        #expect(
            controller.createCalls == [
                AutomationWorkspaceCreateRequest(repoID: validRepoID, name: "created"),
                AutomationWorkspaceCreateRequest(
                    repoID: validRepoID,
                    name: "from-ref",
                    select: false,
                    fromRef: "origin/main"
                ),
            ])

        let confirmation = await post(
            "operator",
            body: try body(repoID: FakeAutomationController.createConfirmationRepoID, name: "needs-lume")
        )
        let confirmationEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceCreateResult>.self, from: confirmation.body)
        #expect(confirmation.status == 200)
        #expect(confirmationEnvelope.result?.outcome == .confirmationRequired)
        #expect(confirmationEnvelope.result?.changed == false)
        #expect(confirmationEnvelope.result?.confirmation?.action == "workspace.create")
        #expect(confirmationEnvelope.result?.confirmation?.providerID == "lume")
        #expect(confirmationEnvelope.result?.message?.contains("Lume setup confirmation") == true)

        let denied = await post("live", body: try body(repoID: validRepoID))
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: denied.body)
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let unknown = await post("operator", body: try body(repoID: FakeAutomationController.createUnknownRepoID))
        #expect(unknown.status == 400)
        let badUUID = await post("operator", body: try body(repoID: "not-a-uuid"))
        let badUUIDEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: badUUID.body)
        #expect(badUUID.status == 400)
        #expect(badUUIDEnvelope.error?.code == .invalidRequest)

        let noWindow = await post("operator", body: try body(repoID: FakeAutomationController.createNoWindowRepoID))
        let noWindowEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: noWindow.body)
        #expect(noWindow.status == 409)
        #expect(noWindowEnvelope.error?.code == .unsupported)

        let empty = await post("operator", body: Data())
        #expect(empty.status == 400)
        let badRef = await post(
            "operator",
            body: try AutomationJSON.encoder.encode(
                AutomationWorkspaceCreateRequest(
                    repoID: validRepoID,
                    name: "bad-ref",
                    fromRef: "origin/main; rm -rf /"
                )
            )
        )
        let badRefEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: badRef.body)
        #expect(badRef.status == 400)
        #expect(badRefEnvelope.error?.code == .invalidRequest)
        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET", path: "/v1/workspace/create",
                headers: [AutomationAPI.handleHeader: "operator"], body: Data()),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongMethod.body)
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("workspace-create result encodes the structured confirmation payload")
    func workspaceCreateResultEncoding() throws {
        let confirmation = AutomationWorkspaceCreateResult(
            repoID: "repo",
            workspaceName: "ws",
            outcome: .confirmationRequired,
            changed: false,
            confirmation: AutomationConfirmationRequirement(
                action: "workspace.create",
                title: "Set Up Lume",
                message: "Create workspace requires setup.",
                providerID: "lume",
                providerDisplayName: "Lume",
                primaryButtonTitle: "Set Up"
            ),
            message: "Create workspace requires setup."
        )
        let data = try AutomationJSON.encoder.encode(AutomationResponseEnvelope(result: confirmation))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"outcome\":\"confirmation_required\""))
        #expect(json.contains("\"confirmation\""))
        #expect(json.contains("\"action\":\"workspace.create\""))
        #expect(json.contains("\"providerID\":\"lume\""))
    }

    @Test("POST /v1/repo/terminal routes, reports the attach, and enforces the capability")
    @MainActor
    func routerRepoTerminal() async throws {
        let controller = FakeAutomationController()

        func post(_ handle: String?, body: Data, method: String = "POST") async -> AutomationHTTPResult {
            var headers: [String: String] = [:]
            if let handle { headers[AutomationAPI.handleHeader] = handle }
            return await AutomationHTTPRouter.route(
                HTTPRequest(method: method, path: "/v1/repo/terminal", headers: headers, body: body),
                controller: controller,
                enabled: true
            )
        }

        let repoID = UUID()
        let ok = await post("operator", body: Data("{\"repoID\":\"\(repoID.uuidString)\"}".utf8))
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationRepoTerminalResult>.self, from: ok.body)
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.repoID == repoID)
        #expect(okEnvelope.result?.attachedTerminal == true)
        #expect(okEnvelope.result?.system.capabilities.contains(.repoTerminal) == true)

        // Broken JSON and a missing field are different caller mistakes and report differently.
        let malformed = await post("operator", body: Data("{broken".utf8))
        let malformedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: malformed.body)
        #expect(malformedEnvelope.error?.code == .malformedJSON)

        let missing = await post("operator", body: Data("{}".utf8))
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: missing.body)
        #expect(missing.status == 400)
        #expect(missingEnvelope.error?.code == .invalidRequest)

        let empty = await post("operator", body: Data())
        let emptyEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: empty.body)
        #expect(empty.status == 400)
        #expect(emptyEnvelope.error?.code == .invalidRequest)

        // A tile handle carries no repo.terminal: opening a repo terminal is operator-only.
        let tile = await post("live", body: Data("{\"repoID\":\"\(repoID.uuidString)\"}".utf8))
        let tileEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: tile.body)
        #expect(tile.status == 403)
        #expect(tileEnvelope.error?.code == .capabilityDenied)

        let wrongMethod = await post("operator", body: Data(), method: "GET")
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongMethod.body)
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("POST /v1/workspace/note stores the normalized note and enforces the capability")
    @MainActor
    func routerWorkspaceNote() async throws {
        let controller = FakeAutomationController()
        let validID = FakeAutomationController.inventoryWorkspaceID

        func post(_ handle: String?, body: Data, method: String = "POST") async -> AutomationHTTPResult {
            var headers: [String: String] = [:]
            if let handle { headers[AutomationAPI.handleHeader] = handle }
            return await AutomationHTTPRouter.route(
                HTTPRequest(method: method, path: "/v1/workspace/note", headers: headers, body: body),
                controller: controller,
                enabled: true
            )
        }

        let noteBody = Data("{\"workspaceID\":\"\(validID)\",\"note\":\"  rebasing\\nonto main  \"}".utf8)
        let ok = await post("operator", body: noteBody)
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceNoteResult>.self, from: ok.body)
        #expect(ok.status == 200)
        // The wire reports the stored form, so a caller learns what the sidebar will show.
        #expect(okEnvelope.result?.note == "rebasing onto main")
        #expect(okEnvelope.result?.changed == true)
        #expect(okEnvelope.result?.system.capabilities.contains(.workspaceNote) == true)

        // An absent note clears, which is why there is no separate clear verb.
        let cleared = await post("operator", body: Data("{\"workspaceID\":\"\(validID)\"}".utf8))
        let clearedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceNoteResult>.self, from: cleared.body)
        #expect(cleared.status == 200)
        #expect(clearedEnvelope.result?.note == nil)

        // An explicit null clears too.
        let nulled = await post("operator", body: Data("{\"workspaceID\":\"\(validID)\",\"note\":null}".utf8))
        #expect(nulled.status == 200)

        let wrongType = await post(
            "operator", body: Data("{\"workspaceID\":\"\(validID)\",\"note\":42}".utf8))
        let wrongTypeEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongType.body)
        #expect(wrongType.status == 400)
        #expect(wrongTypeEnvelope.error?.code == .invalidRequest)

        // A tile handle carries no workspace.note, so the sidebar's line is not writable
        // from inside a tile.
        let tile = await post("live", body: Data("{\"workspaceID\":\"\(validID)\",\"note\":\"x\"}".utf8))
        let tileEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: tile.body)
        #expect(tile.status == 403)
        #expect(tileEnvelope.error?.code == .capabilityDenied)

        let unknown = await post(
            "operator",
            body: Data("{\"workspaceID\":\"\(FakeAutomationController.noteUnknownID)\",\"note\":\"x\"}".utf8))
        let unknownEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: unknown.body)
        #expect(unknown.status == 400)
        #expect(unknownEnvelope.error?.code == .invalidRequest)

        let wrongMethod = await post("operator", body: Data(), method: "GET")
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongMethod.body)
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("POST /v1/workspace/archive projects the gesture outcome and enforces the capability")
    @MainActor
    func routerWorkspaceArchive() async throws {
        let controller = FakeAutomationController()
        let validID = FakeAutomationController.inventoryWorkspaceID

        func post(_ handle: String?, body: Data) async -> AutomationHTTPResult {
            var headers: [String: String] = [:]
            if let handle { headers[AutomationAPI.handleHeader] = handle }
            return await AutomationHTTPRouter.route(
                HTTPRequest(method: "POST", path: "/v1/workspace/archive", headers: headers, body: body),
                controller: controller,
                enabled: true
            )
        }

        func body(_ id: String) -> Data {
            Data("{\"workspaceID\":\"\(id)\"}".utf8)
        }

        let ok = await post("operator", body: body(validID))
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceArchiveResult>.self, from: ok.body)
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.outcome == .completed)
        #expect(okEnvelope.result?.changed == true)
        #expect(okEnvelope.result?.archivedWorkspaceID?.uuidString == validID)
        let expectedSelectedWorkspaceID = UUID(uuidString: FakeAutomationController.archiveSelectedWorkspaceID)
        #expect(okEnvelope.result?.selectedWorkspaceID == expectedSelectedWorkspaceID)
        #expect(okEnvelope.result?.system.capabilities.contains(.workspaceArchive) == true)
        #expect(okEnvelope.result?.teardown == nil)
        #expect(controller.archiveCalls == [AutomationWorkspaceArchiveRequest(workspaceID: validID)])

        let teardownBody = Data(
            "{\"workspaceID\":\"\(validID)\",\"teardownTerminals\":true}".utf8)
        let teardownOK = await post("operator", body: teardownBody)
        let teardownEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceArchiveResult>.self, from: teardownOK.body)
        #expect(teardownOK.status == 200)
        #expect(
            teardownEnvelope.result?.teardown?.retiredSurfaceIDs == [
                FakeAutomationController.archiveRetiredSurfaceID
            ])
        #expect(teardownEnvelope.result?.teardown?.killedTmuxSessions == ["wm-ws-12345678"])
        #expect(
            controller.archiveCalls.last
                == AutomationWorkspaceArchiveRequest(workspaceID: validID, teardownTerminals: true))

        let badTeardown = await post(
            "operator", body: Data("{\"workspaceID\":\"\(validID)\",\"teardownTerminals\":\"yes\"}".utf8))
        let badTeardownEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: badTeardown.body)
        #expect(badTeardown.status == 400)
        #expect(badTeardownEnvelope.error?.code == .invalidRequest)

        // JSONSerialization bridges JSON numbers to Bool, so `1` would silently read as true
        // without the CoreFoundation-boolean check. The documented contract is boolean-only.
        let numericTeardown = await post(
            "operator", body: Data("{\"workspaceID\":\"\(validID)\",\"teardownTerminals\":1}".utf8))
        let numericTeardownEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: numericTeardown.body)
        #expect(numericTeardown.status == 400)
        #expect(numericTeardownEnvelope.error?.code == .invalidRequest)
        #expect(controller.archiveCalls.count == 2)

        let terminalActive = await post(
            "operator", body: body(FakeAutomationController.archiveTerminalActiveID))
        let terminalActiveEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: terminalActive.body)
        #expect(terminalActive.status == 409)
        #expect(terminalActiveEnvelope.error?.code == .terminalActive)
        #expect(terminalActiveEnvelope.error?.retryable == true)
        let terminalActiveJSON = try #require(String(data: terminalActive.body, encoding: .utf8))
        #expect(terminalActiveJSON.contains("\"retryable\":true"))

        let listed = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/workspaces",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let listedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspacesResult>.self, from: listed.body)
        #expect(listed.status == 200)
        #expect(listedEnvelope.result?.workspaces.first?.workspaceID.uuidString == validID)
        #expect(listedEnvelope.result?.workspaces.first?.isArchived == true)
        #expect(listedEnvelope.result?.workspaces.first?.status == "archived")

        let denied = await post("live", body: body(validID))
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: denied.body)
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let stale = await post("ghost", body: body(validID))
        #expect(stale.status == 401)
        let missing = await post(nil, body: body(validID))
        let missingEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: missing.body)
        #expect(missing.status == 401)
        #expect(missingEnvelope.error?.code == .missingHandle)

        let unknown = await post("operator", body: body(FakeAutomationController.archiveUnknownID))
        #expect(unknown.status == 400)
        let badUUID = await post("operator", body: body("not-a-uuid"))
        let badUUIDEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: badUUID.body)
        #expect(badUUID.status == 400)
        #expect(badUUIDEnvelope.error?.code == .invalidRequest)

        let noWindow = await post("operator", body: body(FakeAutomationController.archiveNoWindowID))
        let noWindowEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: noWindow.body)
        #expect(noWindow.status == 409)
        #expect(noWindowEnvelope.error?.code == .unsupported)

        let empty = await post("operator", body: Data())
        #expect(empty.status == 400)
        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET", path: "/v1/workspace/archive",
                headers: [AutomationAPI.handleHeader: "operator"], body: Data()),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self, from: wrongMethod.body)
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("workspace-archive result encodes the structured confirmation payload")
    func workspaceArchiveResultEncoding() throws {
        let confirmation = AutomationWorkspaceArchiveResult(
            workspaceID: "ws",
            outcome: .confirmationRequired,
            changed: false,
            confirmation: AutomationConfirmationRequirement(
                action: "workspace.archive",
                title: "Archive Workspace",
                message: "Archive workspace?",
                primaryButtonTitle: "Archive"
            ),
            message: "Archive workspace?"
        )
        let data = try AutomationJSON.encoder.encode(AutomationResponseEnvelope(result: confirmation))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"outcome\":\"confirmation_required\""))
        #expect(json.contains("\"confirmation\""))
        #expect(json.contains("\"action\":\"workspace.archive\""))
    }

    @Test("error responses carry documented retry semantics on the wire")
    func errorResponseRetryableEncoding() throws {
        func encoded(_ error: AutomationErrorResponse) throws -> String {
            let data = try AutomationJSON.encoder.encode(
                AutomationResponseEnvelope<AutomationEmptyResult>(error: error))
            return try #require(String(data: data, encoding: .utf8))
        }

        let transient = try encoded(
            AutomationErrorResponse(
                code: .terminalActive, message: "terminal still live", retryable: true))
        #expect(transient.contains("\"code\":\"terminal_active\""))
        #expect(transient.contains("\"retryable\":true"))

        let blocked = try encoded(
            AutomationErrorResponse(
                code: .closeBlockedByConfirmation, message: "confirmation blocks close", retryable: false))
        #expect(blocked.contains("\"code\":\"close_blocked_by_confirmation\""))
        #expect(blocked.contains("\"retryable\":false"))

        // Codes without retry guidance omit the field entirely, keeping the legacy wire shape.
        let unspecified = try encoded(
            AutomationErrorResponse(code: .unsupported, message: "no window"))
        #expect(!unspecified.contains("retryable"))

        // Decoding a legacy error without the field round-trips to nil, not false.
        let legacy = Data("{\"code\":\"unsupported\",\"message\":\"no window\"}".utf8)
        let decoded = try AutomationJSON.decoder.decode(AutomationErrorResponse.self, from: legacy)
        #expect(decoded.retryable == nil)
    }

    @Test("POST /v1/window/snapshot captures for an operator handle and fails closed otherwise")
    @MainActor
    func routerWindowSnapshot() async throws {
        let controller = FakeAutomationController()
        let body = try JSONSerialization.data(withJSONObject: ["windowID": "42"], options: [.sortedKeys])

        let ok = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/window/snapshot",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: body
            ),
            controller: controller,
            enabled: true
        )
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWindowSnapshotResult>.self,
            from: ok.body
        )
        #expect(ok.status == 200)
        #expect(okEnvelope.result?.windowID == "42")
        #expect(okEnvelope.result?.encoding == "png")
        #expect(controller.windowSnapshotCalls == ["42"])

        // A tile handle holds tile capabilities but not window.snapshot → capability_denied.
        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/window/snapshot",
                headers: [AutomationAPI.handleHeader: "live"],
                body: body
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        // Missing body → invalid_request, before any capture is attempted.
        let noBody = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/window/snapshot",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let noBodyEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: noBody.body
        )
        #expect(noBody.status == 400)
        #expect(noBodyEnvelope.error?.code == .invalidRequest)

        // Valid JSON of the wrong top-level shape (an array) → invalid_request, not malformed_json:
        // it parsed fine, it is just not the object the route expects.
        let wrongShape = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/window/snapshot",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data("[1,2]".utf8)
            ),
            controller: controller,
            enabled: true
        )
        let wrongShapeEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongShape.body
        )
        #expect(wrongShape.status == 400)
        #expect(wrongShapeEnvelope.error?.code == .invalidRequest)

        // Wrong method on the snapshot path → method_not_allowed.
        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/window/snapshot",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
        // The capture provider was never reached on the denied/malformed/wrong-method attempts.
        #expect(controller.windowSnapshotCalls == ["42"])
    }

    @Test("POST /v1/surface/read routes operator-created read requests and clamps line count")
    @MainActor
    func routerSurfaceRead() async throws {
        let controller = FakeAutomationController()
        let surfaceID = "99999999-9999-9999-9999-999999999999"
        let body = try JSONSerialization.data(
            withJSONObject: ["surfaceID": surfaceID, "lines": 10_000],
            options: [.sortedKeys]
        )

        let ok = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/surface/read",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: body
            ),
            controller: controller,
            enabled: true
        )
        let okEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationSurfaceReadResult>.self,
            from: ok.body
        )

        #expect(ok.status == 200)
        #expect(okEnvelope.result?.surfaceID == surfaceID)
        #expect(okEnvelope.result?.requestedLines == 10_000)
        #expect(okEnvelope.result?.lines == AutomationAPI.surfaceReadMaxLines)
        #expect(okEnvelope.result?.text == "hello\nworld")
        #expect(controller.surfaceReadCalls == [AutomationSurfaceReadRequest(surfaceID: surfaceID, lines: 10_000)])

        let denied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/surface/read",
                headers: [AutomationAPI.handleHeader: "live"],
                body: body
            ),
            controller: controller,
            enabled: true
        )
        let deniedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: denied.body
        )
        #expect(denied.status == 403)
        #expect(deniedEnvelope.error?.code == .capabilityDenied)

        let badLines = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/surface/read",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data("{\"surfaceID\":\"\(surfaceID)\",\"lines\":0}".utf8)
            ),
            controller: controller,
            enabled: true
        )
        let badLinesEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: badLines.body
        )
        #expect(badLines.status == 400)
        #expect(badLinesEnvelope.error?.code == .invalidRequest)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/surface/read",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)
    }

    @Test("Operator credential round-trips through the store and is written user-only (0600)")
    func operatorCredentialStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-cred-\(UUID().uuidString.prefix(8)).json")
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let credential = AutomationOperatorCredential(socketPath: "/tmp/automation.sock", handle: "op-xyz")
        try AutomationOperatorCredentialStore.write(credential, to: url)

        let loaded = AutomationOperatorCredentialStore.load(from: url)
        #expect(loaded == credential)
        #expect(
            loaded?.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .workspaceNote, .repoTerminal, .uiRead,
            ])

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)

        AutomationOperatorCredentialStore.remove(at: url)
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)
    }

    @Test("Provisioner mints only when opted in and clears a stale credential otherwise")
    @MainActor
    func operatorProvisionerGate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-prov-\(UUID().uuidString.prefix(8)).json")
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        // Opt-in launch mints: the credential file exists and its handle resolves as an operator
        // entry carrying window.read.
        let registry = AutomationHandleRegistry()
        let minted = AutomationOperatorProvisioner.provision(
            optedIn: true,
            registry: registry,
            socketPath: "/tmp/automation.sock",
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        let mintedCredential = try #require(minted)
        #expect(AutomationOperatorCredentialStore.load(from: url) == mintedCredential)
        #expect(
            registry.resolve(mintedCredential.handle)?.capabilities == [
                .windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect, .workspaceCreate, .surfaceRead,
                .workspaceArchive, .workspaceNote, .repoTerminal, .uiRead,
            ]
        )
        #expect(registry.resolve(mintedCredential.handle)?.isOperator == true)

        // A non-opt-in launch mints nothing and clears any stale credential left on disk.
        let freshRegistry = AutomationHandleRegistry()
        let notMinted = AutomationOperatorProvisioner.provision(
            optedIn: false,
            registry: freshRegistry,
            socketPath: "/tmp/automation.sock",
            appScopeID: "workspaces.local",
            credentialURL: url
        )
        #expect(notMinted == nil)
        #expect(AutomationOperatorCredentialStore.load(from: url) == nil)
    }

    @Test("Provisioner rolls back the handle when the credential write fails")
    @MainActor
    func operatorProvisionerRollsBackOnWriteFailure() throws {
        // Force a write failure by making the credential's parent path a regular file, so
        // createDirectory (and the write) throw. The provisioner must then leave no dangling handle.
        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-blocker-\(UUID().uuidString.prefix(8))")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }
        let unwritableURL = parentFile.appendingPathComponent("automation-operator.json")

        // Deterministic handle so the rollback is observable: registerOperator mints "op-fixed",
        // and a successful rollback must leave it unresolvable.
        let registry = AutomationHandleRegistry(makeHandle: { "op-fixed" })
        let result = AutomationOperatorProvisioner.provision(
            optedIn: true,
            registry: registry,
            socketPath: "/tmp/automation.sock",
            appScopeID: "workspaces.local",
            credentialURL: unwritableURL
        )

        #expect(result == nil)
        #expect(AutomationOperatorCredentialStore.load(from: unwritableURL) == nil)
        // The handle registered during the aborted mint must have been rolled back.
        #expect(registry.resolve("op-fixed") == nil)
    }

    @Test("Audit log records the operator flag so operator calls are distinguishable")
    func auditLogTagsOperatorCalls() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-audit-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)

        let okBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(result: AutomationWindowsResult(windows: []))
        )
        await logger.record(
            method: "GET",
            path: "/v1/windows",
            headers: [AutomationAPI.handleHeader: "op"],
            responseBody: okBody,
            operatorHandle: true
        )
        await logger.record(
            method: "GET",
            path: "/v1/context",
            headers: [AutomationAPI.handleHeader: "tile"],
            responseBody: okBody,
            operatorHandle: false
        )
        await logger.record(
            method: "POST",
            path: "/v1/workspace/create",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: try AutomationJSON.encoder.encode(
                AutomationWorkspaceCreateRequest(
                    repoID: UUID().uuidString,
                    name: "created",
                    select: false,
                    fromRef: "origin/main"
                )
            ),
            responseBody: okBody,
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        let events = try lines.map { line in
            try AutomationJSON.decoder.decode(AutomationAuditLogger.Event.self, from: Data(line.utf8))
        }
        let windowsEvent = try #require(events.first { $0.path == "/v1/windows" })
        #expect(windowsEvent.operatorHandle)
        let contextEvent = try #require(events.first { $0.path == "/v1/context" })
        #expect(!contextEvent.operatorHandle)
        let createEvent = try #require(events.first { $0.path == "/v1/workspace/create" })
        #expect(createEvent.metadata?["workspaceCreate.select"] == "provided")
        #expect(createEvent.metadata?["workspaceCreate.fromRef"] == "provided")
        #expect(!String(describing: createEvent.metadata).contains("origin/main"))
    }

    @Test("Archive teardown gets its own audit entry with counts only")
    func auditLogRecordsTeardownAsOwnEntry() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-archive-audit-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)

        let workspaceID = UUID().uuidString
        let tmuxSessionName = "wm-ws-12345678"
        let responseBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(
                result: AutomationWorkspaceArchiveResult(
                    workspaceID: workspaceID,
                    outcome: .completed,
                    changed: true,
                    archivedWorkspaceID: UUID(uuidString: workspaceID),
                    teardown: AutomationWorkspaceArchiveTeardownReport(
                        retiredSurfaceIDs: [UUID().uuidString, UUID().uuidString],
                        killedTmuxSessions: [tmuxSessionName]
                    )
                )
            )
        )
        await logger.record(
            method: "POST",
            path: "/v1/workspace/archive",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: Data("{\"workspaceID\":\"\(workspaceID)\",\"teardownTerminals\":true}".utf8),
            responseBody: responseBody,
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let events = try lines.map { line in
            try AutomationJSON.decoder.decode(AutomationAuditLogger.Event.self, from: Data(line.utf8))
        }
        let archiveEvent = try #require(events.first { $0.path == "/v1/workspace/archive" })
        #expect(archiveEvent.metadata?["workspaceArchive.teardownTerminals"] == "true")
        let teardownEvent = try #require(events.first { $0.path == "/v1/workspace/archive#teardown" })
        #expect(teardownEvent.operatorHandle)
        #expect(teardownEvent.allowed)
        #expect(teardownEvent.metadata?["workspaceArchive.teardown.retiredSurfaceCount"] == "2")
        #expect(teardownEvent.metadata?["workspaceArchive.teardown.killedTmuxSessionCount"] == "1")
        // Counts only: the tmux session name never lands in the audit log.
        #expect(!contents.contains(tmuxSessionName))
    }

    @Test("Audit log records surface.read metadata without terminal text")
    func auditLogSurfaceReadMetadataIsContentFree() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-surface-read-audit-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)
        let surfaceID = "99999999-9999-9999-9999-999999999999"
        let requestBody = try AutomationJSON.encoder.encode(
            AutomationSurfaceReadRequest(surfaceID: surfaceID, lines: 10_000)
        )
        let responseBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(
                result: AutomationSurfaceReadResult(
                    surfaceID: surfaceID,
                    requestedLines: 10_000,
                    lines: AutomationAPI.surfaceReadMaxLines,
                    returnedLines: 2,
                    byteCount: 11,
                    text: "secret\ntext"
                )
            )
        )

        await logger.record(
            method: "POST",
            path: "/v1/surface/read",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: requestBody,
            responseBody: responseBody,
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(!contents.contains("secret"))
        let event = try AutomationJSON.decoder.decode(
            AutomationAuditLogger.Event.self,
            from: Data(try #require(contents.split(separator: "\n").first).utf8)
        )
        #expect(event.surfaceID == surfaceID)
        #expect(event.requestedLines == 10_000)
        #expect(event.returnedLines == 2)
        #expect(event.allowed)
        #expect(event.errorCode == nil)
    }

    @Test("CLI formatter emits result JSON and surfaces envelope errors")
    func cliFormatter() throws {
        let result = AutomationContextResult(
            surface: AutomationSurfaceDescriptor(
                surfaceID: "surface",
                tileID: "tile",
                kind: .terminal,
                hostSessionID: nil,
                title: "Terminal",
                cwd: nil,
                isCaller: true,
                isActive: true,
                isVisible: true
            ),
            scope: AutomationScopeDescriptor(app: "app", window: "window", scopeKey: nil, primaryHostSessionID: nil)
        )
        let json = try AutomationCLIResultPrinter.resultJSON(result)
        #expect(!json.contains(#""handle""#))
        #expect(json.contains(#""surfaceID" : "surface""#))

        let failure = AutomationResponseEnvelope<AutomationContextResult>(
            error: AutomationErrorResponse(code: .staleHandle, message: "stale")
        )
        let response = AutomationSocketClient.Response(
            statusCode: 401,
            body: try AutomationJSON.encoder.encode(failure)
        )
        do {
            _ = try AutomationCLIResultPrinter.decodeEnvelope(AutomationContextResult.self, from: response)
            Issue.record("Expected stale handle error")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .staleHandle)
        }

        let health = AutomationHealthResult(
            server: AutomationServerDescriptor(
                pid: 7301,
                launchedAt: "2026-07-08T08:35:44Z",
                appVersion: "1.2.3",
                build: "debug",
                experiments: ["automationAPI"],
                protocolVersion: AutomationAPI.version
            )
        )
        let healthResponse = AutomationSocketClient.Response(
            statusCode: 200,
            body: try AutomationJSON.encoder.encode(AutomationResponseEnvelope(result: health))
        )
        #expect(
            try AutomationCLIResultPrinter.decodeHealthEnvelope(
                from: healthResponse,
                bundledCLIPath: "/Applications/WorkSpaces.app/Contents/MacOS/workspaces"
            ) == health)

        let skewed = Data(
            #"{"ok":true,"result":{"server":{"protocolVersion":2}},"v":1}"#.utf8
        )
        do {
            _ = try AutomationCLIResultPrinter.decodeHealthEnvelope(
                from: AutomationSocketClient.Response(statusCode: 200, body: skewed),
                bundledCLIPath: "/Applications/WorkSpaces.app/Contents/MacOS/workspaces"
            )
            Issue.record("Expected protocol version mismatch")
        } catch let error as AutomationCLIResponseError {
            #expect(
                error.localizedDescription
                    == "CLI v1 vs app v2 — use the bundled CLI at /Applications/WorkSpaces.app/Contents/MacOS/workspaces"
            )
        }

        let raw = #"{"ok":true,"result":{"status":123}}"#
        do {
            _ = try AutomationCLIResultPrinter.decodeHealthEnvelope(
                from: AutomationSocketClient.Response(statusCode: 200, body: Data(raw.utf8)),
                bundledCLIPath: "/Applications/WorkSpaces.app/Contents/MacOS/workspaces"
            )
            Issue.record("Expected raw-body decode fallback")
        } catch let error as AutomationCLIResponseError {
            #expect(error.localizedDescription.contains(raw))
        }
    }

    @Test("A second listener fails instead of becoming a dormant handle issuer")
    @MainActor
    func listenerLockContentionThrows() async throws {
        let socket = URL(fileURLWithPath: "/tmp/wm-auto-lock-\(UUID().uuidString.prefix(8)).sock")
        let first = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: FakeAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil
        )
        let second = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: FakeAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil
        )
        try await first.start()

        do {
            try await second.start()
            Issue.record("Expected second listener to fail lock acquisition")
        } catch AutomationListener.ListenerError.socketAlreadyOwned(let path) {
            #expect(path == socket.path)
        } catch {
            await first.stop()
            throw error
        }
        await first.stop()
    }

    // MARK: - Wait plan resolution

    @Test("Wait plan resolves defaults, clamps the ceiling, and echoes both timeouts")
    func waitPlanTimeouts() throws {
        let defaulted = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(condition: "surface_attached")
        )
        #expect(defaulted.requestedTimeoutMS == AutomationAPI.waitDefaultTimeoutMS)
        #expect(defaulted.effectiveTimeoutMS == AutomationAPI.waitDefaultTimeoutMS)
        #expect(defaulted.condition == .surfaceAttached(surfaceID: nil))

        let clamped = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(condition: "surface_attached", timeoutMS: 600_000)
        )
        #expect(clamped.requestedTimeoutMS == 600_000)
        #expect(clamped.effectiveTimeoutMS == AutomationAPI.waitMaxTimeoutMS)

        #expect(throws: AutomationServiceError.self) {
            try AutomationWaitPlan.resolve(AutomationWaitRequest(condition: "surface_attached", timeoutMS: 0))
        }
    }

    @Test("Wait plan rejects unknown conditions with the vocabulary in the message")
    func waitPlanVocabulary() {
        do {
            _ = try AutomationWaitPlan.resolve(AutomationWaitRequest(condition: "surface_focused"))
            Issue.record("Expected invalid_request for an unknown wait condition")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .invalidRequest)
            for kind in AutomationWaitConditionKind.allCases {
                #expect(error.response.message.contains(kind.rawValue))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Wait plan validates predicates per condition instead of silently ignoring fields")
    func waitPlanPredicateValidation() throws {
        let surfaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceID = "22222222-2222-2222-2222-222222222222"

        // surface_attached: optional surfaceID; workspace/pattern fields are rejected.
        let attached = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(
                condition: "surface_attached",
                predicate: AutomationWaitPredicate(surfaceID: surfaceID)
            )
        )
        #expect(attached.condition == .surfaceAttached(surfaceID: UUID(uuidString: surfaceID)))
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "surface_attached",
                predicate: AutomationWaitPredicate(pattern: "x")
            )
        )
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "surface_attached",
                predicate: AutomationWaitPredicate(surfaceID: "not-a-uuid")
            )
        )

        // workspace_selected: optional workspaceID; surface/pattern fields are rejected.
        let selected = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(
                condition: "workspace_selected",
                predicate: AutomationWaitPredicate(workspaceID: workspaceID)
            )
        )
        #expect(selected.condition == .workspaceSelected(workspaceID: UUID(uuidString: workspaceID)))
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "workspace_selected",
                predicate: AutomationWaitPredicate(surfaceID: surfaceID)
            )
        )

        // surface_text_matches: surfaceID + compiling pattern required, bounded length.
        let textMatch = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(
                condition: "surface_text_matches",
                predicate: AutomationWaitPredicate(surfaceID: surfaceID, pattern: "PASS|FAIL")
            )
        )
        #expect(
            textMatch.condition
                == .surfaceTextMatches(
                    surfaceID: UUID(uuidString: surfaceID)!,
                    pattern: try AutomationWaitPattern("PASS|FAIL")
                )
        )
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "surface_text_matches",
                predicate: AutomationWaitPredicate(pattern: "PASS")
            )
        )
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "surface_text_matches",
                predicate: AutomationWaitPredicate(surfaceID: surfaceID, pattern: "([unclosed")
            )
        )
        expectInvalidWaitRequest(
            AutomationWaitRequest(
                condition: "surface_text_matches",
                predicate: AutomationWaitPredicate(
                    surfaceID: surfaceID,
                    pattern: String(repeating: "a", count: AutomationAPI.waitPatternMaxUTF8Bytes + 1)
                )
            )
        )

        // prompt_ready: surfaceID required.
        let prompt = try AutomationWaitPlan.resolve(
            AutomationWaitRequest(
                condition: "prompt_ready",
                predicate: AutomationWaitPredicate(surfaceID: surfaceID)
            )
        )
        #expect(prompt.condition == .promptReady(surfaceID: UUID(uuidString: surfaceID)!))
        expectInvalidWaitRequest(AutomationWaitRequest(condition: "prompt_ready"))
    }

    private func expectInvalidWaitRequest(_ request: AutomationWaitRequest) {
        do {
            _ = try AutomationWaitPlan.resolve(request)
            Issue.record("Expected invalid_request for \(request)")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .invalidRequest)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Wait pattern matching

    @Test("A resolved pattern answers a well-behaved match without spending its budget")
    func waitPatternMatchesWellBehavedInput() async throws {
        let pattern = try AutomationWaitPattern("BUILD (PASSED|FAILED)")

        #expect(await pattern.firstMatchExists(in: "compiling…\nBUILD PASSED\n", budgetMS: 1_000) == true)
        #expect(await pattern.firstMatchExists(in: "compiling…\n", budgetMS: 1_000) == false)
    }

    @Test("A catastrophic pattern abandons its match at the budget instead of running to completion")
    func waitPatternAbandonsCatastrophicMatchAtBudget() async throws {
        // `(a+)+$` over a run of 'a' terminated by 'b' is the textbook super-polynomial case:
        // ~2^n backtracks at n = 64, which no wait budget can absorb. Six bytes of pattern, far
        // inside `waitPatternMaxUTF8Bytes` — which is exactly why pattern length bounds nothing.
        let pattern = try AutomationWaitPattern("(a+)+$")
        let text = String(repeating: "a", count: 64) + "b"

        // Small budget on purpose: this burns a core for its whole duration, and the suite runs
        // in parallel with main-actor tests that have their own deadlines.
        let started = ContinuousClock.now
        let outcome = await pattern.firstMatchExists(in: text, budgetMS: 120)
        let elapsed = ContinuousClock.now - started

        // nil, not false: the match is undetermined, and reporting "did not match" would be a
        // claim the evaluation never earned.
        #expect(outcome == nil)
        // Loose on purpose — the property is boundedness, not latency. Left to run, this match
        // outlives the process; anything in seconds proves the abort fired.
        #expect(elapsed < .seconds(30))
    }

    @Test("A catastrophic match runs to its budget with the MainActor blocked — it never needs it")
    func waitPatternMatchesWithoutTheMainActor() async throws {
        // Why the app stays drawable through a pathological wait: the match never asks for the
        // MainActor. Proven by holding that actor for the match's whole life and letting only the
        // match's completion release it, so the claim is an ordering rather than a measurement of
        // how responsive a shared runner felt — the shape that made the tick-tally version of this
        // check flaky enough to abort a release (#1300).
        let pattern = try AutomationWaitPattern("(a+)+$")
        let text = String(repeating: "a", count: 64) + "b"
        let matchFinished = DispatchSemaphore(value: 0)

        let (match, released) = await MainActor.run { () -> (Task<Bool?, Never>, DispatchTimeoutResult) in
            // Started with this actor already held, so the match cannot have run before the block:
            // starting it outside would let a contended runner finish it first and pass vacuously.
            // `.userInitiated` because the pool has to schedule it while the main thread is held —
            // the one way this test can fail spuriously is a pool with no worker free to start it.
            let match = Task.detached(priority: .userInitiated) { () -> Bool? in
                defer { matchFinished.signal() }
                // Small budget: this burns a core, and it burns it while the MainActor is held.
                return await pattern.firstMatchExists(in: text, budgetMS: 120)
            }
            // Blocking, not suspending: a suspension would hand the actor back and prove nothing.
            // The timeout is the failure path, never the pass path — a match that needs this actor
            // makes the wait expire and the test fail instead of hanging the suite.
            return (match, matchFinished.wait(timeout: .now() + 30))
        }

        #expect(released == .success)
        // Abandoned at the budget, off-actor, while nothing could run on the MainActor.
        #expect(await match.value == nil)
    }

    // MARK: - Wait engine (virtual time — no sleeps)

    /// Virtual clock for the wait engine: `sleepMS` advances the counter instantly, so the
    /// engine's timeout arithmetic is exercised deterministically without wall-clock waits.
    private final class VirtualWaitClock: @unchecked Sendable {
        private let lock = NSLock()
        private var currentMS: Int64 = 0
        private(set) var sleeps: [Int64] = []

        var timeSource: AutomationWaitTimeSource {
            AutomationWaitTimeSource(
                nowMS: { [weak self] in
                    guard let self else { return 0 }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return self.currentMS
                },
                sleepMS: { [weak self] milliseconds in
                    guard let self else { return }
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    self.currentMS += milliseconds
                    self.sleeps.append(milliseconds)
                }
            )
        }
    }

    /// Serves a scripted sequence of probes, then repeats the final element.
    @MainActor
    private final class ScriptedProbe {
        private var script: [AutomationWaitProbe]
        private(set) var tickCount = 0

        init(_ script: [AutomationWaitProbe]) {
            self.script = script
        }

        func next() -> AutomationWaitProbe {
            tickCount += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }

    @Test("Wait engine returns satisfied with the elapsed virtual time")
    @MainActor
    func waitEngineSatisfied() async throws {
        let clock = VirtualWaitClock()
        let observed = AutomationWaitObservation(surfaceAttached: true, attachedSurfaceID: "s-1")
        let probe = ScriptedProbe([
            .pending(AutomationWaitObservation(surfaceAttached: false)),
            .pending(AutomationWaitObservation(surfaceAttached: false)),
            .satisfied(observed),
        ])
        let plan = AutomationWaitPlan(
            condition: .surfaceAttached(surfaceID: nil),
            requestedTimeoutMS: 1_000,
            effectiveTimeoutMS: 1_000
        )

        let verdict = await AutomationWaitEngine.run(
            plan: plan,
            pollIntervalMS: 100,
            timeSource: clock.timeSource,
            probe: { probe.next() }
        )

        #expect(verdict.outcome == .satisfied)
        #expect(verdict.waitedMS == 200)
        #expect(verdict.observed == observed)
        #expect(probe.tickCount == 3)
        #expect(clock.sleeps == [100, 100])
    }

    @Test("Wait engine times out exactly at the effective ceiling, truncating the final sleep")
    @MainActor
    func waitEngineTimesOutAtCeiling() async throws {
        let clock = VirtualWaitClock()
        let lastObserved = AutomationWaitObservation(surfaceAttached: false)
        let probe = ScriptedProbe([.pending(lastObserved)])
        let plan = AutomationWaitPlan(
            condition: .surfaceAttached(surfaceID: nil),
            requestedTimeoutMS: 60_000,
            effectiveTimeoutMS: 250
        )

        let verdict = await AutomationWaitEngine.run(
            plan: plan,
            pollIntervalMS: 100,
            timeSource: clock.timeSource,
            probe: { probe.next() }
        )

        #expect(verdict.outcome == .timedOut)
        // The final sleep is truncated to the remaining budget: 100 + 100 + 50, never 300.
        #expect(verdict.waitedMS == 250)
        #expect(clock.sleeps == [100, 100, 50])
        #expect(verdict.observed == lastObserved)
    }

    @Test("Wait engine surfaces not_applicable immediately without polling")
    @MainActor
    func waitEngineNotApplicable() async throws {
        let clock = VirtualWaitClock()
        let observed = AutomationWaitObservation(workspaceSelected: false, targetWorkspaceArchived: true)
        let probe = ScriptedProbe([.notApplicable(observed)])
        let plan = AutomationWaitPlan(
            condition: .workspaceSelected(workspaceID: UUID()),
            requestedTimeoutMS: 5_000,
            effectiveTimeoutMS: 5_000
        )

        let verdict = await AutomationWaitEngine.run(
            plan: plan,
            pollIntervalMS: 100,
            timeSource: clock.timeSource,
            probe: { probe.next() }
        )

        #expect(verdict.outcome == .notApplicable)
        #expect(verdict.waitedMS == 0)
        #expect(verdict.observed == observed)
        #expect(probe.tickCount == 1)
        #expect(clock.sleeps.isEmpty)
    }

    // MARK: - Wait and focus routes

    @Test("POST /v1/wait resolves the plan at the wire and projects every typed outcome")
    @MainActor
    func routerWait() async throws {
        let controller = FakeAutomationController()

        let satisfied = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data(#"{"for":"surface_attached","timeoutMS":600000}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let satisfiedEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWaitResult>.self,
            from: satisfied.body
        )
        #expect(satisfied.status == 200)
        #expect(satisfiedEnvelope.result?.outcome == .satisfied)
        #expect(satisfiedEnvelope.result?.condition == .surfaceAttached)
        // The router clamps at the wire; the controller sees the effective ceiling.
        #expect(satisfiedEnvelope.result?.requestedTimeoutMS == 600_000)
        #expect(satisfiedEnvelope.result?.effectiveTimeoutMS == AutomationAPI.waitMaxTimeoutMS)
        #expect(controller.waitPlans.last?.effectiveTimeoutMS == AutomationAPI.waitMaxTimeoutMS)

        let timedOut = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data(
                    #"{"for":"workspace_selected","predicate":{"workspaceID":"\#(FakeAutomationController.waitTimedOutWorkspaceID)"}}"#
                        .utf8)
            ),
            controller: controller,
            enabled: true
        )
        let timedOutEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWaitResult>.self,
            from: timedOut.body
        )
        #expect(timedOut.status == 200)
        #expect(timedOutEnvelope.result?.outcome == .timedOut)
        #expect(timedOutEnvelope.result?.waitedMS == AutomationAPI.waitDefaultTimeoutMS)

        let notApplicable = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data(
                    #"{"for":"workspace_selected","predicate":{"workspaceID":"\#(FakeAutomationController.waitNotApplicableWorkspaceID)"}}"#
                        .utf8)
            ),
            controller: controller,
            enabled: true
        )
        let notApplicableEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWaitResult>.self,
            from: notApplicable.body
        )
        #expect(notApplicable.status == 200)
        #expect(notApplicableEnvelope.result?.outcome == .notApplicable)
        #expect(notApplicableEnvelope.result?.observed.targetWorkspaceArchived == true)
    }

    @Test("POST /v1/wait fails typed for bad shapes, wrong methods, and under-capable handles")
    @MainActor
    func routerWaitFailures() async throws {
        let controller = FakeAutomationController()

        let unknownCondition = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data(#"{"for":"surface_focused"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let unknownEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: unknownCondition.body
        )
        #expect(unknownCondition.status == 400)
        #expect(unknownEnvelope.error?.code == .invalidRequest)
        #expect(controller.waitPlans.isEmpty)

        let strayPredicate = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data(#"{"for":"surface_attached","predicate":{"pattern":"PASS"}}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        #expect(strayPredicate.status == 400)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let wrongMethodEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: wrongMethod.body
        )
        #expect(wrongMethod.status == 405)
        #expect(wrongMethodEnvelope.error?.code == .methodNotAllowed)

        let tileHandle = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/wait",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data(#"{"for":"surface_attached"}"#.utf8)
            ),
            controller: controller,
            enabled: true
        )
        let tileEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: tileHandle.body
        )
        #expect(tileHandle.status == 403)
        #expect(tileEnvelope.error?.code == .capabilityDenied)
        #expect(controller.waitPlans.isEmpty)
    }

    @Test("GET /v1/focus reports the truthful state for an operator handle and fails closed otherwise")
    @MainActor
    func routerFocus() async throws {
        let controller = FakeAutomationController()

        let focus = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/focus",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let focusEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationFocusResult>.self,
            from: focus.body
        )
        #expect(focus.status == 200)
        #expect(focusEnvelope.result?.focusPossible == false)
        #expect(focusEnvelope.result?.keyWindowID == "42")
        #expect(controller.focusCalls == ["operator"])

        let tileHandle = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/focus",
                headers: [AutomationAPI.handleHeader: "live"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        let tileEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: tileHandle.body
        )
        #expect(tileHandle.status == 403)
        #expect(tileEnvelope.error?.code == .capabilityDenied)

        let wrongMethod = await AutomationHTTPRouter.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/focus",
                headers: [AutomationAPI.handleHeader: "operator"],
                body: Data()
            ),
            controller: controller,
            enabled: true
        )
        #expect(wrongMethod.status == 405)
    }

    @Test("Wait and focus results encode stable wire shapes")
    func waitAndFocusWireShapes() throws {
        let waitResult = AutomationWaitResult(
            condition: .workspaceSelected,
            outcome: .timedOut,
            waitedMS: 250,
            requestedTimeoutMS: 60_000,
            effectiveTimeoutMS: 250,
            observed: AutomationWaitObservation(workspaceSelected: false),
            system: AutomationSystemDescriptor(capabilities: [.workspaceRead])
        )
        let waitText = String(data: try AutomationJSON.encoder.encode(waitResult), encoding: .utf8)
        #expect(
            waitText
                == #"{"effectiveTimeoutMS":250,"for":"workspace_selected","observed":{"workspaceSelected":false},"outcome":"timed_out","requestedTimeoutMS":60000,"system":{"capabilities":["workspace.read"]},"waitedMS":250}"#
        )

        let focusResult = AutomationFocusResult(
            state: AutomationFocusState(
                appIsActive: false,
                keyWindowID: nil,
                firstResponderSurfaceID: nil,
                focusPossible: false
            ),
            system: AutomationSystemDescriptor(capabilities: [.windowRead])
        )
        let focusText = String(data: try AutomationJSON.encoder.encode(focusResult), encoding: .utf8)
        #expect(
            focusText
                == #"{"appIsActive":false,"focusPossible":false,"system":{"capabilities":["window.read"]}}"#
        )
    }

    @Test("Audit log records the wait condition but never the predicate pattern")
    func auditLogWaitMetadata() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-wait-audit-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)
        let requestBody = try AutomationJSON.encoder.encode(
            AutomationWaitRequest(
                condition: "surface_text_matches",
                predicate: AutomationWaitPredicate(
                    surfaceID: "11111111-1111-1111-1111-111111111111",
                    pattern: "secret-pattern"
                ),
                timeoutMS: 1_000
            )
        )
        let responseBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(
                result: AutomationWaitResult(
                    condition: .surfaceTextMatches,
                    outcome: .satisfied,
                    waitedMS: 100,
                    requestedTimeoutMS: 1_000,
                    effectiveTimeoutMS: 1_000,
                    observed: AutomationWaitObservation(textMatched: true)
                )
            )
        )

        await logger.record(
            method: "POST",
            path: "/v1/wait",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: requestBody,
            responseBody: responseBody,
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(!contents.contains("secret-pattern"))
        let event = try AutomationJSON.decoder.decode(
            AutomationAuditLogger.Event.self,
            from: Data(try #require(contents.split(separator: "\n").first).utf8)
        )
        #expect(event.metadata?["wait.for"] == "surface_text_matches")
        #expect(event.allowed)
    }

    @Test("Audit log names the surface every content read targeted, never the text it returned")
    func auditLogSurfaceReadLineage() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-surface-read-audit-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)
        let surfaceID = "33333333-3333-3333-3333-333333333333"

        await logger.record(
            method: "POST",
            path: "/v1/surface/read",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: try AutomationJSON.encoder.encode(
                AutomationSurfaceReadRequest(surfaceID: surfaceID, lines: 10)
            ),
            responseBody: try AutomationJSON.encoder.encode(
                AutomationResponseEnvelope(
                    result: AutomationSurfaceReadResult(
                        surfaceID: surfaceID,
                        requestedLines: 10,
                        lines: 10,
                        returnedLines: 1,
                        byteCount: 13,
                        text: "sensitive-text"
                    )
                )
            ),
            operatorHandle: true
        )
        // A body the typed decoder rejects (`lines` absent). An operator handle reads any live
        // surface, so which surface a caller named belongs on the record even when the call
        // never reached the controller.
        await logger.record(
            method: "POST",
            path: "/v1/surface/read",
            headers: [AutomationAPI.handleHeader: "op"],
            requestBody: Data(#"{"surfaceID":"33333333-3333-3333-3333-333333333333"}"#.utf8),
            responseBody: Data(
                #"{"ok":false,"error":{"code":"invalid_request","message":"lines is required"}}"#.utf8
            ),
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(!contents.contains("sensitive-text"))
        let events = try contents.split(separator: "\n").map {
            try AutomationJSON.decoder.decode(AutomationAuditLogger.Event.self, from: Data($0.utf8))
        }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.metadata?["surfaceRead.surfaceID"] == surfaceID })
        #expect(events[0].surfaceID == surfaceID)
        #expect(events[0].allowed)
        // The typed lineage field goes empty on the undecodable body; the metadata read is what
        // keeps the lineage complete across both.
        #expect(events[1].surfaceID == nil)
        #expect(!events[1].allowed)
    }
}

@Suite("AutomationListener", .serialized)
struct AutomationListenerTests {
    @Test("Socket smoke returns health envelope")
    @MainActor
    func socketSmoke() async throws {
        let socket = URL(fileURLWithPath: "/tmp/wm-auto-\(UUID().uuidString.prefix(8)).sock")
        let controller = FakeAutomationController()
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: controller,
            socketURLOverride: socket,
            auditLogger: nil
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(for: .milliseconds(250))

        let client = AutomationSocketClient(socketPath: socket.path)
        let response = try client.request(method: "GET", path: "/v1/health")
        let envelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationHealthResult>.self,
            from: response.body
        )

        #expect(response.statusCode == 200)
        #expect(envelope.ok)
        #expect(envelope.result?.status == "ok")
        #expect(envelope.result?.server?.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(envelope.result?.server?.protocolVersion == AutomationAPI.version)
        await listener.stop()
    }

    /// A fact the app settles *after* the listener is up, standing in for the operator
    /// credential: provisioning runs a millisecond after `start()`, so a descriptor built at
    /// start read the box before it was written and answered `operatorCredential: nil` for
    /// the life of the process (#1400).
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: AutomationOperatorProvisioning.Outcome?

        var value: AutomationOperatorProvisioning.Outcome? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                storage = newValue
            }
        }
    }

    private func health(
        from client: AutomationSocketClient
    ) throws -> AutomationServerDescriptor? {
        let response = try client.request(method: "GET", path: "/v1/health")
        return try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationHealthResult>.self,
            from: response.body
        ).result?.server
    }

    @Test("Health reports a credential provisioned after the listener started")
    @MainActor
    func healthReportsCredentialProvisionedAfterStart() async throws {
        let socket = URL(fileURLWithPath: "/tmp/wm-auto-\(UUID().uuidString.prefix(8)).sock")
        let outcome = OutcomeBox()
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: FakeAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil,
            makeHealthServer: { launchedAt in
                AutomationServerDescriptor.current(
                    launchedAt: launchedAt,
                    experiments: [],
                    operatorCredential: outcome.value
                )
            }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(for: .milliseconds(250))

        let client = AutomationSocketClient(socketPath: socket.path)

        // Nothing provisioned yet, so absent is the honest answer — and the contrast is what
        // keeps the assertion below from passing for the wrong reason.
        #expect(try health(from: client)?.operatorCredential == nil)

        outcome.value = .minted

        #expect(try health(from: client)?.operatorCredential == .minted)
        await listener.stop()
    }

    /// The reverse direction, which a fix that merely refreshed on mint would not cover: an
    /// outcome that changes again mid-run (the operator toggle flipped in Settings) has to
    /// reach health too, or the field goes stale in the other direction.
    @Test("Health follows a credential outcome that changes again mid-run")
    @MainActor
    func healthFollowsLaterOutcomeChanges() async throws {
        let socket = URL(fileURLWithPath: "/tmp/wm-auto-\(UUID().uuidString.prefix(8)).sock")
        let outcome = OutcomeBox()
        outcome.value = .minted
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: FakeAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil,
            makeHealthServer: { launchedAt in
                AutomationServerDescriptor.current(
                    launchedAt: launchedAt,
                    experiments: [],
                    operatorCredential: outcome.value
                )
            }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(for: .milliseconds(250))

        let client = AutomationSocketClient(socketPath: socket.path)
        #expect(try health(from: client)?.operatorCredential == .minted)

        outcome.value = .notOptedIn

        #expect(try health(from: client)?.operatorCredential == .notOptedIn)
        await listener.stop()
    }

    /// What building the descriptor once was actually protecting: `launchedAt` names when this
    /// listener came up, so it must not drift to "now" on every request.
    @Test("The launch instant stays fixed across requests")
    @MainActor
    func launchedAtIsStableAcrossRequests() async throws {
        let socket = URL(fileURLWithPath: "/tmp/wm-auto-\(UUID().uuidString.prefix(8)).sock")
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: FakeAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(for: .milliseconds(250))

        let client = AutomationSocketClient(socketPath: socket.path)
        let first = try health(from: client)?.launchedAt
        try await Task.sleep(for: .milliseconds(1_100))
        let second = try health(from: client)?.launchedAt

        #expect(first != nil)
        #expect(first == second)
        await listener.stop()
    }
}

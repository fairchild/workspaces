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
        return AutomationWorkspacesResult(
            repos: [
                AutomationRepoDescriptor(
                    repoID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    name: "workspaces",
                    path: "/Users/test/workspaces",
                    isSelected: true
                )
            ],
            workspaces: [
                AutomationWorkspaceDescriptor(
                    workspaceID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    repoID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
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

    var windowSnapshotCalls: [String] = []

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
        return AutomationMutationResult(changed: true, closedSurfaceID: "surface-1")
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
        let health = await AutomationHTTPRouter.route(
            HTTPRequest(method: "GET", path: "/v1/health", headers: [:], body: Data()),
            controller: controller,
            enabled: false
        )
        let healthEnvelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationHealthResult>.self,
            from: health.body
        )
        #expect(health.status == 200)
        #expect(healthEnvelope.ok)

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

    @Test("Registry mints an operator handle carrying only capture-only capabilities")
    @MainActor
    func registryRegistersOperatorHandle() {
        let registry = AutomationHandleRegistry(makeHandle: { "op-1" })
        let entry = registry.registerOperator(appScopeID: "workspaces.local")

        #expect(entry.handle == "op-1")
        #expect(entry.isOperator)
        #expect(entry.tileID == nil)
        #expect(entry.capabilities == [.windowRead, .windowSnapshot, .workspaceRead])
        // Capture-only: an operator handle never carries tile mutation or input.write.
        #expect(!entry.capabilities.contains(.tileClose))
        #expect(!entry.capabilities.contains(.inputWrite))
        #expect(registry.resolve("op-1")?.isOperator == true)

        // The handle dies with the launch: once the registry is cleared it no longer resolves,
        // so a credential left behind by a crashed launch fails closed against a fresh registry.
        registry.removeAll()
        #expect(registry.resolve("op-1") == nil)
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
        #expect(okEnvelope.result?.system.capabilities == [.windowRead, .windowSnapshot, .workspaceRead])
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
        #expect(okEnvelope.result?.system.capabilities == [.windowRead, .windowSnapshot, .workspaceRead])
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

    @Test("Operator credential round-trips through the store and is written user-only (0600)")
    func operatorCredentialStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-op-cred-\(UUID().uuidString.prefix(8)).json")
        defer { AutomationOperatorCredentialStore.remove(at: url) }

        let credential = AutomationOperatorCredential(socketPath: "/tmp/automation.sock", handle: "op-xyz")
        try AutomationOperatorCredentialStore.write(credential, to: url)

        let loaded = AutomationOperatorCredentialStore.load(from: url)
        #expect(loaded == credential)
        #expect(loaded?.capabilities == [.windowRead, .windowSnapshot, .workspaceRead])

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
            registry.resolve(mintedCredential.handle)?.capabilities == [.windowRead, .windowSnapshot, .workspaceRead]
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

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let events = try lines.map { line in
            try AutomationJSON.decoder.decode(AutomationAuditLogger.Event.self, from: Data(line.utf8))
        }
        let windowsEvent = try #require(events.first { $0.path == "/v1/windows" })
        #expect(windowsEvent.operatorHandle)
        let contextEvent = try #require(events.first { $0.path == "/v1/context" })
        #expect(!contextEvent.operatorHandle)
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
        await listener.stop()
    }
}

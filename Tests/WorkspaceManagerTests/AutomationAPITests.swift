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
                == #"{"ok":true,"result":{"status":"ok","system":{"capabilities":["context.read","surfaces.read","tile.focus","tile.split","tile.close"]}},"v":1}"#
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

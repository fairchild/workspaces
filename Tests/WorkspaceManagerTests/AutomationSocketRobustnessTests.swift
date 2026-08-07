// Socket-layer robustness coverage for the automation control socket (#1230): listener read
// deadline against hung clients, concurrent-connection cap with typed busy error, client-side
// socket timeouts, and audit log rotation/undelivered-response marking. Routing behavior is
// covered in AutomationAPITests; these tests exercise only the transport and audit layers.
import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
private final class UnroutedAutomationController: AutomationControlling {
    private var unrouted: AutomationServiceError {
        AutomationServiceError(.unsupported, "Socket robustness tests never route to the controller.")
    }

    func automationContext(for handle: String) throws -> AutomationContextResult { throw unrouted }
    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult { throw unrouted }
    func automationWindows(for handle: String) throws -> AutomationWindowsResult { throw unrouted }
    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult { throw unrouted }
    func automationSelectWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult { throw unrouted }
    func automationCreateWorkspace(
        for handle: String,
        request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult { throw unrouted }
    func automationArchiveWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceArchiveResult { throw unrouted }
    func automationWindowSnapshot(
        for handle: String,
        windowID: String
    ) async throws -> AutomationWindowSnapshotResult { throw unrouted }
    func automationReadSurface(
        for handle: String,
        request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult { throw unrouted }
    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult { throw unrouted }
    func automationWebSurfaceSnapshot(
        for handle: String,
        sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult { throw unrouted }
    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult { throw unrouted }
    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult { throw unrouted }
    func automationCloseTile(for handle: String) throws -> AutomationMutationResult { throw unrouted }
    func automationWriteInput(
        for handle: String,
        text: String,
        submit: Bool
    ) throws -> AutomationInputWriteResult { throw unrouted }
    func automationHandleIsOperator(_ handle: String) -> Bool { false }
}

/// Raw Darwin socket helpers so tests can hold a connection open without sending a request,
/// or run a listener that never responds — states AutomationSocketClient cannot produce.
private enum RawUnixSocket {
    static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for index in 0..<capacity { buffer[index] = 0 }
                for (index, byte) in pathBytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
            }
        }
        return true
    }

    static func connect(to path: String, receiveTimeout: TimeInterval) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var deadline = timeval(tv_sec: Int(receiveTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        guard fill(&address, path: path) else {
            close(fd)
            return -1
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard result == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func listenWithoutAccepting(at path: String) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        guard fill(&address, path: path) else {
            close(fd)
            return -1
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, length)
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }
}

private func uniqueSocketPath(_ prefix: String) -> String {
    "/tmp/\(prefix)-\(UUID().uuidString.prefix(8)).sock"
}

@Suite("AutomationSocketRobustness", .serialized)
struct AutomationSocketRobustnessTests {
    @Test("Listener read deadline closes a hung client connection")
    @MainActor
    func readDeadlineClosesHungClient() async throws {
        let socket = URL(fileURLWithPath: uniqueSocketPath("wm-robust-deadline"))
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: UnroutedAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil,
            readDeadline: .milliseconds(200)
        )
        try await listener.start()
        try await Task.sleep(for: .milliseconds(250))

        // Connect and send nothing; the server must hang up on its own within the deadline.
        let fd = RawUnixSocket.connect(to: socket.path, receiveTimeout: 10)
        defer { if fd >= 0 { close(fd) } }
        #expect(fd >= 0)

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &buffer, buffer.count)
        // EOF (0) proves the listener cancelled the hung connection; a negative return here
        // means the generous client-side timeout fired first, i.e. no server deadline.
        #expect(count == 0)
        await listener.stop()
    }

    @Test("Connections over the concurrency cap receive a typed busy error")
    @MainActor
    func connectionCapReturnsBusy() async throws {
        let socket = URL(fileURLWithPath: uniqueSocketPath("wm-robust-cap"))
        let listener = AutomationListener(
            bundleIdentifier: "com.test.workspaces",
            controller: UnroutedAutomationController(),
            socketURLOverride: socket,
            auditLogger: nil,
            maxConcurrentConnections: 1,
            readDeadline: .seconds(30)
        )
        try await listener.start()
        try await Task.sleep(for: .milliseconds(250))

        // Occupy the single slot with a connection that never sends a request.
        let heldFD = RawUnixSocket.connect(to: socket.path, receiveTimeout: 30)
        defer { if heldFD >= 0 { close(heldFD) } }
        #expect(heldFD >= 0)
        try await Task.sleep(for: .milliseconds(300))

        let client = AutomationSocketClient(socketPath: socket.path, timeout: 10)
        let response = try client.request(method: "GET", path: "/v1/health")
        let envelope = try AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: response.body
        )

        #expect(response.statusCode == 503)
        #expect(!envelope.ok)
        #expect(envelope.error?.code == .busy)
        await listener.stop()
    }

    @Test("Client read timeout throws a typed error instead of blocking")
    func clientTimeoutThrowsTypedError() throws {
        let path = uniqueSocketPath("wm-robust-timeout")
        let serverFD = RawUnixSocket.listenWithoutAccepting(at: path)
        defer {
            if serverFD >= 0 { close(serverFD) }
            unlink(path)
        }
        #expect(serverFD >= 0)

        // The backlog completes the connect and buffers the request, but nothing ever responds.
        let client = AutomationSocketClient(socketPath: path, timeout: 0.3)
        do {
            _ = try client.request(method: "GET", path: "/v1/health")
            Issue.record("Expected a typed timeout error")
        } catch let error as AutomationSocketClient.ClientError {
            #expect(error == .timedOut(0.3))
            #expect(error.errorDescription?.contains("did not respond") == true)
        }
    }

    @Test("Audit log rotates at the size threshold and keeps a bounded set")
    func auditLogRotatesAtThreshold() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-robust-rotate-\(UUID().uuidString.prefix(8)).jsonl")
        defer {
            try? FileManager.default.removeItem(at: auditURL)
            for index in 1...3 {
                try? FileManager.default.removeItem(atPath: "\(auditURL.path).\(index)")
            }
        }
        let logger = AutomationAuditLogger(auditURL: auditURL, maxFileBytes: 512, maxRotatedFiles: 2)
        let okBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(result: AutomationEmptyResult())
        )

        // Each event line is well over 100 bytes, so 40 events must cross the 512-byte
        // threshold several times over.
        for _ in 0..<40 {
            await logger.record(
                method: "GET",
                path: "/v1/health",
                headers: [:],
                responseBody: okBody
            )
        }

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: "\(auditURL.path).1"))
        #expect(manager.fileExists(atPath: "\(auditURL.path).2"))
        #expect(!manager.fileExists(atPath: "\(auditURL.path).3"))

        let activeSize = try #require(
            manager.attributesOfItem(atPath: auditURL.path)[.size] as? Int
        )
        // Rotation happens before an append once the threshold is reached, so the active file
        // never grows beyond the threshold plus a single event line.
        #expect(activeSize < 1024)

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        for line in contents.split(separator: "\n") {
            let event = try AutomationJSON.decoder.decode(
                AutomationAuditLogger.Event.self,
                from: Data(String(line).utf8)
            )
            #expect(event.path == "/v1/health")
        }
    }

    @Test("Undelivered responses append a marker entry after the completed mutation")
    func undeliveredResponseAppendsMarkerEntry() async throws {
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-robust-undelivered-\(UUID().uuidString.prefix(8)).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let logger = AutomationAuditLogger(auditURL: auditURL)
        let okBody = try AutomationJSON.encoder.encode(
            AutomationResponseEnvelope(result: AutomationEmptyResult())
        )

        await logger.record(
            method: "POST",
            path: "/v1/tile/close",
            headers: [AutomationAPI.handleHeader: "op"],
            responseBody: okBody,
            operatorHandle: true
        )
        await logger.recordResponseUndelivered(
            method: "POST",
            path: "/v1/tile/close",
            handlePresent: true,
            operatorHandle: true
        )

        let contents = try String(contentsOf: auditURL, encoding: .utf8)
        let events = try contents.split(separator: "\n").map { line in
            try AutomationJSON.decoder.decode(
                AutomationAuditLogger.Event.self,
                from: Data(String(line).utf8)
            )
        }
        #expect(events.count == 2)
        #expect(events[0].responseUndelivered == nil)
        let marker = events[1]
        #expect(marker.responseUndelivered == true)
        #expect(marker.method == "POST")
        #expect(marker.path == "/v1/tile/close")
        #expect(marker.operatorHandle)
    }
}

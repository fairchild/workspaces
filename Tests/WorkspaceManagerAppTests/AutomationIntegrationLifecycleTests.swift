//
//  AutomationIntegrationLifecycleTests.swift
//  Verifies the App Intents operator gate (Shortcuts mint an operator handle only while the operator
//  experiment is on, re-checked on every call) and where the plane's files live: a lifecycle given a
//  scratch root keeps its socket and credential there, and never removes a credential another launch
//  minted — the path by which `swift test` deleted the installed app's (#1607). A stop, including one
//  that lands while a start is still binding or one whose bind fails, leaves no listener or credential of
//  its own behind, and two stops at once finish together, so the plane started after them survives both.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AutomationIntegrationLifecycle", .serialized)
struct AutomationIntegrationLifecycleTests {
    /// A scratch automation directory with the installed app's file names in it. Short, because the
    /// socket path has to fit `sun_path`.
    private func makeScratchPlane() throws -> (root: URL, files: AutomationPlaneFiles) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-lc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let installed = AutomationPlaneFiles.bundled("com.cloudcompute.workspaces")
        func inRoot(_ url: URL) -> URL { root.appendingPathComponent(url.lastPathComponent) }
        let files = AutomationPlaneFiles(
            socketURL: inRoot(installed.socketURL),
            auditURL: inRoot(installed.auditURL),
            credentialURL: inRoot(installed.credentialURL)
        )
        try #require(
            files.socketURL.path.utf8.count < AutomationSupportDirectory.maximumSocketPathLength,
            "TMPDIR is too deep for a bindable socket: \(files.socketURL.path) overruns sun_path"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return (root, files)
    }

    @Test("Shortcuts mint is gated on the operator experiment and re-checked per call")
    func appIntentMintGate() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isAutomationAPIEnabled: { false })
        await lifecycle.configure(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )

        // Gate off: the Shortcuts path fails closed with a clear disabled error and mints nothing.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the disabled operator experiment to fail closed.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
            #expect(error.response.message.contains("Automation Operator Scope"))
        }

        // Gate on: mints one operator handle and reuses it across calls.
        let first = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(lifecycle.handleRegistry.resolve(first.handle)?.isOperator == true)
        let second = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: true)
        #expect(second.handle == first.handle)

        // The gate runs before the cached-handle fast path: flipping the experiment off
        // mid-launch cuts Shortcuts off even though a handle is already minted.
        do {
            _ = try lifecycle.appIntentControllerAndHandle(isOperatorEnabled: false)
            Issue.record("Expected the re-checked gate to fail closed despite a cached handle.")
        } catch let error as AutomationServiceError {
            #expect(error.response.code == .capabilityDenied)
        }

        await lifecycle.stop()
    }

    /// The injected files have to reach the listener and the credential store, not merely be held:
    /// a lifecycle still resolving its bundle's directory binds and mints beside the installed app.
    @Test("A lifecycle given a scratch root listens and mints there, and stopping removes what it minted")
    func planeStaysInsideItsRoot() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let socketPath = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let minted = AutomationOperatorCredentialStore.load(from: plane.files.credentialURL)
        // Stop before asserting, so a failed expectation cannot leave the listener bound.
        await lifecycle.stop()

        #expect(socketPath == plane.files.socketURL.path)
        #expect(minted?.socketPath == socketPath)
        #expect(AutomationOperatorCredentialStore.load(from: plane.files.credentialURL) == nil)
    }

    /// Every launch keyed on one bundle identifier shares the credential path, so the file there can
    /// hold another launch's credential by the time this one stops. What this launch removes has to
    /// be the credential it minted, not whatever sits at that path.
    @Test("Stopping leaves a credential another launch wrote over the one this launch minted")
    func leavesAReplacedCredential() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let socketPath = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let minted = AutomationOperatorCredentialStore.load(from: plane.files.credentialURL)
        let replacement = AutomationOperatorCredential(socketPath: socketPath, handle: "another-launch")
        try? AutomationOperatorCredentialStore.write(replacement, to: plane.files.credentialURL)
        await lifecycle.stop()

        #expect(minted != nil)
        #expect(AutomationOperatorCredentialStore.load(from: plane.files.credentialURL) == replacement)
    }

    /// The credential is cleared before the listener shuts down, and a defaults change can land while
    /// it does. Nothing may mint a fresh credential behind the clear and leave it on disk once `stop()`
    /// has returned.
    @Test("A defaults change while stopping does not mint a credential that outlives the stop")
    func defaultsChangeDuringStopLeavesNoCredential() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        _ = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let minted = AutomationOperatorCredentialStore.load(from: plane.files.credentialURL)

        // Let stop() run to its first suspension, the listener shutting down, then change defaults.
        let stopping = Task { await lifecycle.stop() }
        await Task.yield()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await stopping.value

        #expect(minted != nil)
        #expect(AutomationOperatorCredentialStore.load(from: plane.files.credentialURL) == nil)
    }

    /// `stop()` can land while `startIfNeeded` is still waiting on the bind. Once both have settled, that
    /// start may not have published the listener it bound or minted a credential for it (#1665).
    @Test("A stop while a start is still binding leaves no listener or credential behind")
    func stopDuringStartLeavesNothingBehind() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let starting = Task {
            try await lifecycle.startIfNeeded(
                tileTreeStore: TileTreeStore(),
                focusTerminal: { _ in },
                requestCloseTerminal: { _ in }
            )
        }
        // stop() lands once the start is waiting on the bind.
        let binding = await yield(until: { lifecycle.startWaiters == 1 })
        await lifecycle.stop()
        let started = await starting.result
        let left = await leftovers(of: lifecycle, files: plane.files)
        // Stop again before asserting, so a start that published anyway cannot leave its listener bound.
        await lifecycle.stop()

        #expect(binding)
        // A cancellation, not merely a failure: a start that failed to bind would also leave nothing behind.
        #expect(throws: CancellationError.self) { try started.get() }
        #expect(left == .nothing)
    }

    /// A configure pass that joined the start refreshes the credential once the start settles, so the
    /// stop has to turn that pass away as well as the one that started the listener.
    @Test("A configure pass waiting on a start that stop cancelled mints no credential")
    func stopDuringJoinedStartLeavesNothingBehind() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(
            files: plane.files,
            isAutomationAPIEnabled: { true },
            isOperatorEnabled: { true }
        )
        let store = TileTreeStore()

        // The first pass starts the listener and the second joins that start; both are waiting on the
        // bind when stop() lands.
        let starting = Task {
            await lifecycle.configure(tileTreeStore: store, focusTerminal: { _ in }, requestCloseTerminal: { _ in })
        }
        let joining = Task {
            await lifecycle.configure(tileTreeStore: store, focusTerminal: { _ in }, requestCloseTerminal: { _ in })
        }
        let joined = await yield(until: { lifecycle.startWaiters == 2 })
        // Nothing published yet means the stop below lands on the start, not on an ordinary shutdown.
        let publishedBeforeStop = lifecycle.socketPath
        await lifecycle.stop()
        await starting.value
        await joining.value
        let left = await leftovers(of: lifecycle, files: plane.files)
        await lifecycle.stop()

        #expect(joined)
        #expect(publishedBeforeStop == nil)
        #expect(left == .nothing)
    }

    /// A start whose bind fails while a stop waits on it belongs to that stop as well. Its waiters get the
    /// stop's cancellation rather than the bind error, so a configure pass among them takes the path that
    /// leaves the plane to the stop instead of the one that clears the tile store and the handle registry.
    @Test("A start that fails while a stop waits on it hands every waiter the stop's cancellation")
    func failedStartDuringStopCancelsItsWaiters() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        // Another launch holds the plane's socket lock, so this lifecycle's bind throws.
        let otherLaunch = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { false })
        _ = try await otherLaunch.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        func start() -> Task<String, Error> {
            Task {
                try await lifecycle.startIfNeeded(
                    tileTreeStore: TileTreeStore(),
                    focusTerminal: { _ in },
                    requestCloseTerminal: { _ in }
                )
            }
        }
        let starting = start()
        let joining = start()
        let joined = await yield(until: { lifecycle.startWaiters == 2 })
        await lifecycle.stop()
        let results = [await starting.result, await joining.result]
        await otherLaunch.stop()
        let left = await leftovers(of: lifecycle, files: plane.files)
        await lifecycle.stop()

        #expect(joined)
        for result in results {
            #expect(throws: CancellationError.self) { try result.get() }
        }
        #expect(left == .nothing)
    }

    /// Two stops can wait on the same start. The second finishes with the first instead of tearing down
    /// again, so what a caller sets up once either stop has returned, a tile's handle and a fresh start,
    /// is still in place after both have (#1679).
    @Test("A second stop finishes with the first, so the plane started after them survives both")
    func concurrentStopsLeaveTheNextPlaneIntact() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isOperatorEnabled: { true })

        let starting = Task {
            try await lifecycle.startIfNeeded(
                tileTreeStore: TileTreeStore(),
                focusTerminal: { _ in },
                requestCloseTerminal: { _ in }
            )
        }
        let binding = await yield(until: { lifecycle.startWaiters == 1 })
        // Each caller stops, then at once registers a handle and starts again, as a window would.
        func stopThenRestart() -> Task<(handle: String, socketPath: String), Error> {
            Task {
                await lifecycle.stop()
                let handle = lifecycle.handleRegistry.registerOperator(appScopeID: "test").handle
                let socketPath = try await lifecycle.startIfNeeded(
                    tileTreeStore: TileTreeStore(),
                    focusTerminal: { _ in },
                    requestCloseTerminal: { _ in }
                )
                return (handle, socketPath)
            }
        }
        let first = stopThenRestart()
        let second = stopThenRestart()
        let cancelled = await starting.result
        let restarts = [await first.result, await second.result]
        let handlesResolve = restarts.compactMap { try? $0.get().handle }.map {
            lifecycle.handleRegistry.resolve($0) != nil
        }
        let running = await leftovers(of: lifecycle, files: plane.files)
        await lifecycle.stop()
        let left = await leftovers(of: lifecycle, files: plane.files)

        #expect(binding)
        #expect(throws: CancellationError.self) { try cancelled.get() }
        #expect(restarts.map { try? $0.get().socketPath } == [plane.files.socketURL.path, plane.files.socketURL.path])
        #expect(handlesResolve == [true, true])
        #expect(running.socketPath == plane.files.socketURL.path)
        #expect(running.credential?.socketPath == plane.files.socketURL.path)
        #expect(running.lockHeld)
        #expect(left == .nothing)
    }

    /// Yields until `condition` holds, so a test acts on the state it needs rather than on how far one
    /// yield happened to get. Bounded by a count of yields, not a clock.
    private func yield(until condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 where !condition() {
            await Task.yield()
        }
        return condition()
    }

    /// What a stop left on its plane: the credential, the published socket path, and whether the socket
    /// lock is still held, which a fresh launch finds by trying to take the plane. The socket file is no
    /// signal: Network.framework creates it when the bind lands on its own queue, which can be after the
    /// listener's stop removed it, leaving a file with nothing listening behind it.
    private struct Leftovers: Equatable {
        var credential: AutomationOperatorCredential?
        var socketPath: String?
        var lockHeld: Bool

        static let nothing = Leftovers(credential: nil, socketPath: nil, lockHeld: false)
    }

    private func leftovers(
        of lifecycle: AutomationIntegrationLifecycle,
        files: AutomationPlaneFiles
    ) async -> Leftovers {
        let credential = AutomationOperatorCredentialStore.load(from: files.credentialURL)
        let socketPath = lifecycle.socketPath
        let probe = AutomationIntegrationLifecycle(files: files, isOperatorEnabled: { false })
        let probeBound =
            (try? await probe.startIfNeeded(
                tileTreeStore: TileTreeStore(),
                focusTerminal: { _ in },
                requestCloseTerminal: { _ in }
            )) != nil
        await probe.stop()
        return Leftovers(credential: credential, socketPath: socketPath, lockHeld: !probeBound)
    }

    /// #1607 inside a scratch root: the installed app's credential sits at the path this lifecycle
    /// resolves, and the lifecycle is configured and stopped with the Automation API off, as it is in
    /// the test process. Neither pass may remove a file this launch did not mint.
    @Test("Configuring and stopping leaves a credential this launch did not mint")
    func leavesAnotherLaunchsCredential() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let installedAppsCredential = Data(#"{"handle":"installed-app"}"#.utf8)
        try installedAppsCredential.write(to: plane.files.credentialURL)
        let lifecycle = AutomationIntegrationLifecycle(files: plane.files, isAutomationAPIEnabled: { false })

        await lifecycle.configure(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        #expect(FileManager.default.contents(atPath: plane.files.credentialURL.path) == installedAppsCredential)

        await lifecycle.stop()
        #expect(FileManager.default.contents(atPath: plane.files.credentialURL.path) == installedAppsCredential)
    }

    /// The listener re-checks the Automation API decision on every request past `/v1/health`, so that
    /// decision has to be the one the lifecycle was given: told the API is on, it serves; told
    /// otherwise mid-run, the next request is refused as disabled.
    @Test("The listener enforces the injected Automation API decision on each request")
    func listenerFollowsTheInjectedAPIDecision() async throws {
        let plane = try makeScratchPlane()
        defer { try? FileManager.default.removeItem(at: plane.root) }
        let apiEnabled = APIDecision(true)
        let lifecycle = AutomationIntegrationLifecycle(
            files: plane.files,
            isAutomationAPIEnabled: { apiEnabled.value }
        )

        let socketPath = try await lifecycle.startIfNeeded(
            tileTreeStore: TileTreeStore(),
            focusTerminal: { _ in },
            requestCloseTerminal: { _ in }
        )
        let client = AutomationSocketClient(socketPath: socketPath, timeout: 5)
        let listening = await Self.waitForHealth(client)
        let whileOn = await Self.errorCode(client, path: "/v1/context")
        apiEnabled.value = false
        let whileOff = await Self.errorCode(client, path: "/v1/context")
        await lifecycle.stop()

        #expect(listening)
        // No handle is sent, so a listener that is on refuses for that reason instead.
        #expect(whileOn != nil && whileOn != .disabled)
        #expect(whileOff == .disabled)
    }

    /// Waits for the listener to answer rather than for a tuned interval: it binds asynchronously.
    private static func waitForHealth(_ client: AutomationSocketClient) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let response = await Task.detached { try? client.request(method: "GET", path: "/v1/health") }.value
            if response?.statusCode == 200 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// Requests run off the main actor, which the listener's controller may need while answering.
    private static func errorCode(_ client: AutomationSocketClient, path: String) async -> AutomationErrorCode? {
        let response = await Task.detached { try? client.request(method: "GET", path: path) }.value
        guard let body = response?.body else { return nil }
        let envelope = try? AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationEmptyResult>.self,
            from: body
        )
        return envelope?.error?.code
    }
}

/// The injected Automation API decision, flipped by the test while the listener reads it per request.
private final class APIDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) { storage = value }

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

//
//  AgentsIntegrationStatusTests.swift
//  WorkspaceManagerAppTests
//
//  The Settings → Agents status row: how the settings-file probe, the opt-in, the hook
//  listener probe and the last install attempt combine into active, degraded or failed;
//  the listener probe against sockets that answer and ones that don't; and one rendered
//  PNG per state, written for PR evidence.
//

import AppKit
import Darwin
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("AgentsIntegrationStatus")
struct AgentsIntegrationStatusTests {
    private func status(
        isChecking: Bool = false,
        isOptedIn: Bool = true,
        isInstalled: Bool = true,
        listenerFailure: String? = nil,
        installFailure: String? = nil
    ) -> AgentsIntegrationStatus {
        AgentsIntegrationStatus(
            isChecking: isChecking,
            isOptedIn: isOptedIn,
            isInstalled: isInstalled,
            listenerFailure: listenerFailure,
            installFailure: installFailure
        )
    }

    @Test("Installed hooks and an answering listener are active, opted in or not")
    func installedAndAnsweringIsActive() {
        #expect(status() == .active)
        #expect(status(isOptedIn: false) == .active)
    }

    /// The condition the standalone re-install banner used to cover.
    @Test("Opted in with the hooks gone from the settings file is degraded")
    func optedInWithoutHooksIsDegraded() {
        #expect(status(isInstalled: false) == .degraded(.hooksMissing))
        #expect(status(isInstalled: false, listenerFailure: "silent") == .degraded(.hooksMissing))
    }

    @Test("Installed hooks this app isn't listening for are degraded with the probe's reason")
    func notListeningIsDegraded() {
        let reason = "Nothing answered at /tmp/hooks.sock: Connection refused."
        #expect(status(listenerFailure: reason) == .degraded(.notListening(reason: reason)))
        #expect(status(isOptedIn: false, listenerFailure: reason) == .degraded(.notListening(reason: reason)))
    }

    @Test("An install attempt that errored is failed with its error text, whatever the settings file says")
    func erroredInstallIsFailed() {
        let error = "You don’t have permission to save the file “settings.json” in the folder “.claude”."
        #expect(status(installFailure: error) == .failed(error: error))
        #expect(status(isInstalled: false, installFailure: error) == .failed(error: error))
        #expect(status(isOptedIn: false, isInstalled: false, installFailure: error) == .failed(error: error))
        #expect(status(listenerFailure: "silent", installFailure: error) == .failed(error: error))
    }

    @Test("Neither opted in nor installed is not installed, and checking outranks every other input")
    func surroundingStates() {
        #expect(status(isOptedIn: false, isInstalled: false) == .notInstalled)
        #expect(status(isOptedIn: false, isInstalled: false, listenerFailure: "silent") == .notInstalled)
        #expect(status(isChecking: true) == .checking)
        #expect(status(isChecking: true, isInstalled: false, installFailure: "threw") == .checking)
    }

    @Test("Active, degraded and failed each have their own symbol and colour, and a title that names the state")
    func healthStatesAreDistinct() {
        let active = AgentsIntegrationStatus.active
        let degraded = AgentsIntegrationStatus.degraded(.hooksMissing)
        let failed = AgentsIntegrationStatus.failed(error: "threw")

        #expect(Set([active, degraded, failed].map(\.symbolName)).count == 3)
        #expect(Set([active, degraded, failed].map(\.color)).count == 3)
        #expect(active.title.hasPrefix("Active"))
        #expect(degraded.title.hasPrefix("Degraded"))
        #expect(failed.title.hasPrefix("Failed"))

        let notListening = AgentsIntegrationStatus.degraded(.notListening(reason: "refused"))
        #expect(notListening.symbolName == degraded.symbolName)
        #expect(notListening.color == degraded.color)
        #expect(notListening.title.hasPrefix("Degraded"))
        #expect(notListening.title != degraded.title)
    }
}

@Suite("Hook listener probe")
struct HookListenerProbeTests {
    /// Under `/tmp` directly: the per-user temporary directory plus a UUID overflows the
    /// 104 bytes a Unix socket address holds.
    private static func socketPath() -> String {
        "/tmp/wm-probe-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Binds and listens on `path` with plain POSIX calls, so the socket accepts connections
    /// as soon as this returns. Closing the descriptor stops listening and leaves the file.
    private static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(fd, 4) == 0)
        return fd
    }

    private func probe(_ path: String?) -> String? {
        ClaudeIntegrationLifecycle.hookListenerProbeFailure(socketPath: path)
    }

    @Test("A socket something listens on answers")
    func listeningSocketAnswers() throws {
        let path = Self.socketPath()
        let fd = try Self.listen(at: path)
        defer {
            close(fd)
            unlink(path)
        }
        #expect(probe(path) == nil)
    }

    /// What a dormant instance meets: its hook socket answered by the process that holds the
    /// lock. The test's own listener stands in for that process, checked against the pid of
    /// the test's parent as the app's.
    @Test("A socket another process listens on is not this app's listener")
    func anotherProcessIsNotThisAppsListener() throws {
        let path = Self.socketPath()
        let fd = try Self.listen(at: path)
        defer {
            close(fd)
            unlink(path)
        }
        let failure = try #require(
            ClaudeIntegrationLifecycle.hookListenerProbeFailure(socketPath: path, listenerProcess: getppid())
        )
        #expect(failure.contains("pid \(getpid())"))
        #expect(failure.contains(path))
    }

    /// A socket file left behind by a listener that exited is the case a crashed app leaves.
    @Test("A socket file nobody listens on, a missing socket and an unstarted listener each say why")
    func silentSocketsSayWhy() throws {
        let stale = Self.socketPath()
        close(try Self.listen(at: stale))
        defer { unlink(stale) }
        let staleFailure = try #require(probe(stale))
        #expect(staleFailure.contains(stale))
        #expect(staleFailure.contains("Connection refused"))

        let missing = Self.socketPath()
        let missingFailure = try #require(probe(missing))
        #expect(missingFailure.contains(missing))
        #expect(missingFailure.contains("No such file or directory"))

        #expect(probe(nil) != nil)
    }

    /// The app's own listener, not a stand-in: `NWListener` binds after `start()` returns, so
    /// the test waits on the probe answering rather than asserting on the first try.
    @MainActor
    @Test("The hook listener answers once started and stops answering once stopped")
    func hookListenerAnswers() async throws {
        let socketURL = URL(fileURLWithPath: Self.socketPath())
        defer { unlink(socketURL.deletingPathExtension().appendingPathExtension("lock").path) }
        let listener = AgentHookListener(
            bundleIdentifier: "com.cloudcompute.workspaces.probe-tests",
            registry: AgentSessionRegistry(),
            socketURLOverride: socketURL,
            logger: { _ in }
        )
        try await listener.start()

        let deadline = Date().addingTimeInterval(10)
        while probe(socketURL.path) != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(probe(socketURL.path) == nil)

        await listener.stop()
        #expect(probe(socketURL.path) != nil)
    }
}

@MainActor
@Suite("AgentsIntegrationStatusRow render")
struct AgentsIntegrationStatusRowRenderTests {
    /// `WORKSPACES_EVIDENCE_DIR` when set, a fixed temporary directory otherwise.
    private static let evidenceDirectory: URL = {
        if let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-status-row", isDirectory: true)
    }()

    /// The row at the Settings pane's width, with the paths a real install shows.
    private func row(_ status: AgentsIntegrationStatus, showsFailureDetails: Bool = false) -> some View {
        AgentsIntegrationStatusRow(
            status: status,
            settingsPath: "/Users/me/.claude/settings.json",
            settingsModificationDate: Date(timeIntervalSince1970: 1_789_394_400),
            backupPath:
                "/Users/me/Library/Application Support/com.cloudcompute.workspaces/ClaudeSettingsBackups/"
                + "settings.json.workspaces-backup-2026-09-14T13-40-00Z",
            showsFailureDetails: showsFailureDetails,
            onInstall: {},
            onRecheck: {}
        )
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
    }

    /// Renders `content` to a non-empty image and writes it as a PNG, printing the path.
    private func render(_ content: some View, evidenceName: String) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)

        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.evidenceDirectory, withIntermediateDirectories: true)
        let url = Self.evidenceDirectory.appendingPathComponent(evidenceName)
        try png.write(to: url)
        print("AgentsIntegrationStatusRow render: \(url.path)")
    }

    @Test("Active renders a green check and no action")
    func rendersActive() throws {
        try render(row(.active), evidenceName: "agents-status-active.png")
    }

    /// The re-install banner's condition, now the degraded row with its Re-install action.
    @Test("Degraded with the hooks gone renders an orange warning and Re-install")
    func rendersDegradedHooksMissing() throws {
        try render(row(.degraded(.hooksMissing)), evidenceName: "agents-status-degraded-hooks-missing.png")
    }

    /// The reason is the probe's own text for a socket nothing answers on.
    @Test("Degraded without this app listening renders the probe's reason and Check again")
    func rendersDegradedNotListening() throws {
        let socketPath = "/Users/me/Library/Application Support/com.cloudcompute.workspaces/hooks.sock"
        let reason = try #require(ClaudeIntegrationLifecycle.hookListenerProbeFailure(socketPath: socketPath))
        try render(
            row(.degraded(.notListening(reason: reason))),
            evidenceName: "agents-status-degraded-not-listening.png"
        )
    }

    @Test("Failed renders a red mark, Try again, and the error text behind Details")
    func rendersFailed() throws {
        let error = "You don’t have permission to save the file “settings.json” in the folder “.claude”."
        try render(row(.failed(error: error)), evidenceName: "agents-status-failed.png")
        try render(
            row(.failed(error: error), showsFailureDetails: true),
            evidenceName: "agents-status-failed-details.png"
        )
    }
}

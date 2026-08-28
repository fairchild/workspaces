//
//  AutomationSupportDirectoryTests.swift
//  WorkspaceManagerTests
//
//  Coverage for where the automation plane writes (#1391). The property that matters is that a
//  synthetic run's socket, audit log, and operator credential all move together and land nowhere
//  near the running app's — one shared directory is what let a second instance delete the daily
//  driver's credential.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("AutomationSupportDirectory")
struct AutomationSupportDirectoryTests {
    private let bundleID = "com.cloudcompute.workspaces"

    @Test("Without a synthetic root the directory is the real Application Support one")
    func realLaunchUsesApplicationSupport() {
        let url = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: [:])

        #expect(url.lastPathComponent == bundleID)
        #expect(url.path.contains("Application Support"))
    }

    /// The whole point: an isolated launch must not resolve to the path a running app owns.
    @Test("A synthetic root gets its own automation directory")
    func syntheticRootRelocatesTheDirectory() {
        let root = "/tmp/synthetic-run-\(UUID().uuidString)"
        let environment = [SyntheticRunRoot.environmentKey: root]

        let isolated = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: environment)
        let real = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: [:])

        #expect(isolated.path != real.path)
        #expect(!isolated.path.contains("Application Support"))
        // Under the per-user temporary directory, never /tmp: that is mode 01777, and another
        // local account could pre-create the predictable path and own what is written inside it.
        #expect(isolated.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(isolated.lastPathComponent.hasPrefix("ws-auto-"))
    }

    /// The bundle identifier rides in the digest rather than a path component — one short
    /// component keeps the socket inside `sun_path` — so it still has to separate two apps
    /// sharing a root.
    @Test("Different bundle identifiers under one root do not collide")
    func differentBundleIdentifiersAreDistinct() {
        let environment = [SyntheticRunRoot.environmentKey: "/tmp/shared-root"]

        let first = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: environment)
        let second = AutomationSupportDirectory.url(
            bundleIdentifier: "com.cloudcompute.workspaces.helper", environment: environment)

        #expect(first.path != second.path)
    }

    /// Two different synthetic roots must not share one automation plane, or isolating a run
    /// from the daily driver would still collide it with the next isolated run.
    @Test("Different synthetic roots get different directories")
    func differentRootsAreDistinct() {
        let a = AutomationSupportDirectory.url(
            bundleIdentifier: bundleID, environment: [SyntheticRunRoot.environmentKey: "/tmp/root-a"])
        let b = AutomationSupportDirectory.url(
            bundleIdentifier: bundleID, environment: [SyntheticRunRoot.environmentKey: "/tmp/root-b"])

        #expect(a.path != b.path)
    }

    /// The same root must resolve identically in every process — the app and the CLI launched
    /// into one root have to find the same socket.
    @Test("The same synthetic root resolves identically")
    func sameRootIsStable() {
        let environment = [SyntheticRunRoot.environmentKey: "/tmp/stable-root"]

        let first = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: environment)
        let second = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: environment)

        #expect(first.path == second.path)
    }

    /// The constraint that made nesting inside the root wrong: `sun_path` is 104 bytes, and a
    /// synthetic root is usually a deep scratch path. Overrunning it binds no socket while the
    /// credential is still written, naming a path nothing listens on.
    @Test("An isolated socket path fits inside sun_path, however deep the root")
    func isolatedSocketPathFitsInSunPath() {
        let deepRoot = "/private/tmp/claude-501/" + String(repeating: "nested-directory/", count: 12) + "scratch"
        #expect(deepRoot.count > AutomationSupportDirectory.maximumSocketPathLength)

        let socket = AutomationSupportDirectory.fileURL(
            named: "automation.sock",
            bundleIdentifier: bundleID,
            environment: [SyntheticRunRoot.environmentKey: deepRoot]
        )

        #expect(socket.path.utf8.count < AutomationSupportDirectory.maximumSocketPathLength)
    }

    /// Socket, audit log, and credential share one resolver precisely so they cannot drift apart
    /// — an isolated socket beside a real credential would be the same bug in a new shape.
    @Test("Every automation file moves together under a synthetic root")
    func allAutomationFilesMoveTogether() {
        let root = "/tmp/synthetic-run-\(UUID().uuidString)"
        let environment = [SyntheticRunRoot.environmentKey: root]
        let directory = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: environment)

        for name in ["automation.sock", "automation-audit.jsonl", "automation-operator.json"] {
            let file = AutomationSupportDirectory.fileURL(
                named: name, bundleIdentifier: bundleID, environment: environment)
            #expect(file.deletingLastPathComponent().path == directory.path)
            #expect(file.lastPathComponent == name)
        }
    }

    /// An empty or whitespace-only value is not a root; treating it as one would silently
    /// relocate a real launch's automation plane.
    @Test("An empty synthetic root reads as unset", arguments: ["", "   "])
    func emptySyntheticRootIsIgnored(rawValue: String) {
        let url = AutomationSupportDirectory.url(
            bundleIdentifier: bundleID,
            environment: [SyntheticRunRoot.environmentKey: rawValue]
        )

        #expect(url.path == AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: [:]).path)
    }

    /// `WORKSPACES_DATA_DIR` moves the model store and local-state sidecar only. A run that
    /// relocates its data but not its automation plane still shares one socket and one
    /// credential with the app it runs beside, which is the case that caused #1391.
    @Test("A data-dir override alone does not move the automation directory")
    func dataDirAloneDoesNotRelocate() {
        let url = AutomationSupportDirectory.url(
            bundleIdentifier: bundleID,
            environment: ["WORKSPACES_DATA_DIR": "/tmp/some-isolated-data-dir"]
        )

        #expect(url.path == AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: [:]).path)
    }
}

/// The consumers, not just the helper (#1391). Asserting the helper alone would pass with any
/// one of the three reverted to its own Application Support lookup, which is the shape of the
/// original bug.
@Suite("Automation paths follow the support directory")
struct AutomationPathConsumerTests {
    private let bundleID = "com.cloudcompute.workspaces"

    @Test("Socket, audit log, and credential all resolve into the automation directory")
    func everyConsumerUsesTheSharedDirectory() {
        let directory = AutomationSupportDirectory.url(bundleIdentifier: bundleID, environment: [:])

        let socket = AutomationListener.defaultSocketURL(bundleIdentifier: bundleID)
        let audit = AutomationAuditLogger.defaultAuditURL(bundleIdentifier: bundleID)
        let credential = AutomationOperatorCredentialStore.defaultURL(bundleIdentifier: bundleID)

        #expect(socket.deletingLastPathComponent().path == directory.path)
        #expect(audit.deletingLastPathComponent().path == directory.path)
        #expect(credential.deletingLastPathComponent().path == directory.path)
        #expect(socket.lastPathComponent == "automation.sock")
        #expect(audit.lastPathComponent == "automation-audit.jsonl")
    }

    /// The isolated socket has to be bindable, not merely short in the abstract: nesting inside
    /// a deep synthetic root produced a credential naming a socket that never bound.
    @Test("A listener binds on the isolated socket under a deep synthetic root")
    func listenerBindsUnderADeepSyntheticRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(String(repeating: "nested-directory/", count: 8), isDirectory: true)
        let environment = [SyntheticRunRoot.environmentKey: root.path]

        let socketURL = AutomationSupportDirectory.fileURL(
            named: "automation.sock", bundleIdentifier: bundleID, environment: environment)
        #expect(socketURL.path.utf8.count < AutomationSupportDirectory.maximumSocketPathLength)

        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

        // The bind itself is the assertion: a path over the limit fails here, not in a length check.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8)
        #expect(pathBytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutablePointer(to: &address.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { destination in
                for (index, byte) in pathBytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[pathBytes.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(fd, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bindResult == 0)
        unlink(socketURL.path)
    }
}

/// Opting out has to close every operator door (#1391). A repair pass can mint a second handle
/// while an earlier one is still registered, and the credential file names only the newest.
@MainActor
@Suite("Operator opt-out revocation")
struct AutomationOperatorRevocationTests {
    @Test("Opting out revokes operator handles the credential no longer names")
    func optOutRevokesEveryOperatorHandle() {
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        let stranded = registry.registerOperator(appScopeID: "workspaces.local")
        let current = registry.registerOperator(appScopeID: "workspaces.local")

        #expect(registry.resolve(stranded.handle)?.isOperator == true)
        #expect(registry.resolve(current.handle)?.isOperator == true)

        let revoked = registry.removeAllOperators()

        #expect(revoked == 2)
        #expect(registry.resolve(stranded.handle) == nil)
        #expect(registry.resolve(current.handle) == nil)
    }

    /// Revocation is scoped to operator entries: a tile handle is a different grant and an
    /// operator opt-out must not take a terminal's own handle with it.
    @Test("Revoking operators leaves tile handles alone")
    func tileHandlesSurviveOperatorRevocation() {
        let registry = AutomationHandleRegistry(makeHandle: { UUID().uuidString })
        _ = registry.registerOperator(appScopeID: "workspaces.local")
        let tile = registry.upsert(
            hostSessionID: UUID(),
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: "window",
            appScopeID: "workspaces.local"
        )

        #expect(registry.removeAllOperators() == 1)
        #expect(registry.resolve(tile.handle)?.isOperator == false)
    }
}

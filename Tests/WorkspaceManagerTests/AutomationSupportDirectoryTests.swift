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
        // The bundle-id component is kept, so an isolated tree still reads as this app's.
        #expect(isolated.lastPathComponent == bundleID)
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

/// The republish decision (#1391): the app has to answer it from disk, because its own record of
/// what it published is exactly what goes stale when another copy deletes the file.
@MainActor
@Suite("AutomationOperatorProvisioning republish")
struct AutomationOperatorRepublishTests {
    @Test("A missing credential on an opted-in launch is republished")
    func missingCredentialIsRepublished() {
        #expect(
            AutomationOperatorProvisioning.shouldRepublish(
                optedIn: true, hasSocket: true, credentialExists: false))
    }

    /// The case that kept the plane down: the launch believes it published one, so nothing else
    /// prompts a re-mint. Presence on disk is the only thing that settles it.
    @Test("A credential still on disk is left alone")
    func presentCredentialIsLeftAlone() {
        #expect(
            !AutomationOperatorProvisioning.shouldRepublish(
                optedIn: true, hasSocket: true, credentialExists: true))
    }

    /// Fail closed: not opting in means no credential, so its absence is the intended state and
    /// republishing would defeat the opt-in.
    @Test("An opted-out launch never republishes")
    func optedOutNeverRepublishes() {
        #expect(
            !AutomationOperatorProvisioning.shouldRepublish(
                optedIn: false, hasSocket: true, credentialExists: false))
    }

    /// A credential names the socket a caller should connect to, so there is nothing coherent to
    /// publish before the listener is up.
    @Test("A launch with no listener never republishes")
    func noSocketNeverRepublishes() {
        #expect(
            !AutomationOperatorProvisioning.shouldRepublish(
                optedIn: true, hasSocket: false, credentialExists: false))
    }
}

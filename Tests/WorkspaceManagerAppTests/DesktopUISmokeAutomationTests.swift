import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// Every deadline in this suite is a failure-only ceiling, never a sampling window: each test
/// waits on the event it asserts on and continues the moment that event lands, so a healthy run
/// never spends the number and a loaded runner pays latency instead of a verdict. The controller
/// under test is in-process — no child launches — so `LaunchBudget`'s unit (a spawn-to-answer
/// round trip, and a different test target) does not describe what these waits are waiting for:
/// main-actor scheduling. The ceiling is sized past the worst starvation measured in a full
/// parallel run, where tests whose own work is sub-second took 20s (hosted CI) and 57s (laptop).
@Suite("DesktopUISmokeAutomation")
struct DesktopUISmokeAutomationTests {
    private static let observationCeiling: Duration = .seconds(60)

    @Test("Configuration parses desktop UI smoke environment")
    func configurationParsesEnvironment() {
        let environment = [
            DesktopUISmokeAutomationConfiguration.modeEnvironmentKey: "desktop-ui-smoke",
            DesktopUISmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
            DesktopUISmokeAutomationConfiguration.workspaceNameEnvironmentKey: "ui-smoke-v1",
            DesktopUISmokeAutomationConfiguration.eventsPathEnvironmentKey: "/tmp/events.jsonl",
            DesktopUISmokeAutomationConfiguration.selectDriverEnvironmentKey: "api",
            DesktopUISmokeAutomationConfiguration.createDriverEnvironmentKey: "api",
        ]

        let configuration = DesktopUISmokeAutomationConfiguration.from(environment: environment)

        #expect(configuration?.repoURL.path == "/tmp/repo")
        #expect(configuration?.workspaceName == "ui-smoke-v1")
        #expect(configuration?.eventsURL.path == "/tmp/events.jsonl")
        #expect(configuration?.selectDriver == .api)
        #expect(configuration?.createDriver == .api)
    }

    @Test("Configuration ignores other automation modes")
    func configurationIgnoresOtherModes() {
        let environment = [
            DesktopUISmokeAutomationConfiguration.modeEnvironmentKey: "host-lume-macos-smoke",
            DesktopUISmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
            DesktopUISmokeAutomationConfiguration.workspaceNameEnvironmentKey: "ui-smoke-v1",
            DesktopUISmokeAutomationConfiguration.eventsPathEnvironmentKey: "/tmp/events.jsonl",
        ]

        #expect(DesktopUISmokeAutomationConfiguration.from(environment: environment) == nil)
    }

    @Test("Configuration requires all automation inputs")
    func configurationRequiresAllInputs() {
        let environment = [
            DesktopUISmokeAutomationConfiguration.modeEnvironmentKey: "desktop-ui-smoke",
            DesktopUISmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
        ]

        #expect(DesktopUISmokeAutomationConfiguration.from(environment: environment) == nil)
    }

    @Test("Controller is disabled without automation environment")
    @MainActor
    func controllerDisabledWithoutEnvironment() {
        let controller = DesktopUISmokeAutomationController(environment: [:])
        #expect(!controller.isEnabled)
        #expect(controller.targetRepoURL == nil)
        #expect(!controller.shouldStartScenario())
    }

    @Test("Controller starts the scenario exactly once")
    @MainActor
    func scenarioStartsOnce() throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        #expect(controller.isEnabled)
        #expect(controller.shouldStartScenario())
        #expect(!controller.shouldStartScenario())
    }

    @Test("Surface focus wait resolves when focus count advances")
    @MainActor
    func surfaceFocusWaitResolvesOnFocus() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        let baseline = controller.surfaceFocusCount
        // The focus below is what ends this wait; the timeout only decides how long a broken
        // signal takes to report, so it is sized to be unreachable rather than tuned.
        let waiter = Task { @MainActor in
            await controller.waitForSurfaceFocus(after: baseline, timeout: Self.observationCeiling)
        }

        await controller.noteSurfaceFocused(sessionID: UUID())
        let focused = await waiter.value
        #expect(focused)
        #expect(controller.surfaceFocusCount == baseline + 1)
    }

    @Test("Surface focus wait reports timeout without focus")
    @MainActor
    func surfaceFocusWaitTimesOut() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        // Short on purpose, and the one place a number is the property: the wait is supposed to
        // expire, and nothing in this test can ever end it early. Load delays the expiry; it
        // cannot turn it into a focus.
        let focused = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: .milliseconds(150)
        )
        #expect(!focused)

        // The timeout milestone is emitted inside the awaited call above, so it is already on
        // disk — no settling, no polling.
        let events = try Self.readEventTypes(at: eventsURL)
        #expect(events.contains("surface_focus_timed_out"))
    }

    @Test("Surface focus wait is skipped when activation is suppressed")
    @MainActor
    func surfaceFocusWaitSkippedWithoutActivation() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(
                eventsURL: eventsURL,
                extra: ["WORKSPACES_NO_ACTIVATE_ON_LAUNCH": "1"]
            )
        )

        // Neither wait consults its timeout: suppressed activation makes focus impossible, so the
        // call returns on the not-applicable path. Passing the same unreachable ceiling as
        // everywhere else keeps that visible — were the short-circuit to regress, these would run
        // long and `surface_focus_timed_out` below would name the regression.
        let firstWait = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: Self.observationCeiling
        )
        let secondWait = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: Self.observationCeiling
        )
        #expect(!firstWait)
        #expect(!secondWait)

        let events = try Self.readEventTypes(at: eventsURL)
        #expect(events.filter { $0 == "surface_focus_not_applicable" }.count == 1)
        #expect(!events.contains("surface_focus_timed_out"))
    }

    @Test("API select handoff completes scenario without focus when activation is suppressed")
    @MainActor
    func apiSelectHandoffCompletesWithoutActivation() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(
                eventsURL: eventsURL,
                extra: [
                    DesktopUISmokeAutomationConfiguration.selectDriverEnvironmentKey: "api",
                    "WORKSPACES_NO_ACTIVATE_ON_LAUNCH": "1",
                ]
            )
        )
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "ui-smoke-v1",
            path: URL(fileURLWithPath: "/tmp/repo-workspace"),
            sourceRepo: repo
        )

        await controller.noteAwaitingAPISelect(workspace: workspace)
        await controller.noteTerminalSessionAttached(
            kind: .workspace,
            sessionID: UUID(),
            scopePath: "/tmp/repo-workspace"
        )

        // `scenario_complete` comes from the completion task, which needs main-actor turns the
        // test cannot schedule for it. Wait for that event rather than for a duration: five
        // seconds was long enough on an idle machine and not on a loaded runner, which is how
        // this assertion failed twice on main (#1281).
        let events = try await Self.awaitEventTypes(at: eventsURL, containing: "scenario_complete")

        #expect(events.contains("surface_focus_not_applicable"))
        #expect(!events.contains("surface_focused"))
        #expect(events.last == "scenario_complete")
    }

    @Test("Terminal attach wait resolves when an attach lands and times out without one")
    @MainActor
    func terminalAttachWaitResolvesOnAttach() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        let baseline = controller.terminalAttachCount
        // Ended by the attach below, not by the clock — unreachable ceiling for the same reason
        // as the focus wait above.
        let waiter = Task { @MainActor in
            await controller.waitForTerminalAttach(after: baseline, timeout: Self.observationCeiling)
        }
        await controller.noteTerminalSessionAttached(
            kind: .workspace,
            sessionID: UUID(),
            scopePath: "/tmp/workspace"
        )
        #expect(await waiter.value)

        // The other half of the pair, where expiring is the property: no attach follows, so this
        // wait can only end one way and load can only postpone it.
        let timedOut = await controller.waitForTerminalAttach(
            after: controller.terminalAttachCount,
            timeout: .milliseconds(150)
        )
        #expect(!timedOut)
    }

    @Test("Terminal attach milestone records the selection kind and session")
    @MainActor
    func terminalAttachRecordsSelectionKind() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        let sessionID = UUID()
        await controller.noteTerminalSessionAttached(
            kind: .workspace,
            sessionID: sessionID,
            scopePath: "/tmp/workspace"
        )

        let events = try Self.readEvents(at: eventsURL)
        let attach = try #require(events.first { $0["type"] as? String == "terminal_session_attached" })
        #expect(attach["selectionKind"] as? String == "workspace")
        #expect(attach["sessionID"] as? String == sessionID.uuidString)
        #expect(attach["sessionScope"] as? String == "/tmp/workspace")
    }

    @Test("Launch ready is emitted once")
    @MainActor
    func launchReadyEmittedOnce() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(eventsURL: eventsURL)
        )

        await controller.noteLaunchReady()
        await controller.noteLaunchReady()

        let events = try Self.readEventTypes(at: eventsURL)
        #expect(events.filter { $0 == "launch_ready" }.count == 1)
    }

    @Test("API select handoff completes scenario after selected workspace focuses")
    @MainActor
    func apiSelectHandoffCompletesScenarioAfterFocus() async throws {
        let eventsURL = Self.temporaryEventsURL()
        defer { try? FileManager.default.removeItem(at: eventsURL) }

        let controller = DesktopUISmokeAutomationController(
            environment: Self.environment(
                eventsURL: eventsURL,
                extra: [DesktopUISmokeAutomationConfiguration.selectDriverEnvironmentKey: "api"]
            )
        )
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "ui-smoke-v1",
            path: URL(fileURLWithPath: "/tmp/repo-workspace"),
            sourceRepo: repo
        )

        await controller.noteAwaitingAPISelect(workspace: workspace)
        let sessionID = UUID()
        await controller.noteTerminalSessionAttached(
            kind: .workspace,
            sessionID: sessionID,
            scopePath: "/tmp/repo-workspace"
        )
        await controller.noteSurfaceFocused(sessionID: sessionID)

        // Same detached completion task as the suppressed-activation case, reached by a real focus
        // instead of the not-applicable path.
        let events = try await Self.awaitEventTypes(at: eventsURL, containing: "scenario_complete")
        #expect(events.contains("awaiting_api_select"))
        #expect(events.contains("terminal_session_attached"))
        #expect(events.contains("surface_focused"))
        #expect(events.last == "scenario_complete")
    }

    private static func environment(eventsURL: URL, extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            DesktopUISmokeAutomationConfiguration.modeEnvironmentKey: "desktop-ui-smoke",
            DesktopUISmokeAutomationConfiguration.repoPathEnvironmentKey: "/tmp/repo",
            DesktopUISmokeAutomationConfiguration.workspaceNameEnvironmentKey: "ui-smoke-v1",
            DesktopUISmokeAutomationConfiguration.eventsPathEnvironmentKey: eventsURL.path,
        ]
        environment.merge(extra) { _, new in new }
        return environment
    }

    private static func temporaryEventsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-ui-smoke-\(UUID().uuidString).jsonl")
    }

    /// Reads what is already on disk. Every milestone these tests assert on is emitted inside an
    /// awaited `note…` call, and the writer actor finishes the write before that call returns, so
    /// there is nothing to settle for: the events are there or the code is wrong.
    private static func readEvents(at url: URL) throws -> [[String: Any]] {
        try parseEvents(at: url)
    }

    /// Waits for a milestone that a detached task emits, suspending between reads. Blocking here
    /// would be self-defeating rather than merely slow: these tests run on the main actor, and the
    /// task that emits `scenario_complete` needs that actor to run at all — a blocking wait holds
    /// the thing it is waiting for. Returns as soon as the event lands; `ceiling` only bounds how
    /// long a genuinely missing event takes to report.
    private static func awaitEvents(
        at url: URL,
        containing eventType: String,
        ceiling: Duration = observationCeiling
    ) async throws -> [[String: Any]] {
        let deadline = ContinuousClock.now.advanced(by: ceiling)
        while ContinuousClock.now < deadline {
            let events = try parseEvents(at: url)
            if events.contains(where: { $0["type"] as? String == eventType }) { return events }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return try parseEvents(at: url)
    }

    private static func parseEvents(at url: URL) throws -> [[String: Any]] {
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return
            contents
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }

    private static func readEventTypes(at url: URL) throws -> [String] {
        try readEvents(at: url).compactMap { $0["type"] as? String }
    }

    private static func awaitEventTypes(
        at url: URL,
        containing eventType: String,
        ceiling: Duration = observationCeiling
    ) async throws -> [String] {
        try await awaitEvents(at: url, containing: eventType, ceiling: ceiling)
            .compactMap { $0["type"] as? String }
    }
}

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("DesktopUISmokeAutomation")
struct DesktopUISmokeAutomationTests {
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
        let waiter = Task { @MainActor in
            await controller.waitForSurfaceFocus(after: baseline, timeout: .seconds(5))
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

        let focused = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: .milliseconds(150)
        )
        #expect(!focused)

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

        let firstWait = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: .seconds(15)
        )
        let secondWait = await controller.waitForSurfaceFocus(
            after: controller.surfaceFocusCount,
            timeout: .seconds(15)
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

        // The completion task runs on the main actor; suspend (not block) while
        // waiting so it can be scheduled.
        var events: [String] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            events = try Self.readEventTypes(at: eventsURL)
            if events.contains("scenario_complete") { break }
            try await Task.sleep(for: .milliseconds(20))
        }

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
        let waiter = Task { @MainActor in
            await controller.waitForTerminalAttach(after: baseline, timeout: .seconds(5))
        }
        await controller.noteTerminalSessionAttached(
            kind: .workspace,
            sessionID: UUID(),
            scopePath: "/tmp/workspace"
        )
        #expect(await waiter.value)

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

        let events = try Self.readEventTypes(at: eventsURL, waitingFor: "scenario_complete")
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

    private static func readEvents(at url: URL, waitingFor eventType: String? = nil) throws -> [[String: Any]] {
        // Events are written by a background actor; allow a brief settle.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let events = try? parseEvents(at: url), !events.isEmpty {
                if let eventType, !events.contains(where: { $0["type"] as? String == eventType }) {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
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

    private static func readEventTypes(at url: URL, waitingFor eventType: String? = nil) throws -> [String] {
        try readEvents(at: url, waitingFor: eventType).compactMap { $0["type"] as? String }
    }
}

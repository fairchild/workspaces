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

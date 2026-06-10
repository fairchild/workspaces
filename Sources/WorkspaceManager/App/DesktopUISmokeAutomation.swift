//
//  DesktopUISmokeAutomation.swift
//  WorkspaceManager
//
//  Dev-only automation that drives the daily-driver desktop UI flows — create a
//  local workspace through the UI, confirm it lands in the sidebar with a live
//  terminal, then switch selection away and back to prove the terminal surface
//  follows selection. Milestones stream to a JSONL file so a host smoke script
//  can assert the sequence without XCUITest.
//

import Foundation
import WorkspaceManagerCore

struct DesktopUISmokeAutomationConfiguration: Equatable, Sendable {
    static let modeEnvironmentKey = "WORKSPACES_AUTOMATION_MODE"
    static let repoPathEnvironmentKey = "WORKSPACES_AUTOMATION_REPO_PATH"
    static let workspaceNameEnvironmentKey = "WORKSPACES_AUTOMATION_WORKSPACE_NAME"
    static let eventsPathEnvironmentKey = "WORKSPACES_AUTOMATION_EVENTS_PATH"
    static let modeValue = "desktop-ui-smoke"

    let repoURL: URL
    let workspaceName: String
    let eventsURL: URL

    static func from(environment: [String: String]) -> DesktopUISmokeAutomationConfiguration? {
        guard
            environment[modeEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines) == modeValue
        else {
            return nil
        }

        guard
            let repoPath = environment[repoPathEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !repoPath.isEmpty,
            let workspaceName = environment[workspaceNameEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !workspaceName.isEmpty,
            let eventsPath = environment[eventsPathEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !eventsPath.isEmpty
        else {
            return nil
        }

        return DesktopUISmokeAutomationConfiguration(
            repoURL: URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath),
            workspaceName: workspaceName,
            eventsURL: URL(fileURLWithPath: (eventsPath as NSString).expandingTildeInPath)
        )
    }
}

/// The selection that a host terminal session is attached to. Lets the smoke
/// script prove the surface follows selection across a workspace → repo →
/// workspace switch.
enum DesktopUISmokeSelectionKind: String, Codable, Sendable {
    case workspace
    case repo
}

private struct DesktopUISmokeEvent: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case launchReady = "launch_ready"
        case repoReady = "repo_ready"
        case workspaceCreationStarted = "workspace_creation_started"
        case workspaceCreated = "workspace_created"
        case sidebarUpdated = "sidebar_updated"
        case terminalSessionAttached = "terminal_session_attached"
        case surfaceFocused = "surface_focused"
        case surfaceFocusTimedOut = "surface_focus_timed_out"
        case scenarioComplete = "scenario_complete"
        case failure
    }

    let type: Kind
    let timestamp: String
    let repoName: String?
    let repoPath: String?
    let workspaceName: String?
    let workspacePath: String?
    let workspaceID: String?
    let selectionKind: DesktopUISmokeSelectionKind?
    let sessionID: String?
    let sessionScope: String?
    let sidebarWorkspaceCount: Int?
    let message: String?
}

actor DesktopUISmokeEventWriter {
    private let eventsURL: URL
    private let encoder = JSONEncoder()
    private let fileManager = FileManager.default

    init(eventsURL: URL) {
        self.eventsURL = eventsURL
        encoder.outputFormatting = [.sortedKeys]

        let directoryURL = eventsURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: eventsURL.path) {
            try? fileManager.removeItem(at: eventsURL)
        }
        _ = fileManager.createFile(atPath: eventsURL.path, contents: Data())
    }

    fileprivate func emit(_ event: DesktopUISmokeEvent) async {
        guard
            let encoded = try? encoder.encode(event),
            let handle = try? FileHandle(forWritingTo: eventsURL)
        else {
            return
        }

        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            NSLog("[DesktopUISmokeAutomation] Failed to write event: %@", error.localizedDescription)
        }
    }
}

@MainActor
final class DesktopUISmokeAutomationController: ObservableObject {
    let configuration: DesktopUISmokeAutomationConfiguration?

    private let writer: DesktopUISmokeEventWriter?
    private var emittedLaunchReady = false
    private var emittedRepoPath: String?
    private var hasStartedScenario = false
    private var lastFailureSignature: String?

    /// Monotonic counter bumped each time a terminal surface reports focus.
    /// The scenario captures it before a selection action and waits for it to
    /// advance, so it never races a focus callback that already fired.
    @Published private(set) var surfaceFocusCount = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let configuration = DesktopUISmokeAutomationConfiguration.from(environment: environment)
        self.configuration = configuration
        self.writer = configuration.map { DesktopUISmokeEventWriter(eventsURL: $0.eventsURL) }
    }

    var isEnabled: Bool {
        configuration != nil && writer != nil
    }

    var targetRepoURL: URL? {
        configuration?.repoURL
    }

    var targetWorkspaceName: String? {
        configuration?.workspaceName
    }

    func matchingRepo(in repos: [Repo], normalizePath: (URL) -> String) -> Repo? {
        guard let targetRepoURL else { return nil }
        let targetPath = normalizePath(targetRepoURL)
        return repos.first(where: { normalizePath($0.localURL) == targetPath })
    }

    func shouldStartScenario() -> Bool {
        guard isEnabled, !hasStartedScenario else { return false }
        hasStartedScenario = true
        return true
    }

    func noteLaunchReady() async {
        guard isEnabled, !emittedLaunchReady else { return }
        emittedLaunchReady = true
        await emit(makeEvent(type: .launchReady))
    }

    func noteRepoReady(_ repo: Repo) async {
        guard isEnabled else { return }
        let normalizedPath = repo.localURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard emittedRepoPath != normalizedPath else { return }
        emittedRepoPath = normalizedPath
        await emit(makeEvent(type: .repoReady, repoName: repo.name, repoPath: normalizedPath))
    }

    func noteWorkspaceCreationStarted(repo: Repo) async {
        guard isEnabled else { return }
        await emit(
            makeEvent(
                type: .workspaceCreationStarted,
                repoName: repo.name,
                repoPath: repo.localURL.standardizedFileURL.resolvingSymlinksInPath().path
            )
        )
    }

    func noteWorkspaceCreated(_ workspace: Workspace) async {
        guard isEnabled else { return }
        await emit(
            makeEvent(
                type: .workspaceCreated,
                repoName: workspace.sourceRepo?.name,
                workspaceName: workspace.name,
                workspacePath: workspace.path,
                workspaceID: workspace.id.uuidString
            )
        )
    }

    func noteSidebarUpdated(workspace: Workspace, sidebarWorkspaceCount: Int) async {
        guard isEnabled else { return }
        await emit(
            makeEvent(
                type: .sidebarUpdated,
                repoName: workspace.sourceRepo?.name,
                workspaceName: workspace.name,
                workspacePath: workspace.path,
                workspaceID: workspace.id.uuidString,
                sidebarWorkspaceCount: sidebarWorkspaceCount
            )
        )
    }

    func noteTerminalSessionAttached(
        kind: DesktopUISmokeSelectionKind,
        sessionID: UUID,
        scopePath: String
    ) async {
        guard isEnabled else { return }
        await emit(
            makeEvent(
                type: .terminalSessionAttached,
                selectionKind: kind,
                sessionID: sessionID.uuidString,
                sessionScope: scopePath
            )
        )
    }

    func noteSurfaceFocused(sessionID: UUID) async {
        guard isEnabled else { return }
        surfaceFocusCount += 1
        await emit(makeEvent(type: .surfaceFocused, sessionID: sessionID.uuidString))
    }

    func noteScenarioComplete() async {
        guard isEnabled else { return }
        await emit(makeEvent(type: .scenarioComplete))
    }

    func noteFailure(message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty, trimmed != lastFailureSignature else { return }
        lastFailureSignature = trimmed
        await emit(makeEvent(type: .failure, message: trimmed))
    }

    /// Suspend until a surface focus fires after `baseline`, or `timeout`
    /// elapses. Returns true on focus, false on timeout (emitting a non-fatal
    /// timeout milestone so the scheduled lane stays honest in headless runs
    /// where focus can lag behind attach).
    func waitForSurfaceFocus(after baseline: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while surfaceFocusCount <= baseline {
            if ContinuousClock.now >= deadline {
                await emit(makeEvent(type: .surfaceFocusTimedOut))
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func emit(_ event: DesktopUISmokeEvent) async {
        guard let writer else { return }
        await writer.emit(event)
    }

    private func makeEvent(
        type: DesktopUISmokeEvent.Kind,
        repoName: String? = nil,
        repoPath: String? = nil,
        workspaceName: String? = nil,
        workspacePath: String? = nil,
        workspaceID: String? = nil,
        selectionKind: DesktopUISmokeSelectionKind? = nil,
        sessionID: String? = nil,
        sessionScope: String? = nil,
        sidebarWorkspaceCount: Int? = nil,
        message: String? = nil
    ) -> DesktopUISmokeEvent {
        DesktopUISmokeEvent(
            type: type,
            timestamp: Date().ISO8601Format(),
            repoName: repoName,
            repoPath: repoPath ?? targetRepoURL?.path,
            workspaceName: workspaceName ?? targetWorkspaceName,
            workspacePath: workspacePath,
            workspaceID: workspaceID,
            selectionKind: selectionKind,
            sessionID: sessionID,
            sessionScope: sessionScope,
            sidebarWorkspaceCount: sidebarWorkspaceCount,
            message: message
        )
    }
}

//
//  PerformanceSignposts.swift
//  WorkspaceManager
//
//  Production signposts and lightweight log metrics for launch/switching latency.
//

import Foundation
import OSLog
import WorkspaceManagerCore

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "PerformanceSignposts")

enum PerformanceSignposts {
    #if DEBUG
        typealias NewWorkspaceSheetMetricObserver = (_ phase: String, _ fields: [String: String]) -> Void
        typealias OpenInEditorMetricObserver = (_ phase: String, _ fields: [String: String]) -> Void
        typealias WorkspaceClickMetricObserver = (_ phase: String, _ fields: [String: String]) -> Void
    #endif

    private struct ActiveInterval {
        let state: OSSignpostIntervalState
        let startedAt: ContinuousClock.Instant
    }

    private struct ActiveNewWorkspaceSheetInterval {
        let attemptID: UUID
        let trigger: String
        let state: OSSignpostIntervalState
        let startedAt: ContinuousClock.Instant
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "WorkspaceManager",
        category: "Performance"
    )
    private static let signposter = OSSignposter(logger: logger)
    private static let clock = ContinuousClock()
    private static let lock = NSLock()

    nonisolated(unsafe) private static var launchInterval: ActiveInterval?
    nonisolated(unsafe) private static var launchCompleted = false
    nonisolated(unsafe) private static var repoHydrationInterval: ActiveInterval?
    nonisolated(unsafe) private static var repoClickIntervals: [UUID: ActiveInterval] = [:]
    nonisolated(unsafe) private static var webViewInitializationInterval: ActiveInterval?
    nonisolated(unsafe) private static var webFirstLoadInterval: ActiveInterval?
    nonisolated(unsafe) private static var webFirstLoadSourceID: UUID?
    nonisolated(unsafe) private static var newWorkspaceSheetInterval: ActiveNewWorkspaceSheetInterval?
    nonisolated(unsafe) private static var openInEditorIntervals: [UUID: ActiveInterval] = [:]
    nonisolated(unsafe) private static var workspaceClickIntervals: [UUID: ActiveInterval] = [:]
    #if DEBUG
        nonisolated(unsafe) private static var newWorkspaceSheetMetricObserver: NewWorkspaceSheetMetricObserver?
        nonisolated(unsafe) private static var openInEditorMetricObserver: OpenInEditorMetricObserver?
        nonisolated(unsafe) private static var workspaceClickMetricObserver: WorkspaceClickMetricObserver?
    #endif

    nonisolated(unsafe) private static var mainWindowBodyEvaluations: UInt64 = 0

    /// Counts `ContentView.body` evaluations (#1347 B4). An event signpost per
    /// evaluation for Instruments, plus a periodic log line so the count is
    /// greppable during replay runs: zero growth per agent event is the
    /// acceptance criterion the A-series established.
    static func noteMainWindowBodyEvaluation() {
        lock.lock()
        mainWindowBodyEvaluations += 1
        let count = mainWindowBodyEvaluations
        lock.unlock()

        signposter.emitEvent("MainWindowBodyEvaluation")
        if count == 1 || count.isMultiple(of: 50) {
            log.info("[Perf] event=main_window_body_evaluations count=\(count, privacy: .public)")
        }
    }

    static func beginLaunchToFirstPromptIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard !launchCompleted else { return }
        guard launchInterval == nil else { return }

        let state = signposter.beginInterval("LaunchToFirstPrompt")
        launchInterval = ActiveInterval(state: state, startedAt: clock.now)
    }

    static func endLaunchToFirstPromptIfNeeded(trigger: String) {
        let interval: ActiveInterval?

        lock.lock()
        if launchCompleted {
            interval = nil
        } else {
            interval = launchInterval
            launchInterval = nil
            launchCompleted = interval != nil
        }
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("LaunchToFirstPrompt", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=launch_to_first_prompt duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) trigger=\(trigger, privacy: .public)"
        )
        recordDiagnostic(metric: "launch_to_first_prompt", durationMs: durationMs, labels: ["trigger": trigger])
    }

    /// Records how the first terminal session came to exist on this launch.
    ///
    /// `launch_to_first_prompt` closes when the first shell reaches a prompt, so the amount of
    /// work standing between launch and that prompt depends on which path seeded the session
    /// (`caller`) and what it seeded (`branch`: a manifest restore of N sessions, a fresh
    /// default-home shell, or a no-op because the other path already ran). Both vary per launch,
    /// and #1251's residual is a bimodal distribution — so each sample carries its own mode here
    /// instead of the mode being argued from the shape of the distribution afterwards.
    ///
    /// Deliberately `event=`, not `metric=`: this is a label for the sample, not a latency
    /// sample, and the duration parsers key on `metric=… duration_ms=…`.
    static func noteInitialHostSessionBootstrap(
        caller: String,
        branch: String,
        sessionCount: Int
    ) {
        log.info(
            "[Perf] event=initial_host_session caller=\(caller, privacy: .public) branch=\(branch, privacy: .public) sessions=\(sessionCount, privacy: .public)"
        )
    }

    static func beginRepoHydration(rootPath: String) {
        lock.lock()
        defer { lock.unlock() }

        guard repoHydrationInterval == nil else { return }

        let state = signposter.beginInterval("RepoHydration")
        repoHydrationInterval = ActiveInterval(state: state, startedAt: clock.now)
        log.info("[Perf] metric=repo_hydration status=started root=\(rootPath, privacy: .public)")
    }

    static func endRepoHydrationIfNeeded(discoveredCount: Int, importedCount: Int) {
        let interval: ActiveInterval?

        lock.lock()
        interval = repoHydrationInterval
        repoHydrationInterval = nil
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("RepoHydration", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=repo_hydration duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) discovered=\(discoveredCount, privacy: .public) imported=\(importedCount, privacy: .public)"
        )
        recordDiagnostic(
            metric: "repo_hydration",
            durationMs: durationMs,
            labels: ["discovered": "\(discoveredCount)", "imported": "\(importedCount)"]
        )
    }

    static func beginRepoClickToFocusedInput(sessionID: UUID, repoPath: String) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = repoClickIntervals.removeValue(forKey: sessionID) {
            signposter.endInterval("RepoClickToFocusedInput", existing.state)
            let elapsedMs = milliseconds(since: existing.startedAt)
            log.info(
                "[Perf] metric=repo_click_to_focus status=abandoned elapsed_ms=\(String(format: "%.2f", elapsedMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=superseded"
            )
        }

        let state = signposter.beginInterval("RepoClickToFocusedInput")
        repoClickIntervals[sessionID] = ActiveInterval(state: state, startedAt: clock.now)
        log.info(
            "[Perf] metric=repo_click_to_focus status=started session=\(sessionID.uuidString, privacy: .public) path=\(repoPath, privacy: .public)"
        )
    }

    static func endRepoClickToFocusedInputIfNeeded(sessionID: UUID, outcome: String) {
        let interval: ActiveInterval?

        lock.lock()
        interval = repoClickIntervals.removeValue(forKey: sessionID)
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("RepoClickToFocusedInput", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=repo_click_to_focus duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
    }

    /// Ends an interval whose latency was never observed (user navigated away,
    /// selection superseded, surface invalidated). Emits `status=abandoned` with
    /// `elapsed_ms` — not `duration_ms` — so duration parsers cannot mistake the
    /// idle wall time for a measured latency sample.
    static func cancelRepoClickToFocusedInputIfNeeded(sessionID: UUID, reason: String) {
        let interval: ActiveInterval?

        lock.lock()
        interval = repoClickIntervals.removeValue(forKey: sessionID)
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("RepoClickToFocusedInput", interval.state)
        let elapsedMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=repo_click_to_focus status=abandoned elapsed_ms=\(String(format: "%.2f", elapsedMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=\(reason, privacy: .public)"
        )
    }

    static func beginWorkspaceClickToFocusedInput(sessionID: UUID, workspacePath: String) {
        var supersededFields: [String: String]?
        var supersededElapsedMs: Double = 0
        let startedFields: [String: String]

        lock.lock()
        if let existing = workspaceClickIntervals.removeValue(forKey: sessionID) {
            signposter.endInterval("WorkspaceClickToFocusedInput", existing.state)
            supersededElapsedMs = milliseconds(since: existing.startedAt)
            supersededFields = [
                "metric": "workspace_click_to_focus",
                "status": "abandoned",
                "session": sessionID.uuidString,
                "outcome": "superseded",
                "elapsed_ms": String(format: "%.2f", supersededElapsedMs),
            ]
        }
        let state = signposter.beginInterval("WorkspaceClickToFocusedInput")
        workspaceClickIntervals[sessionID] = ActiveInterval(state: state, startedAt: clock.now)
        startedFields = [
            "metric": "workspace_click_to_focus",
            "status": "started",
            "session": sessionID.uuidString,
            "path": workspacePath,
        ]
        lock.unlock()

        if let supersededFields {
            log.info(
                "[Perf] metric=workspace_click_to_focus status=abandoned elapsed_ms=\(String(format: "%.2f", supersededElapsedMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=superseded"
            )
            emitWorkspaceClickMetricEvent(phase: "abandoned", fields: supersededFields)
        }

        log.info(
            "[Perf] metric=workspace_click_to_focus status=started session=\(sessionID.uuidString, privacy: .public) path=\(workspacePath, privacy: .public)"
        )
        emitWorkspaceClickMetricEvent(phase: "started", fields: startedFields)
    }

    static func endWorkspaceClickToFocusedInputIfNeeded(sessionID: UUID, outcome: String) {
        let interval: ActiveInterval?

        lock.lock()
        interval = workspaceClickIntervals.removeValue(forKey: sessionID)
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("WorkspaceClickToFocusedInput", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        let fields = [
            "metric": "workspace_click_to_focus",
            "status": "completed",
            "session": sessionID.uuidString,
            "outcome": outcome,
            "duration_ms": String(format: "%.2f", durationMs),
        ]
        log.info(
            "[Perf] metric=workspace_click_to_focus duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
        emitWorkspaceClickMetricEvent(phase: "completed", fields: fields)
    }

    /// Ends an interval whose latency was never observed (user navigated away,
    /// selection superseded, surface invalidated). Emits `status=abandoned` with
    /// `elapsed_ms` — not `duration_ms` — so duration parsers cannot mistake the
    /// idle wall time for a measured latency sample.
    static func cancelWorkspaceClickToFocusedInputIfNeeded(sessionID: UUID, reason: String) {
        let interval: ActiveInterval?

        lock.lock()
        interval = workspaceClickIntervals.removeValue(forKey: sessionID)
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("WorkspaceClickToFocusedInput", interval.state)
        let elapsedMs = milliseconds(since: interval.startedAt)
        let fields = [
            "metric": "workspace_click_to_focus",
            "status": "abandoned",
            "session": sessionID.uuidString,
            "outcome": reason,
            "elapsed_ms": String(format: "%.2f", elapsedMs),
        ]
        log.info(
            "[Perf] metric=workspace_click_to_focus status=abandoned elapsed_ms=\(String(format: "%.2f", elapsedMs), privacy: .public) session=\(sessionID.uuidString, privacy: .public) outcome=\(reason, privacy: .public)"
        )
        emitWorkspaceClickMetricEvent(phase: "abandoned", fields: fields)
    }

    static func beginWebViewInitializationIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard webViewInitializationInterval == nil else { return }
        let state = signposter.beginInterval("WebViewInitialization")
        webViewInitializationInterval = ActiveInterval(state: state, startedAt: clock.now)
    }

    static func endWebViewInitializationIfNeeded(outcome: String) {
        let interval: ActiveInterval?

        lock.lock()
        interval = webViewInitializationInterval
        webViewInitializationInterval = nil
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("WebViewInitialization", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=webview_initialization duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) outcome=\(outcome, privacy: .public)"
        )
    }

    static func beginWebFirstLoadIfNeeded(sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = webFirstLoadInterval {
            signposter.endInterval("WebFirstLoad", existing.state)
            let durationMs = milliseconds(since: existing.startedAt)
            log.info(
                "[Perf] metric=web_first_load duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) source=\(webFirstLoadSourceID?.uuidString ?? "unknown", privacy: .public) outcome=superseded"
            )
        }

        let state = signposter.beginInterval("WebFirstLoad")
        webFirstLoadInterval = ActiveInterval(state: state, startedAt: clock.now)
        webFirstLoadSourceID = sourceID
    }

    static func endWebFirstLoadIfNeeded(outcome: String) {
        let interval: ActiveInterval?
        let sourceID: UUID?

        lock.lock()
        interval = webFirstLoadInterval
        sourceID = webFirstLoadSourceID
        webFirstLoadInterval = nil
        webFirstLoadSourceID = nil
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("WebFirstLoad", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        log.info(
            "[Perf] metric=web_first_load duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) source=\(sourceID?.uuidString ?? "unknown", privacy: .public) outcome=\(outcome, privacy: .public)"
        )
    }

    @discardableResult
    static func beginNewWorkspaceSheetReady(trigger: String) -> UUID {
        let attemptID = UUID()
        var supersededInterval: ActiveNewWorkspaceSheetInterval?

        lock.lock()
        supersededInterval = newWorkspaceSheetInterval
        if let supersededInterval {
            signposter.endInterval("NewWorkspaceSheetReady", supersededInterval.state)
        }

        let state = signposter.beginInterval("NewWorkspaceSheetReady")
        newWorkspaceSheetInterval = ActiveNewWorkspaceSheetInterval(
            attemptID: attemptID,
            trigger: trigger,
            state: state,
            startedAt: clock.now
        )
        lock.unlock()

        if let supersededInterval {
            let durationMs = milliseconds(since: supersededInterval.startedAt)
            let fields = [
                "metric": "new_workspace_sheet_ready",
                "status": "completed",
                "attempt": supersededInterval.attemptID.uuidString,
                "trigger": supersededInterval.trigger,
                "outcome": "superseded",
                "duration_ms": String(format: "%.2f", durationMs),
            ]
            log.info(
                "[Perf] metric=new_workspace_sheet_ready duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) attempt=\(supersededInterval.attemptID.uuidString, privacy: .public) trigger=\(supersededInterval.trigger, privacy: .public) outcome=superseded"
            )
            emitNewWorkspaceSheetMetricEvent(phase: "completed", fields: fields)
        }

        let fields = [
            "metric": "new_workspace_sheet_ready",
            "status": "started",
            "attempt": attemptID.uuidString,
            "trigger": trigger,
        ]
        log.info(
            "[Perf] metric=new_workspace_sheet_ready status=started attempt=\(attemptID.uuidString, privacy: .public) trigger=\(trigger, privacy: .public)"
        )
        emitNewWorkspaceSheetMetricEvent(phase: "started", fields: fields)

        return attemptID
    }

    static func endNewWorkspaceSheetReadyIfNeeded(attemptID: UUID, outcome: String) {
        let interval: ActiveNewWorkspaceSheetInterval?

        lock.lock()
        if let activeInterval = newWorkspaceSheetInterval, activeInterval.attemptID == attemptID {
            interval = activeInterval
            newWorkspaceSheetInterval = nil
        } else {
            interval = nil
        }
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("NewWorkspaceSheetReady", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)
        let fields = [
            "metric": "new_workspace_sheet_ready",
            "status": "completed",
            "attempt": interval.attemptID.uuidString,
            "trigger": interval.trigger,
            "outcome": outcome,
            "duration_ms": String(format: "%.2f", durationMs),
        ]
        log.info(
            "[Perf] metric=new_workspace_sheet_ready duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) attempt=\(interval.attemptID.uuidString, privacy: .public) trigger=\(interval.trigger, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
        emitNewWorkspaceSheetMetricEvent(phase: "completed", fields: fields)
    }

    static func beginOpenInEditorLaunch(
        attemptID: UUID,
        trigger: String,
        editorID: String,
        targetKind: String
    ) {
        lock.lock()

        if let existing = openInEditorIntervals.removeValue(forKey: attemptID) {
            signposter.endInterval("OpenInEditorLaunch", existing.state)
        }

        let state = signposter.beginInterval("OpenInEditorLaunch")
        openInEditorIntervals[attemptID] = ActiveInterval(state: state, startedAt: clock.now)
        lock.unlock()

        let fields = [
            "metric": "open_in_editor_launch",
            "status": "started",
            "attempt": attemptID.uuidString,
            "trigger": trigger,
            "editor": editorID,
            "target": targetKind,
        ]
        log.info(
            "[Perf] metric=open_in_editor_launch status=started attempt=\(attemptID.uuidString, privacy: .public) trigger=\(trigger, privacy: .public) editor=\(editorID, privacy: .public) target=\(targetKind, privacy: .public)"
        )
        emitOpenInEditorMetricEvent(phase: "started", fields: fields)
    }

    static func endOpenInEditorLaunchIfNeeded(
        attemptID: UUID,
        trigger: String,
        editorID: String,
        targetKind: String,
        outcome: String,
        failureReason: String?
    ) {
        let interval: ActiveInterval?

        lock.lock()
        interval = openInEditorIntervals.removeValue(forKey: attemptID)
        lock.unlock()

        guard let interval else { return }

        signposter.endInterval("OpenInEditorLaunch", interval.state)
        let durationMs = milliseconds(since: interval.startedAt)

        var fields = [
            "metric": "open_in_editor_launch",
            "status": "completed",
            "attempt": attemptID.uuidString,
            "trigger": trigger,
            "editor": editorID,
            "target": targetKind,
            "outcome": outcome,
            "duration_ms": String(format: "%.2f", durationMs),
        ]

        if let failureReason {
            fields["failure_reason"] = failureReason
            log.info(
                "[Perf] metric=open_in_editor_launch duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) attempt=\(attemptID.uuidString, privacy: .public) trigger=\(trigger, privacy: .public) editor=\(editorID, privacy: .public) target=\(targetKind, privacy: .public) outcome=\(outcome, privacy: .public) failure_reason=\(failureReason, privacy: .public)"
            )
        } else {
            log.info(
                "[Perf] metric=open_in_editor_launch duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) attempt=\(attemptID.uuidString, privacy: .public) trigger=\(trigger, privacy: .public) editor=\(editorID, privacy: .public) target=\(targetKind, privacy: .public) outcome=\(outcome, privacy: .public)"
            )
        }

        emitOpenInEditorMetricEvent(phase: "completed", fields: fields)
    }

    #if DEBUG
        static func setNewWorkspaceSheetMetricObserver(_ observer: NewWorkspaceSheetMetricObserver?) {
            lock.lock()
            newWorkspaceSheetMetricObserver = observer
            lock.unlock()
        }

        static func setOpenInEditorMetricObserver(_ observer: OpenInEditorMetricObserver?) {
            lock.lock()
            openInEditorMetricObserver = observer
            lock.unlock()
        }

        static func setWorkspaceClickMetricObserver(_ observer: WorkspaceClickMetricObserver?) {
            lock.lock()
            workspaceClickMetricObserver = observer
            lock.unlock()
        }

        static func resetWorkspaceClickMetricsForTesting() {
            lock.lock()
            workspaceClickIntervals.removeAll()
            workspaceClickMetricObserver = nil
            lock.unlock()
        }
    #endif

    private static func emitNewWorkspaceSheetMetricEvent(phase: String, fields: [String: String]) {
        #if DEBUG
            let observer: NewWorkspaceSheetMetricObserver?
            lock.lock()
            observer = newWorkspaceSheetMetricObserver
            lock.unlock()
            observer?(phase, fields)
        #else
            _ = phase
            _ = fields
        #endif
    }

    private static func emitOpenInEditorMetricEvent(phase: String, fields: [String: String]) {
        #if DEBUG
            let observer: OpenInEditorMetricObserver?
            lock.lock()
            observer = openInEditorMetricObserver
            lock.unlock()
            observer?(phase, fields)
        #else
            _ = phase
            _ = fields
        #endif
    }

    private static func emitWorkspaceClickMetricEvent(phase: String, fields: [String: String]) {
        #if DEBUG
            let observer: WorkspaceClickMetricObserver?
            lock.lock()
            observer = workspaceClickMetricObserver
            lock.unlock()
            observer?(phase, fields)
        #else
            _ = phase
            _ = fields
        #endif
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func recordDiagnostic(metric: String, durationMs: Double, labels: [String: String]) {
        Task.detached {
            await StartupDiagnosticsStore.shared.record(
                metric: metric,
                durationMs: durationMs,
                labels: labels
            )
        }
    }
}

//
//  PerformanceSignposts.swift
//  WorkspaceManager
//
//  Production signposts and lightweight log metrics for launch/switching latency.
//

import Foundation
import OSLog

enum PerformanceSignposts {
    private struct ActiveInterval {
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

    private static var launchInterval: ActiveInterval?
    private static var launchCompleted = false
    private static var repoHydrationInterval: ActiveInterval?
    private static var repoClickIntervals: [UUID: ActiveInterval] = [:]

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
        NSLog(
            "[Perf] metric=launch_to_first_prompt duration_ms=%.2f trigger=%@",
            durationMs,
            trigger
        )
    }

    static func beginRepoHydration(rootPath: String) {
        lock.lock()
        defer { lock.unlock() }

        guard repoHydrationInterval == nil else { return }

        let state = signposter.beginInterval("RepoHydration")
        repoHydrationInterval = ActiveInterval(state: state, startedAt: clock.now)
        NSLog("[Perf] metric=repo_hydration status=started root=%@", rootPath)
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
        NSLog(
            "[Perf] metric=repo_hydration duration_ms=%.2f discovered=%ld imported=%ld",
            durationMs,
            discoveredCount,
            importedCount
        )
    }

    static func beginRepoClickToFocusedInput(sessionID: UUID, repoPath: String) {
        lock.lock()
        defer { lock.unlock() }

        if let existing = repoClickIntervals.removeValue(forKey: sessionID) {
            signposter.endInterval("RepoClickToFocusedInput", existing.state)
            let durationMs = milliseconds(since: existing.startedAt)
            NSLog(
                "[Perf] metric=repo_click_to_focus duration_ms=%.2f session=%@ outcome=superseded",
                durationMs,
                sessionID.uuidString
            )
        }

        let state = signposter.beginInterval("RepoClickToFocusedInput")
        repoClickIntervals[sessionID] = ActiveInterval(state: state, startedAt: clock.now)
        NSLog(
            "[Perf] metric=repo_click_to_focus status=started session=%@ path=%@",
            sessionID.uuidString,
            repoPath
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
        NSLog(
            "[Perf] metric=repo_click_to_focus duration_ms=%.2f session=%@ outcome=%@",
            durationMs,
            sessionID.uuidString,
            outcome
        )
    }

    static func cancelRepoClickToFocusedInputIfNeeded(sessionID: UUID, reason: String) {
        endRepoClickToFocusedInputIfNeeded(sessionID: sessionID, outcome: reason)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: clock.now)
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

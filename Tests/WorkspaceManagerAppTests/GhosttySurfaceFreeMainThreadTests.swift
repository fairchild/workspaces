//
//  GhosttySurfaceFreeMainThreadTests.swift
//  WorkspaceManagerAppTests
//
//  Guards the main thread against waiting on a closed terminal's command (#1897).
//  `ghostty_surface_free` runs on the main thread and joins the surface's io thread, which
//  hangs up the command and exits only once the command has. These tests hold the command
//  (the `login` wrapper) stopped, so it cannot exit, and check the order of events around
//  it: the hang-up arrives while the main thread runs on, and the free begins only after
//  the command exits or is killed. A watchdog off the main thread resumes the command if a
//  free blocks the main thread on it.
//

import Darwin
import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

/// Nested in the mailbox-deadlock suite so its `.serialized` keeps the two apart: that suite
/// suspends every free while it fills the mailbox.
extension GhosttySurfaceMailboxDeadlockTests {
    @Suite("GhosttySurface free and the main thread")
    @MainActor
    struct GhosttySurfaceFreeMainThreadTests {
        /// Far below the seconds a free held the main thread while it waited on a command.
        private static let freeHoldBound: Duration = .milliseconds(500)

        @Test(
            "Retiring a surface hangs up its command while the main thread runs on, and frees it once the command exits"
        )
        func retiringAStoppedCommand() async throws {
            let manager = GhosttyAppManager.shared
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("hung-up-\(UUID().uuidString)")
            let script = try Self.hangUpMarkerScript(marker: marker)
            defer {
                try? FileManager.default.removeItem(at: script)
                try? FileManager.default.removeItem(at: marker)
            }
            var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: script.path)
            let surface = try #require(view?.surface, "the view needs a Ghostty surface to free")
            await waitUntil(.seconds(30)) { view?.hasObservedPromptReadySignal == true }
            try #require(view?.hasObservedPromptReadySignal == true, "the script never set its hang-up trap")
            let command = try #require(GhosttySurfaceChildProcess.pid(of: surface), "the surface's command has no pid")

            // Stopped, `login` cannot exit until it is resumed; the script under it still runs.
            try #require(kill(command, SIGSTOP) == 0)
            let grace = manager.hangUpGrace
            manager.hangUpGrace = .seconds(60)
            defer { manager.hangUpGrace = grace }
            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) {
                    (freed.started, freed.held) = (free.started, free.held)
                }
            }
            defer { manager.onSurfaceFreed = nil }
            let observation = HangUpObservation()
            let resumed = Self.resume(command, onceHungUp: marker, observation)
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")

            // Only a main thread free of the free gets here before the command is resumed.
            await waitUntil(.seconds(20)) { observation.hungUpAt != nil }
            let freeBeganBeforeHangUpSeen = freed.started != nil
            let ticks = manager.tickCount
            await waitUntil(.seconds(5)) { manager.tickCount - ticks >= 10 || freed.started != nil }
            let ticksWhileStopped = manager.tickCount - ticks
            let freeBeganWhileStopped = freed.started != nil
            observation.release()
            let resumption = await resumed.value
            await waitUntil(.seconds(20)) { freed.started != nil }

            let hungUpAt = try #require(observation.hungUpAt, "the command was not hung up while it was stopped")
            #expect(resumption.released, "the main thread never got back to release the stopped command")
            #expect(!freeBeganBeforeHangUpSeen, "the free began before the hang-up was seen")
            #expect(ticksWhileStopped >= 10, "the main thread stopped ticking while the command was stopped")
            #expect(!freeBeganWhileStopped, "the free began while the command was still stopped")
            let started = try #require(freed.started, "the retired surface was never freed")
            let held = try #require(freed.held)
            #expect(hungUpAt < started, "the hang-up came from the free itself")
            #expect(resumption.at < started, "the surface was freed before its command could exit")
            #expect(held < Self.freeHoldBound, "the free held the main thread \(held)")
        }

        @Test("A foreground pipeline whose first process has exited still leads back to the surface's command")
        func pipelineWithAnExitedLeader() async throws {
            let manager = GhosttyAppManager.shared
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
            // With job control on, the pipeline is the pty's foreground group and its first
            // process leads it; once that process exits the group id names no process.
            let script = try Self.script(
                """
                #!/bin/bash
                set -m
                echo $$ > "\(pidFile.path)"
                { printf '\\033]2;pipeline\\007' >&2; exec sleep 0.2; } | sleep 120
                """)
            defer {
                try? FileManager.default.removeItem(at: script)
                try? FileManager.default.removeItem(at: pidFile)
            }
            var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: script.path)
            let surface = try #require(view?.surface, "the view needs a Ghostty surface to free")
            await waitUntil(.seconds(30)) { view?.hasObservedPromptReadySignal == true }
            try #require(view?.hasObservedPromptReadySignal == true, "the pipeline never started")
            let recorded = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
            let scriptPID = try #require(
                pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines)), "the script never recorded its pid")
            let command = getsid(scriptPID)
            try #require(command > 0, "the script's session is unreadable")
            var foreground: pid_t { pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface)) }
            await waitUntil(.seconds(30)) { foreground > 0 && foreground != command }
            let pipeline = foreground
            try #require(pipeline > 0 && pipeline != command, "the pipeline never took the foreground")
            await waitUntil(.seconds(30)) { getsid(pipeline) == -1 }
            try #require(getsid(pipeline) == -1 && foreground == pipeline, "the pipeline's first process never exited")

            #expect(GhosttySurfaceChildProcess.pid(of: surface) == command)

            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) { freed.started = free.started }
            }
            defer { manager.onSurfaceFreed = nil }
            let retired = ContinuousClock.now
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")
            await waitUntil(.seconds(60)) { freed.started != nil }
            let started = try #require(freed.started, "the retired surface was never freed")
            #expect(
                started - retired < manager.hangUpGrace,
                "the free waited out the hang-up grace, so the hang-up never reached the command")
        }

        @Test("A command still alive after its grace is killed, and its free never holds the main thread for it")
        func aCommandThatOutlivesItsGrace() async throws {
            let manager = GhosttyAppManager.shared
            let script = try Self.script(
                """
                #!/bin/sh
                trap '' HUP
                printf '\\033]2;ignoring hang-ups\\007'
                while kill -0 "$PPID" 2>/dev/null; do sleep 0.1; done
                """)
            defer { try? FileManager.default.removeItem(at: script) }
            var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: script.path)
            let surface = try #require(view?.surface, "the view needs a Ghostty surface to free")
            await waitUntil(.seconds(30)) { view?.hasObservedPromptReadySignal == true }
            try #require(view?.hasObservedPromptReadySignal == true, "the script never started")
            let command = try #require(GhosttySurfaceChildProcess.pid(of: surface), "the surface's command has no pid")

            // Stopped, `login` holds its hang-up until it is resumed, and the script ignores its own.
            try #require(kill(command, SIGSTOP) == 0)
            let watchdog = Self.watchdog(resuming: command, after: .seconds(40))
            let grace = (hangUp: manager.hangUpGrace, kill: manager.killGrace)
            manager.hangUpGrace = .milliseconds(300)
            manager.killGrace = .seconds(10)
            defer { (manager.hangUpGrace, manager.killGrace) = grace }
            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) {
                    (freed.started, freed.held) = (free.started, free.held)
                }
            }
            defer { manager.onSurfaceFreed = nil }
            let retired = ContinuousClock.now
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")
            await waitUntil(.seconds(30)) { freed.started != nil }
            watchdog.cancel()
            let resumedByWatchdog = await watchdog.value
            if freed.started == nil {
                kill(command, SIGCONT)
                await waitUntil(.seconds(30)) { freed.started != nil }
            }

            #expect(!resumedByWatchdog, "the command stayed stopped until the test's watchdog resumed it")
            let started = try #require(
                freed.started, "the stopped command was never ended, so its surface was never freed")
            let held = try #require(freed.held)
            #expect(
                started - retired >= manager.hangUpGrace,
                "the surface was freed before its command could have been killed")
            #expect(held < Self.freeHoldBound, "the free held the main thread \(held)")
        }

        /// From off the main thread, so a free that blocks it cannot hold the command stopped
        /// for good: records when `marker` appears, waits for the test to release the command,
        /// and resumes it, each wait bounded. Returns when it resumed the command, and whether
        /// the test had released it by then.
        nonisolated private static func resume(
            _ command: pid_t, onceHungUp marker: URL, _ observation: HangUpObservation
        ) -> Task<(at: ContinuousClock.Instant, released: Bool), Never> {
            Task.detached {
                let hungUpBy = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < hungUpBy {
                    if FileManager.default.fileExists(atPath: marker.path) {
                        observation.hungUpAt = ContinuousClock.now
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let releasedBy = ContinuousClock.now + .seconds(30)
                while !observation.isReleased, ContinuousClock.now < releasedBy {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                let resumed = (at: ContinuousClock.now, released: observation.isReleased)
                kill(command, SIGCONT)
                return resumed
            }
        }

        /// Resumes `command` after `timeout` unless cancelled first, from off the main thread, so
        /// a test whose free blocks the main thread on a stopped command still ends. True if it
        /// had to.
        nonisolated private static func watchdog(resuming command: pid_t, after timeout: Duration) -> Task<Bool, Never>
        {
            Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return false }
                kill(command, SIGCONT)
                return true
            }
        }

        /// Runs in the command's process group, so it receives the same hang-up, and leaves
        /// `marker` behind when it does. The title it sets marks the trap as installed.
        private static func hangUpMarkerScript(marker: URL) throws -> URL {
            try script(
                """
                #!/bin/sh
                trap ': > "\(marker.path)"; exit 0' HUP
                printf '\\033]2;trap set\\007'
                while :; do sleep 1; done
                """)
        }

        private static func script(_ body: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("surface-free-\(UUID().uuidString).sh")
            let created = FileManager.default.createFile(
                atPath: url.path, contents: Data((body + "\n").utf8), attributes: [.posixPermissions: 0o755])
            try #require(created, "the script could not be written")
            return url
        }

        private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

@MainActor
private final class FreeRecord {
    var started: ContinuousClock.Instant?
    var held: Duration?
}

/// Written from the test's off-main resumer and read on the main thread.
private final class HangUpObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: ContinuousClock.Instant?
    private var released = false

    var hungUpAt: ContinuousClock.Instant? {
        get { lock.withLock { seen } }
        set { lock.withLock { seen = newValue } }
    }

    var isReleased: Bool { lock.withLock { released } }

    func release() { lock.withLock { released = true } }
}

private struct WeakView {
    weak var view: GhosttySurfaceView?

    init(_ view: GhosttySurfaceView?) {
        self.view = view
    }
}

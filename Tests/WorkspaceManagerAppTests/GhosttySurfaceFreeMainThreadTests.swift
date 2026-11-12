//
//  GhosttySurfaceFreeMainThreadTests.swift
//  WorkspaceManagerAppTests
//
//  Guards the main thread against waiting on a closed terminal's command (#1897).
//  `ghostty_surface_free` runs on the main thread and joins the surface's io thread, which
//  hangs up the command and exits only once the command has. These tests hold the command
//  (the `login` wrapper) stopped or out of sight, and check the order of events around it:
//  the hang-up arrives while the main thread runs on, and the free begins only after the
//  command exits or is killed. A watchdog off the main thread resumes or kills the command
//  if a free blocks the main thread on it.
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

            let found = try #require(GhosttySurfaceChildProcess.command(of: surface))
            try #require(found.pid == command, "the lookup did not lead back to the surface's command")

            // With no kill until the grace runs out, only the hang-up can end the command.
            let grace = manager.hangUpGrace
            manager.hangUpGrace = .seconds(600)
            defer { manager.hangUpGrace = grace }
            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) { freed.started = free.started }
            }
            defer { manager.onSurfaceFreed = nil }
            let exit = Self.watchExit(of: found, for: .seconds(60))
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")
            let watched = await exit.value
            await waitUntil(.seconds(30)) { freed.started != nil }

            #expect(watched.ended, "the hang-up never ended the command")
            let started = try #require(freed.started, "the retired surface was never freed")
            #expect(watched.lastRunningAt < started, "the surface was freed while its command still ran")
        }

        @Test("A command still alive after its grace is killed, and its free never holds the main thread for it")
        func aCommandThatOutlivesItsGrace() async throws {
            let manager = GhosttyAppManager.shared
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("immune-\(UUID().uuidString)")
            // Ignoring hang-ups and running on whether `login` lives or not, the script ends
            // only by SIGKILL.
            let script = try Self.script(
                """
                #!/bin/sh
                trap '' HUP
                echo $$ > "\(pidFile.path)"
                printf '\\033]2;ignoring hang-ups\\007'
                while :; do sleep 0.1; done
                """)
            defer {
                try? FileManager.default.removeItem(at: script)
                try? FileManager.default.removeItem(at: pidFile)
            }
            var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: script.path)
            let surface = try #require(view?.surface, "the view needs a Ghostty surface to free")
            await waitUntil(.seconds(30)) { view?.hasObservedPromptReadySignal == true }
            try #require(view?.hasObservedPromptReadySignal == true, "the script never started")
            let command = try #require(GhosttySurfaceChildProcess.pid(of: surface), "the surface's command has no pid")
            let immune = try Self.recordedPID(in: pidFile)
            defer { kill(immune, SIGKILL) }

            // Stopped, `login` holds its hang-up until it is resumed, and the script ignores its own.
            try #require(kill(command, SIGSTOP) == 0)
            let watchdog = Self.watchdog(sending: SIGCONT, to: [command], after: .seconds(40))
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
            await waitUntil(.seconds(10)) { kill(immune, 0) != 0 }

            #expect(!resumedByWatchdog, "the command stayed stopped until the test's watchdog resumed it")
            #expect(
                kill(immune, 0) != 0, "the script that ignores hang-ups outlived its surface, so it was never killed")
            let started = try #require(
                freed.started, "the stopped command was never ended, so its surface was never freed")
            let held = try #require(freed.held)
            #expect(
                started - retired >= manager.hangUpGrace,
                "the surface was freed before its command could have been killed")
            #expect(held < Self.freeHoldBound, "the free held the main thread \(held)")
        }

        @Test("A stopped command whose foreground group has emptied stays unfreed, and the main thread runs on")
        func aStoppedCommandOutOfSight() async throws {
            let manager = GhosttyAppManager.shared
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("unseen-\(UUID().uuidString)")
            // The script stops `login`, then hands the terminal to a job that stops the script
            // and exits: the foreground group is left empty, so nothing on the pty leads back
            // to `login`, which cannot exit until it is resumed.
            let script = try Self.script(
                """
                #!/bin/bash
                trap '' HUP
                echo $$ > "\(pidFile.path)"
                set -m
                kill -STOP $PPID
                sh -c 'printf "\\033]2;foreground gone\\007"; kill -STOP $PPID'
                """)
            defer {
                try? FileManager.default.removeItem(at: script)
                try? FileManager.default.removeItem(at: pidFile)
            }
            var view: GhosttySurfaceView? = GhosttySurfaceView(customCommand: script.path)
            let surface = try #require(view?.surface, "the view needs a Ghostty surface to free")
            await waitUntil(.seconds(30)) { view?.hasObservedPromptReadySignal == true }
            try #require(view?.hasObservedPromptReadySignal == true, "the script never started its job")
            let shell = try Self.recordedPID(in: pidFile)
            let command = getsid(shell)
            try #require(command > 0, "the script's session is unreadable")
            defer {
                kill(command, SIGKILL)
                kill(shell, SIGKILL)
            }
            await waitUntil(.seconds(10)) { GhosttySurfaceChildProcess.pid(of: surface) == nil }
            try #require(GhosttySurfaceChildProcess.pid(of: surface) == nil, "the foreground group never emptied")

            let watchdog = Self.watchdog(sending: SIGKILL, to: [command, shell], after: .seconds(10))
            let grace = (hangUp: manager.hangUpGrace, kill: manager.killGrace)
            manager.hangUpGrace = .milliseconds(300)
            manager.killGrace = .milliseconds(300)
            defer { (manager.hangUpGrace, manager.killGrace) = grace }
            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) {
                    (freed.started, freed.held) = (free.started, free.held)
                }
            }
            defer { manager.onSurfaceFreed = nil }
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")
            let ticks = manager.tickCount
            await waitUntil(.seconds(2)) { freed.started != nil }
            let freedOutOfSight = freed.started != nil
            let ticksOutOfSight = manager.tickCount - ticks

            kill(command, SIGKILL)
            kill(shell, SIGKILL)
            await waitUntil(.seconds(30)) { freed.started != nil }
            watchdog.cancel()
            let killedByWatchdog = await watchdog.value

            #expect(!freedOutOfSight, "the surface was freed while its stopped command was out of sight")
            #expect(ticksOutOfSight >= 10, "the main thread stopped ticking while the command was out of sight")
            #expect(!killedByWatchdog, "the main thread held on the command until the test's watchdog killed it")
            let held = try #require(freed.held, "the surface was never freed once its command was killed")
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

        /// Sends `signal` to `processes` after `timeout` unless cancelled first, from off the main
        /// thread, so a test whose free blocks the main thread on a stopped command still ends.
        /// True if it had to.
        nonisolated private static func watchdog(
            sending signal: Int32, to processes: [pid_t], after timeout: Duration
        ) -> Task<Bool, Never> {
            Task.detached {
                do { try await Task.sleep(for: timeout) } catch { return false }
                for process in processes { kill(process, signal) }
                return true
            }
        }

        /// Watches `command` from off the main thread, every millisecond, until it stops running
        /// or `timeout` passes. Returns the last instant it was seen running, and whether it ended.
        nonisolated private static func watchExit(
            of command: GhosttySurfaceChildProcess.Command, for timeout: Duration
        ) -> Task<(lastRunningAt: ContinuousClock.Instant, ended: Bool), Never> {
            Task.detached {
                let deadline = ContinuousClock.now + timeout
                var lastRunningAt = ContinuousClock.now
                while ContinuousClock.now < deadline {
                    let checked = ContinuousClock.now
                    guard GhosttySurfaceChildProcess.fate(of: command) == .running else {
                        return (lastRunningAt, true)
                    }
                    lastRunningAt = checked
                    try? await Task.sleep(for: .milliseconds(1))
                }
                return (lastRunningAt, false)
            }
        }

        private static func recordedPID(in file: URL) throws -> pid_t {
            let recorded = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return try #require(
                pid_t(recorded.trimmingCharacters(in: .whitespacesAndNewlines)), "the script never recorded its pid")
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

//
//  GhosttySurfaceFreeMainThreadTests.swift
//  WorkspaceManagerAppTests
//
//  Guards the main thread against waiting on a closed terminal's command (#1897).
//  `ghostty_surface_free` runs on the main thread and joins the surface's io thread, which
//  hangs up the command and exits only once the command has. The test holds the command
//  (the `login` wrapper) stopped, so it cannot exit, and resumes it seconds later: a free
//  that does the hang-up itself holds the main thread until then. A script in the command's
//  process group records when the hang-up arrives.
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
        private static let exitDelay: Duration = .seconds(2)

        @Test("Retiring a surface hangs up its command at once, and freeing it never waits on the command's exit")
        func retiringASlowToExitCommand() async throws {
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
            let freed = FreeRecord()
            manager.onSurfaceFreed = { free in
                if free.surfaceAddress == UInt(bitPattern: surface) { freed.held = free.held }
            }
            defer { manager.onSurfaceFreed = nil }
            let resumed = Self.resume(command, after: Self.exitDelay, checking: marker)
            let released = WeakView(view)
            autoreleasepool { view = nil }
            try #require(released.view == nil, "the view outlived its last reference")
            await waitUntil(.seconds(60)) { freed.held != nil }
            let hungUpBeforeResume = await resumed.value

            #expect(hungUpBeforeResume, "the command was not hung up until after it was resumed")
            let held = try #require(freed.held, "the retired surface was never freed")
            #expect(held < Self.exitDelay / 2, "the free held the main thread \(held), waiting on the command's exit")
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
                started - retired < GhosttyAppManager.hangUpGrace,
                "the free waited out the hang-up grace, so the hang-up never reached the command")
        }

        /// Off the main thread, since a free that does the hang-up itself holds it until then.
        nonisolated private static func resume(
            _ command: pid_t, after delay: Duration, checking marker: URL
        ) -> Task<Bool, Never> {
            Task.detached {
                try? await Task.sleep(for: delay)
                let hungUp = FileManager.default.fileExists(atPath: marker.path)
                kill(command, SIGCONT)
                return hungUp
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

private struct WeakView {
    weak var view: GhosttySurfaceView?

    init(_ view: GhosttySurfaceView?) {
        self.view = view
    }
}

//
//  GhosttyWakeupCoalescingProbeTests.swift
//  WorkspaceManagerAppTests
//
//  #1361's measurement: how many libghostty wakeups arrive while an earlier tick is
//  still queued, under heavy output and a live resize. Those are the ticks a "tick
//  already scheduled" bit would skip. It measures rather than asserts a budget, so it
//  runs only on request: WORKSPACES_GHOSTTY_WAKEUP_PROBE=1 swift test --filter WakeupCoalescing
//

import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite(
    "Ghostty wakeup coalescing probe",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_GHOSTTY_WAKEUP_PROBE"] == "1")
)
@MainActor
struct GhosttyWakeupCoalescingProbeTests {
    private static let timeout: TimeInterval = 60

    @Test("Heavy output: 300,000 lines through one surface")
    func heavyOutput() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }

        let view = try harness.makeSurface(BareSurfaceConfig(command: "/usr/bin/seq 1 300000"))
        #expect(await BareGhosttyApp.poll(timeout: Self.timeout) { harness.hasProcessExited(view) })
        await Self.settle(harness)
        Self.report("output", harness.ledger.snapshot)
        harness.free(view)
    }

    @Test("Live resize: 60 size changes at display rate")
    func liveResize() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }

        let view = try harness.makeSurface(BareSurfaceConfig(command: "/bin/sleep 600"))
        let surface = try #require(harness.surface(for: view))
        await Self.settle(harness)
        harness.ledger.reset()

        for step in 0..<60 {
            let grow = UInt32(step % 2 == 0 ? 0 : 40)
            ghostty_surface_set_size(surface, 1600 + grow, 1200 + grow)
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        await Self.settle(harness)
        Self.report("resize", harness.ledger.snapshot)
        harness.free(view)
    }

    @Test("Idle: one sleeping surface for two seconds")
    func idle() async throws {
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }

        let view = try harness.makeSurface(BareSurfaceConfig(command: "/bin/sleep 600"))
        await Self.settle(harness)
        harness.ledger.reset()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await Self.settle(harness)
        Self.report("idle", harness.ledger.snapshot)
        harness.free(view)
    }

    /// Lets every queued tick run, so each wakeup counted has had its tick.
    private static func settle(_ harness: BareGhosttyApp) async {
        _ = await BareGhosttyApp.poll(timeout: timeout) {
            let counts = harness.ledger.snapshot
            return counts.ticks == counts.wakeups
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private static func report(_ scenario: String, _ counts: GhosttyWakeupLedger.Counts) {
        let share = counts.wakeups == 0 ? 0 : Double(counts.coalescible) / Double(counts.wakeups)
        print(
            String(
                format: "[WakeupProbe] scenario=%@ wakeups=%d ticks=%d coalescible=%d coalescible_share=%.3f",
                scenario, counts.wakeups, counts.ticks, counts.coalescible, share))
        #expect(counts.ticks == counts.wakeups)
    }
}

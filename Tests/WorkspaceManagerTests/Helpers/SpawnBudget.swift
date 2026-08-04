//
//  SpawnBudget.swift
//  WorkspaceManagerTests
//
//  Sizes test deadlines from this machine's measured process-spawn cost instead of a
//  fixed wall clock. Spawn latency is the dominant and least predictable term for any
//  test that supervises child processes: a laptop launches the Python stub in ~0.2s
//  while a loaded hosted runner has measured 13-15s for the same work, so a constant
//  budget is a bet against a quantity the test cannot see in advance.
//

import Foundation

enum SpawnBudget {
    /// Reproduces another machine's spawn latency without needing that machine —
    /// set `WORKSPACES_TEST_SPAWN_BASELINE_SECONDS=15` to run a spawn-bound suite
    /// under loaded-hosted-runner budgets from a fast laptop.
    static let baselineOverrideKey = "WORKSPACES_TEST_SPAWN_BASELINE_SECONDS"

    /// Cost of one `python3 -c "import http.server"` on this machine, measured once
    /// per test process. The probe doubles as a warm-up — it faults in the interpreter
    /// and the modules the stubs import, so the first real test does not pay for both.
    static let spawnSeconds: TimeInterval = resolveSpawnSeconds()

    /// Deadline for an observable event costing roughly `spawns` process launches.
    /// Never below `floor`, so a fast machine still fails quickly when something is
    /// genuinely broken; never above `ceiling`, so a pathological baseline cannot hang
    /// the run. These bound failure only: a passing test returns the moment it
    /// observes its state change, so a generous ceiling is free when the machine is
    /// healthy.
    static func deadline(
        spawns: Double,
        floor: TimeInterval,
        ceiling: TimeInterval = 300
    ) -> TimeInterval {
        deadline(spawnSeconds: spawnSeconds, spawns: spawns, floor: floor, ceiling: ceiling)
    }

    /// The scaling itself, independent of what this machine measured, so the budget
    /// policy can be tested at latencies the test machine will never exhibit.
    static func deadline(
        spawnSeconds: TimeInterval,
        spawns: Double,
        floor: TimeInterval,
        ceiling: TimeInterval
    ) -> TimeInterval {
        min(ceiling, max(floor, spawnSeconds * spawns))
    }

    private static func resolveSpawnSeconds() -> TimeInterval {
        if let raw = ProcessInfo.processInfo.environment[baselineOverrideKey],
            let override = TimeInterval(raw), override > 0
        {
            report(override, source: "override via \(baselineOverrideKey)")
            return override
        }
        return measureSpawnSeconds()
    }

    /// Two samples, worst wins: the first pays cold-cache cost and the second reflects
    /// steady state. Over-estimating only widens deadlines, so the pessimistic sample
    /// is the safe one to keep.
    private static func measureSpawnSeconds() -> TimeInterval {
        var worst: TimeInterval = 0
        for _ in 0..<2 {
            guard let sample = timeOneSpawn() else {
                report(unmeasurableSpawnSeconds, source: "unmeasurable, using fallback")
                return unmeasurableSpawnSeconds
            }
            worst = max(worst, sample)
        }
        let measured = max(worst, 0.05)
        report(measured, source: "measured")
        return measured
    }

    /// Stand-in for a machine where the probe itself cannot run (no `python3` on
    /// PATH). Generous on purpose: an unmeasurable machine is not evidence of a fast
    /// one, and the stub scripts need the same interpreter anyway.
    private static let unmeasurableSpawnSeconds: TimeInterval = 5

    /// Printed once per test process so a future failure is diagnosable from the CI
    /// log alone: every budget in the spawn-bound suites is a multiple of this number.
    private static func report(_ seconds: TimeInterval, source: String) {
        print(String(format: "[SpawnBudget] process-spawn baseline: %.3fs (%@)", seconds, source))
    }

    private static func timeOneSpawn() -> TimeInterval? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import http.server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let started = Date()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return Date().timeIntervalSince(started)
    }
}

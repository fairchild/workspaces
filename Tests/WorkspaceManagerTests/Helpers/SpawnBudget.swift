//
//  SpawnBudget.swift
//  WorkspaceManagerTests
//
//  Sizes test deadlines from this machine's measured process-spawn cost instead of a
//  fixed wall clock. Spawn latency is the dominant and least predictable term for any
//  test that supervises child processes: a laptop launches the Python stub in ~0.1s
//  while a loaded hosted runner has measured 13-15s for the same work, so a constant
//  budget is a bet against a quantity the test cannot see in advance.
//
//  Load is not stationary either, so a single calibration at suite start is the same
//  bet one step removed. The baseline is therefore a running maximum that can be
//  re-measured on demand — budgets only ever widen, and a wait that misses its
//  deadline can ask whether the machine slowed down before calling it a regression.
//

import Foundation

actor SpawnBudget {
    /// Reproduces another machine's spawn latency without needing that machine —
    /// set `WORKSPACES_TEST_SPAWN_BASELINE_SECONDS=15` to run a spawn-bound suite
    /// under loaded-hosted-runner budgets from a fast laptop.
    static let baselineOverrideKey = "WORKSPACES_TEST_SPAWN_BASELINE_SECONDS"

    /// Longest a single probe may run before it is killed and its cap reported as the
    /// sample. A hung interpreter must not become an unbounded wait — the probe is
    /// load instrumentation, and a capped over-estimate only widens budgets.
    private static let probeCap: TimeInterval = 30

    /// Stand-in for a machine where the probe cannot run at all (no `python3` on
    /// PATH). Generous on purpose: an unmeasurable machine is not evidence of a fast
    /// one, and the stub scripts need the same interpreter anyway.
    private static let unmeasurableSpawnSeconds: TimeInterval = 5

    private static let shared = SpawnBudget()

    private var observedSpawnSeconds: TimeInterval?

    /// Highest spawn cost observed so far in this test process. Measured on first use
    /// — the probe doubles as a warm-up, faulting in the interpreter and the modules
    /// the stubs import so the first real test does not pay for both.
    static func spawnSeconds() async -> TimeInterval {
        await shared.value(refreshing: false)
    }

    /// Re-probes and folds the sample into the running maximum. Call when a wait has
    /// already missed its deadline, or right before handing a budget to something that
    /// cannot be extended later — those are the two places a stale baseline turns into
    /// a failure that has nothing to do with the code under test.
    static func refreshedSpawnSeconds() async -> TimeInterval {
        await shared.value(refreshing: true)
    }

    /// Deadline for an observable event costing roughly `spawns` process launches.
    /// Never below `floor`, so a fast machine still fails quickly when something is
    /// genuinely broken; never above `ceiling`, so a pathological baseline cannot hang
    /// the run. These bound failure only: a passing test returns the moment it
    /// observes its state change, so a generous ceiling is free on a healthy machine.
    static func deadline(
        spawns: Double,
        floor: TimeInterval,
        ceiling: TimeInterval,
        refreshing: Bool = false
    ) async -> TimeInterval {
        let baseline = refreshing ? await refreshedSpawnSeconds() : await spawnSeconds()
        return deadline(spawnSeconds: baseline, spawns: spawns, floor: floor, ceiling: ceiling)
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

    private func value(refreshing: Bool) async -> TimeInterval {
        if let override = Self.baselineOverride {
            if observedSpawnSeconds == nil {
                Self.report(override, source: "override via \(Self.baselineOverrideKey)")
                observedSpawnSeconds = override
            }
            return override
        }
        if let observed = observedSpawnSeconds, !refreshing {
            return observed
        }

        // Two samples on the first measurement: the first pays cold-cache cost and the
        // second reflects steady state. Refreshes take one — the point there is the
        // machine's cost right now, not its warm-up.
        var sample = await Self.probe()
        if observedSpawnSeconds == nil {
            sample = max(sample, await Self.probe())
        }

        let updated = max(observedSpawnSeconds ?? 0, sample)
        if updated != observedSpawnSeconds {
            Self.report(updated, source: observedSpawnSeconds == nil ? "measured" : "re-measured")
        }
        observedSpawnSeconds = updated
        return updated
    }

    private static let baselineOverride: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment[baselineOverrideKey],
            let value = TimeInterval(raw), value > 0
        else { return nil }
        return value
    }()

    /// Times one `python3 -c "import http.server"` on a dedicated thread. The wait is
    /// blocking by nature, and running it on a cooperative executor would park a
    /// concurrency worker for as long as the machine is slow — exactly when the
    /// remaining workers are needed most.
    private static func probe() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: blockingProbe()) }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private static func blockingProbe() -> TimeInterval {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import http.server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let started = Date()
        do {
            try process.run()
        } catch {
            return unmeasurableSpawnSeconds
        }

        let deadline = started.addingTimeInterval(probeCap)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        guard !process.isRunning else {
            // Capped, not measured: the machine is at least this slow, which is all a
            // budget needs to know.
            process.terminate()
            return probeCap
        }
        guard process.terminationStatus == 0 else { return unmeasurableSpawnSeconds }
        return max(Date().timeIntervalSince(started), 0.05)
    }

    /// Printed whenever the baseline changes so a future failure is diagnosable from
    /// the CI log alone: every budget in the spawn-bound suites is a multiple of it.
    private static func report(_ seconds: TimeInterval, source: String) {
        print(String(format: "[SpawnBudget] process-spawn baseline: %.3fs (%@)", seconds, source))
    }
}

/// Waits for `condition`, and when the deadline passes, asks whether the machine got
/// slower than the baseline the deadline was sized from before giving up. Re-measuring
/// only on a miss keeps the happy path free while removing the stationary-load
/// assumption — the assumption behind both previous attempts at these budgets.
func waitUntilSpawnScaled(
    spawns: Double,
    floor: TimeInterval,
    ceiling: TimeInterval,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let budget = await SpawnBudget.deadline(spawns: spawns, floor: floor, ceiling: ceiling)
    if await waitUntil(timeout: budget, condition) { return true }

    let refreshed = await SpawnBudget.deadline(
        spawns: spawns, floor: floor, ceiling: ceiling, refreshing: true)
    guard refreshed > budget else { return false }
    return await waitUntil(timeout: refreshed - budget, condition)
}

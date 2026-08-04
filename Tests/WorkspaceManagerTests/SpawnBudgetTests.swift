//
//  SpawnBudgetTests.swift
//  WorkspaceManagerTests
//
//  Covers the budget-scaling policy the spawn-bound suites depend on, at latencies
//  the test machine will never exhibit — the whole point of the scaling is behaviour
//  on a runner nobody can reproduce locally.
//

import Foundation
import Testing

@Suite("SpawnBudget")
struct SpawnBudgetTests {
    /// Representative of a developer laptop: ~0.2s to launch the Python stub.
    private let fastMachine: TimeInterval = 0.2
    /// Representative of the loaded hosted runner measured on 2026-08-03.
    private let loadedRunner: TimeInterval = 15

    @Test("a fast machine keeps the human-scale floor so real breakage still fails quickly")
    func fastMachineUsesFloor() {
        let budget = SpawnBudget.deadline(
            spawnSeconds: fastMachine, spawns: 8, floor: 45, ceiling: 240)
        #expect(budget == 45)
    }

    @Test("a loaded machine scales past the floor instead of betting against its own latency")
    func loadedMachineScalesUp() {
        let budget = SpawnBudget.deadline(
            spawnSeconds: loadedRunner, spawns: 8, floor: 45, ceiling: 240)
        #expect(budget == 120)
        #expect(budget > 45, "the floor must not cap a machine slower than it assumes")
    }

    @Test("the ceiling bounds a pathological baseline so no single test can hang the run")
    func ceilingBoundsPathologicalBaseline() {
        let budget = SpawnBudget.deadline(
            spawnSeconds: 600, spawns: 8, floor: 45, ceiling: 240)
        #expect(budget == 240)
    }

    @Test("budgets sharing a floor:ceiling ratio keep their ordering at every latency")
    func relativeBudgetsSurviveScaling() {
        // WebNextServerServiceTests' early-exit test asserts that failing fast beats
        // the readiness budget it did not wait out. That comparison is only meaningful
        // if the two budgets stay ordered as the machine slows down.
        for spawnSeconds in [0.05, 0.2, 1, 5, 15, 60, 600] as [TimeInterval] {
            let readiness = SpawnBudget.deadline(
                spawnSeconds: spawnSeconds, spawns: 12, floor: 60, ceiling: 360)
            let fastFail = SpawnBudget.deadline(
                spawnSeconds: spawnSeconds, spawns: 3, floor: 15, ceiling: 120)
            #expect(
                fastFail * 2 < readiness,
                "at a \(spawnSeconds)s baseline the fast-fail bound (\(fastFail)s) must stay well under the readiness budget (\(readiness)s)"
            )
        }
    }

    @Test("the measured baseline is a positive duration usable as a scaling factor")
    func measuredBaselineIsUsable() async {
        #expect(await SpawnBudget.spawnSeconds() > 0)
        #expect(await SpawnBudget.deadline(spawns: 4, floor: 20, ceiling: 120) >= 20)
    }

    @Test("re-measuring never lowers the baseline, so budgets only widen mid-run")
    func refreshNeverLowersTheBaseline() async {
        // Load is not stationary: a baseline taken at suite start can be an
        // under-estimate by the time a later test uses it. Re-measuring has to be safe
        // to call at any moment, which means it can raise the baseline but never
        // shrink a budget another test already sized from it.
        let first = await SpawnBudget.spawnSeconds()
        let refreshed = await SpawnBudget.refreshedSpawnSeconds()
        #expect(refreshed >= first)
        #expect(await SpawnBudget.spawnSeconds() == refreshed, "the raised baseline must stick")
    }
}

//
//  LaunchBudgetTests.swift
//  WorkspaceManagerTests
//
//  Covers the budget-scaling policy the launch-bound suites depend on, at latencies
//  the test machine will never exhibit — the whole point of the scaling is behaviour
//  on a runner nobody can reproduce locally.
//

import Foundation
import Testing

@Suite("LaunchBudget")
struct LaunchBudgetTests {
    /// Representative of a developer laptop launching the Python stub and getting an
    /// answer out of it.
    private let fastMachine: TimeInterval = 0.3
    /// Representative of the loaded hosted runner measured on PR #1204's own CI run,
    /// where the same round trip took two orders of magnitude longer.
    private let loadedRunner: TimeInterval = 35

    @Test("a fast machine keeps the human-scale floor so real breakage still fails quickly")
    func fastMachineUsesFloor() {
        let budget = LaunchBudget.deadline(
            launchSeconds: fastMachine, launches: 3, floor: 45, ceiling: 360)
        #expect(budget == 45)
    }

    @Test("a loaded machine scales past the floor instead of betting against its own latency")
    func loadedMachineScalesUp() {
        let budget = LaunchBudget.deadline(
            launchSeconds: loadedRunner, launches: 3, floor: 45, ceiling: 360)
        #expect(budget == 105)
        #expect(budget > 45, "the floor must not cap a machine slower than it assumes")
    }

    @Test("the ceiling bounds a pathological baseline so no single test can hang the run")
    func ceilingBoundsPathologicalBaseline() {
        let budget = LaunchBudget.deadline(
            launchSeconds: 600, launches: 3, floor: 45, ceiling: 360)
        #expect(budget == 360)
    }

    @Test("budgets sharing a floor:ceiling ratio keep their ordering at every latency")
    func relativeBudgetsSurviveScaling() {
        // WebNextServerServiceTests' early-exit test asserts that failing fast beats
        // the readiness budget it did not wait out. That comparison is only meaningful
        // if the two budgets stay ordered as the machine slows down.
        for launchSeconds in [0.05, 0.3, 1, 5, 15, 35, 60, 600] as [TimeInterval] {
            let readiness = LaunchBudget.deadline(
                launchSeconds: launchSeconds, launches: 4, floor: 60, ceiling: 600)
            let fastFail = LaunchBudget.deadline(
                launchSeconds: launchSeconds, launches: 1, floor: 15, ceiling: 180)
            #expect(
                fastFail * 2 < readiness,
                "at a \(launchSeconds)s baseline the fast-fail bound (\(fastFail)s) must stay well under the readiness budget (\(readiness)s)"
            )
        }
    }

    @Test("the measured baseline is a positive duration usable as a scaling factor")
    func measuredBaselineIsUsable() async {
        #expect(await LaunchBudget.launchSeconds() > 0)
        #expect(await LaunchBudget.deadline(launches: 1.5, floor: 20, ceiling: 240) >= 20)
    }

    @Test("re-measuring never lowers the baseline, so budgets only widen mid-run")
    func refreshNeverLowersTheBaseline() async {
        // Load is not stationary: a baseline taken at suite start can be an
        // under-estimate by the time a later test uses it. Re-measuring has to be safe
        // to call at any moment, which means it can raise the baseline but never
        // shrink a budget another test already sized from it.
        let first = await LaunchBudget.launchSeconds()
        let refreshed = await LaunchBudget.refreshedLaunchSeconds()
        #expect(refreshed >= first)
        #expect(await LaunchBudget.launchSeconds() == refreshed, "the raised baseline must stick")
    }
}

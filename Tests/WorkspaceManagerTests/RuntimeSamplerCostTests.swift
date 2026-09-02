//
//  RuntimeSamplerCostTests.swift
//  WorkspaceManagerTests
//
//  The two numbers #1368 is accepted on, measured against the live machine:
//  what the always-on sampler costs at its real cadence, and whether the
//  app-tree total agrees with the per-pid footprints it is built from.
//
//  The cost run takes longer than a unit test should, so it is opt-in:
//  `WORKSPACES_SAMPLER_COST_RUN=1 swift test --filter RuntimeSamplerCost`.
//  Its duration and cadence are overridable for a shorter local pass; the
//  numbers quoted in the PR come from the default five-and-a-half minutes.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RuntimeSamplerCost", .serialized)
struct RuntimeSamplerCostTests {

    private static var costRunEnabled: Bool {
        ProcessInfo.processInfo.environment["WORKSPACES_SAMPLER_COST_RUN"] == "1"
    }

    private static var costRunSeconds: TimeInterval {
        ProcessInfo.processInfo.environment["WORKSPACES_SAMPLER_COST_SECONDS"]
            .flatMap(Double.init) ?? 330
    }

    private static var costRunCadence: TimeInterval {
        ProcessInfo.processInfo.environment["WORKSPACES_SAMPLER_COST_CADENCE"]
            .flatMap(Double.init) ?? 30
    }

    @Test(
        "Steady-state sampler cost stays under 0.5% of one core",
        .enabled(if: costRunEnabled, "opt-in: set WORKSPACES_SAMPLER_COST_RUN=1")
    )
    func steadyStateCostUnderHalfAPercent() async {
        let sampler = RuntimeDiagnosticsSampler(minimumSampleInterval: 0)
        let cadence = Self.costRunCadence
        let deadline = Date().addingTimeInterval(Self.costRunSeconds)

        var samplingCPUSeconds: TimeInterval = 0
        var sampleCount = 0
        var processCount = 0
        let startedAt = Date()

        while Date() < deadline {
            let before = Self.ownCPUSeconds()
            let snapshot = await sampler.sample(workspaceDirectories: [])
            samplingCPUSeconds += Self.ownCPUSeconds() - before
            sampleCount += 1
            processCount = max(processCount, snapshot?.allProcesses.count ?? 0)
            try? await Task.sleep(for: .seconds(cadence))
        }

        let wallSeconds = Date().timeIntervalSince(startedAt)
        let dutyPercent = (samplingCPUSeconds / wallSeconds) * 100
        let msPerSample = (samplingCPUSeconds / Double(max(sampleCount, 1))) * 1_000

        print(
            String(
                format: """
                    [#1368 sampler cost] samples=%d processes=%d cadence=%.0fs \
                    wall=%.1fs samplingCPU=%.3fs perSample=%.2fms duty=%.4f%%
                    """,
                sampleCount, processCount, cadence, wallSeconds, samplingCPUSeconds,
                msPerSample, dutyPercent
            )
        )

        #expect(sampleCount >= 10)
        #expect(dutyPercent < 0.5)
    }

    @Test("Reported totals agree with the per-pid footprints they sum")
    func totalsAgreeWithSummedFootprints() async {
        let sampler = RuntimeDiagnosticsSampler(minimumSampleInterval: 0)

        // Bracket the sample with two independent `proc_pid_rusage` passes over
        // the same pids. A live process allocates while it is being measured, so
        // the honest question is whether the reported total lands between two
        // readings taken either side of it — not whether it equals a reading
        // taken afterwards, which drifts by however much ran in between.
        let treePIDs = ProcessInventory.descendantPIDs(of: getpid())
        let treeBefore = Self.summedFootprints(treePIDs)
        let hostPIDs = ProcessInventory.allPIDs()
        let hostBefore = Self.summedFootprints(hostPIDs)

        guard let snapshot = await sampler.sample(workspaceDirectories: []),
            !snapshot.appTreeProcesses.isEmpty
        else {
            Issue.record("sampler returned no app-tree processes")
            return
        }

        let treeAfter = Self.summedFootprints(treePIDs)
        let hostAfter = Self.summedFootprints(hostPIDs)

        let treeReported = snapshot.appTreeTotals.residentMemoryBytes
        let hostReported = snapshot.allProcesses.reduce(Int64(0)) { $0 + $1.residentMemoryBytes }

        let treeDrift = Self.drift(reported: treeReported, between: treeBefore, and: treeAfter)
        let hostDrift = Self.drift(reported: hostReported, between: hostBefore, and: hostAfter)

        print(
            String(
                format: """
                    [#1368 app-tree footprint] pids=%d reported=%lld (%.1f MB) \
                    independent=%lld…%lld (%.1f…%.1f MB) drift=%.3f%%
                    [#1368 host footprint] pids=%d reported=%lld (%.1f MB) \
                    independent=%lld…%lld (%.1f…%.1f MB) drift=%.3f%%
                    """,
                snapshot.appTreeProcesses.count,
                treeReported, Double(treeReported) / 1_048_576,
                min(treeBefore, treeAfter), max(treeBefore, treeAfter),
                Double(min(treeBefore, treeAfter)) / 1_048_576,
                Double(max(treeBefore, treeAfter)) / 1_048_576,
                treeDrift * 100,
                snapshot.allProcesses.count,
                hostReported, Double(hostReported) / 1_048_576,
                min(hostBefore, hostAfter), max(hostBefore, hostAfter),
                Double(min(hostBefore, hostAfter)) / 1_048_576,
                Double(max(hostBefore, hostAfter)) / 1_048_576,
                hostDrift * 100
            )
        )

        // The app-tree criterion, made gating.
        //
        // An earlier form of this compared the reported total against the sum of
        // the very array the total was reduced from, which is an identity — a
        // tree missing every descendant but the root still passed. Membership is
        // now checked against the kernel instead: every pid the sampler placed in
        // the tree has its parentage walked independently, and must reach the
        // root. Comparing against a *snapshot* of the descendant set does not
        // work here, because neighbouring suites spawn and reap children of this
        // same process while the sweep runs; parentage is a per-pid fact and is
        // not disturbed by them. The other direction — that live descendants are
        // not dropped — is `appTreeContainsRealDescendants`, which brings its own
        // child rather than borrowing someone else's.
        let root = getpid()
        for process in snapshot.appTreeProcesses where process.pid != root {
            var walker = process.pid
            var reachedRoot = false
            for _ in 0..<64 {
                guard let entry = ProcessInventory.entry(pid: walker) else { break }
                if entry.parentPID == root {
                    reachedRoot = true
                    break
                }
                guard entry.parentPID > 1 else { break }
                walker = entry.parentPID
            }
            // A pid that exited between the sweep and this walk reads as gone,
            // which is an absence of evidence rather than a stranger.
            let stillLive = ProcessInventory.entry(pid: process.pid) != nil
            #expect(
                reachedRoot || !stillLive,
                "pid \(process.pid) (\(process.name)) is in the app tree but is not a descendant"
            )
        }

        #expect(treeReported > 0)
        #expect(treeDrift < 0.10)
        #expect(hostReported > 0)
        #expect(hostDrift < 0.10)
    }

    @Test("The app tree contains the app's actual descendants, not just its root")
    func appTreeContainsRealDescendants() async throws {
        // The membership check above cannot fail on its own: a test runner has no
        // children, so "tree == root" is both the correct answer and what a broken
        // tree builder returns. This gives the tree a descendant to find. Verified
        // by mutation — making `appTreeProcesses` return only the root turns this
        // red while every other test in the suite stays green.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }

        let sampler = RuntimeDiagnosticsSampler(minimumSampleInterval: 0)
        guard let snapshot = await sampler.sample(workspaceDirectories: []) else {
            Issue.record("sampler returned no snapshot")
            return
        }

        let tree = snapshot.appTreeProcesses
        #expect(tree.map(\.pid).contains(child.processIdentifier))
        #expect(tree.count >= 2)
        // The total is over the whole tree, so the child's footprint is inside it.
        let childFootprint = tree.first { $0.pid == child.processIdentifier }?.residentMemoryBytes ?? 0
        #expect(childFootprint > 0)
        #expect(snapshot.appTreeTotals.residentMemoryBytes >= childFootprint)
        #expect(snapshot.appTreeTotals.processCount == tree.count)
    }

    private static func summedFootprints(_ pids: [Int32]) -> Int64 {
        pids.reduce(Int64(0)) { $0 + (RuntimeProcessMemory.physicalFootprint(pid: $1) ?? 0) }
    }

    /// How far the reported total sits outside the interval the two independent
    /// readings bracket. Zero when it lands between them.
    private static func drift(reported: Int64, between first: Int64, and second: Int64) -> Double {
        let low = min(first, second)
        let high = max(first, second)
        let reference = Double(max((low + high) / 2, 1))
        if reported < low { return Double(low - reported) / reference }
        if reported > high { return Double(reported - high) / reference }
        return 0
    }

    /// This process's own CPU time, user plus system, from the same rusage the
    /// footprint metric comes from.
    private static func ownCPUSeconds() -> TimeInterval {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return 0 }
        return Double(info.ri_user_time + info.ri_system_time) / 1_000_000_000
    }
}

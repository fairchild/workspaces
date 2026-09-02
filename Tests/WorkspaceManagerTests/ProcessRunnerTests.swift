//
//  ProcessRunnerTests.swift
//  WorkspaceManagerTests
//
//  Tests for shared process execution behavior under large output and failures.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("Handles successful process with no output")
    func handlesNoOutputProcess() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", "exit 0"]
        )

        #expect(result.success)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("Handles large stdout and stderr without hanging")
    func handlesLargeOutputWithoutHanging() async throws {
        let oneMB = 1_048_576
        let command = [
            "yes \"stdout-block\" | head -c \(oneMB)",
            "yes \"stderr-block\" | head -c \(oneMB) >&2",
        ].joined(separator: "\n")

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", command]
        )

        #expect(result.success)
        #expect(result.stdout.utf8.count >= oneMB)
        #expect(result.stderr.utf8.count >= oneMB)
    }

    @Test("Captures stderr and exit code for non-zero exit")
    func capturesFailureDetails() async throws {
        let command = [
            "echo \"intentional failure\" >&2",
            "exit 7",
        ].joined(separator: "\n")

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", command]
        )

        #expect(!result.success)
        #expect(result.exitCode == 7)
        #expect(result.stderr.contains("intentional failure"))
    }

    @Test("Captures short stdout reliably for rapid process exits")
    func capturesShortStdoutReliably() async throws {
        for index in 0..<100 {
            let token = "rapid-\(index)"
            let result = try await ProcessRunner.run(
                executable: "/bin/echo",
                arguments: [token]
            )

            #expect(result.success)
            #expect(result.stdout.contains(token))
        }
    }

    @Test("Returns after exit when a backgrounded child holds the pipes open")
    func returnsWhenBackgroundedChildHoldsPipes() async throws {
        let start = ContinuousClock.now
        let command = [
            "echo before-background",
            "sleep \(Self.unreachableChildLifetimeSeconds) &",
            "exit 0",
        ].joined(separator: "\n")

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", command],
            pipeDrainGracePeriod: 0.5
        )
        let elapsed = ContinuousClock.now - start

        // The property is the foreground exit: `run` returned it, with its output,
        // while a grandchild still holds the write end of the pipe. Both assertions
        // are on that observable outcome rather than on how long it took.
        #expect(result.success)
        #expect(result.stdout.contains("before-background"))
        // The residual bound only separates "returned on the exit" from "waited on the
        // pipe", and the two are now three orders of magnitude apart, so the ceiling is
        // sized from this machine's measured launch cost instead of a constant a loaded
        // runner can exceed while behaving correctly.
        #expect(elapsed < .seconds(await Self.spawnBoundedCeiling()))
    }

    @Test("Throws timedOut for a child that never exits")
    func timesOutHungChild() async throws {
        let start = ContinuousClock.now

        // The property is the throw: a child outliving its timeout must surface as
        // `timedOut`, not as a success once the child eventually exits. With a child
        // whose lifetime no reasonable elapsed time can reach, a returned result could
        // only mean the runner stopped enforcing the timeout.
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-c", "sleep \(Self.unreachableChildLifetimeSeconds)"],
                timeout: 0.5
            )
        }

        let elapsed = ContinuousClock.now - start
        // Same reasoning as the backgrounded-child test: a launch-scaled ceiling, so a
        // contended runner does not fail a correct runner.
        #expect(elapsed < .seconds(await Self.spawnBoundedCeiling()))
    }

    /// How long the child in the two timeout tests sleeps. Far beyond any elapsed time
    /// the ceiling below permits, so "the runner returned because the child exited" and
    /// "the runner returned because it enforced its own deadline" can never be confused
    /// — which is what the previous fixed 30s child and 25s bound left one contended
    /// runner away from (#1033).
    private static let unreachableChildLifetimeSeconds = 600

    /// Upper bound on a run that should finish in well under a second of real work,
    /// scaled from this machine's measured cost of spawning a child and hearing back.
    /// The floor keeps a genuine hang failing quickly on a fast machine; the ceiling
    /// keeps a pathological baseline from turning a failure into a hang.
    private static func spawnBoundedCeiling() async -> Double {
        await LaunchBudget.deadline(launches: 3, floor: 10, ceiling: 120)
    }

    @Test("Timeout leaves a process that completes in time untouched")
    func timeoutUnusedForFastProcess() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["fast-enough"],
            timeout: 30
        )

        #expect(result.success)
        #expect(result.stdout.contains("fast-enough"))
    }
}

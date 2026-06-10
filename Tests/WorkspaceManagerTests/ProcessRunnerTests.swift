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
            "sleep 30 &",
            "exit 0",
        ].joined(separator: "\n")

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: ["-c", command],
            pipeDrainGracePeriod: 0.5
        )
        let elapsed = ContinuousClock.now - start

        #expect(result.success)
        #expect(result.stdout.contains("before-background"))
        #expect(elapsed < .seconds(10))
    }

    @Test("Throws timedOut for a child that never exits")
    func timesOutHungChild() async throws {
        let start = ContinuousClock.now

        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(
                executable: "/bin/bash",
                arguments: ["-c", "sleep 30"],
                timeout: 0.5
            )
        }

        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(10))
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

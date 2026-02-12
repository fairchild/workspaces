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
}

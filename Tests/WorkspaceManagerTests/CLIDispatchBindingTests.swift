//
//  CLIDispatchBindingTests.swift
//  WorkspaceManagerTests
//
//  Binds the alias spellings the smoke scripts type — `workspaces workspace select`,
//  `workspaces window snapshot` — to the handlers they must reach, by running the real
//  `workspaces` binary. `CLIVerbCatalogTests` proves canonicalization is correct in
//  isolation; only this proves the dispatch path actually calls it.
//

import Foundation
import Testing

@Suite("CLI dispatch binding")
struct CLIDispatchBindingTests {
    private struct Invocation {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// The `workspaces` product, built beside the test bundle by both `swift build` and
    /// `swift test`. Discovery walks from the most specific source outward: an explicit
    /// override, the test bundle the runner was handed, then the package's own build
    /// directory. A missing binary fails rather than skips — without it the alias spellings
    /// have no coverage at all.
    private static var cliBinaryURL: URL? {
        candidateBinaryURLs.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var candidateBinaryURLs: [URL] {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WORKSPACES_TEST_CLI_BINARY"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        // The swift-testing runner lives in the toolchain, so Bundle.main is useless here;
        // the bundle under test arrives as an argument instead.
        for argument in CommandLine.arguments {
            guard let buildDirectory = enclosingBundleParent(of: argument) else { continue }
            candidates.append(buildDirectory.appendingPathComponent("workspaces"))
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for configuration in ["debug", "release"] {
            candidates.append(
                packageRoot
                    .appendingPathComponent(".build")
                    .appendingPathComponent(configuration)
                    .appendingPathComponent("workspaces")
            )
        }
        return candidates
    }

    /// The build directory holding a `.xctest` bundle named anywhere in `path`, or nil when
    /// the path names no bundle.
    private static func enclosingBundleParent(of path: String) -> URL? {
        guard path.contains(".xctest") else { return nil }
        var url = URL(fileURLWithPath: path)
        while url.pathComponents.count > 1 {
            if url.lastPathComponent.hasSuffix(".xctest") {
                return url.deletingLastPathComponent()
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// Runs the CLI with its state store redirected into a scratch directory, so dispatch is
    /// exercised without reading or writing the developer's real CLI state.
    private func runCLI(_ arguments: [String]) throws -> Invocation? {
        guard let binary = Self.cliBinaryURL else {
            let searched = Self.candidateBinaryURLs.map(\.path).joined(separator: ", ")
            Issue.record("workspaces binary not found — run 'swift build' first. Searched: \(searched)")
            return nil
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_CONFIG_HOME"] = scratch.path
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Invocation(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    /// Both invocations stop in argument parsing, before any socket or credential read, so
    /// the assertion is about which handler received them and nothing else.
    @Test(
        "Smoke-script alias spellings reach their grouped handlers",
        arguments: [
            (["workspace", "select"], "Usage: workspaces automation workspace select"),
            (["window", "snapshot"], "Usage: workspaces automation window snapshot --out <path>"),
        ]
    )
    func aliasSpellingsDispatchToHandlers(arguments: [String], expected: String) throws {
        guard let result = try runCLI(arguments) else { return }
        #expect(result.stderr.contains(expected))
        // The failure mode this guards: dispatching the raw vector instead of the
        // canonicalized one leaves 'workspace'/'window' unknown at top level.
        #expect(!result.stderr.contains("Unknown command"))
        #expect(result.status == 1)
    }

    @Test(
        "Alias and grouped spellings produce identical output",
        arguments: [["workspace", "select"], ["window", "snapshot"]]
    )
    func aliasAndGroupedSpellingsAgree(arguments: [String]) throws {
        guard let alias = try runCLI(arguments), let grouped = try runCLI(["automation"] + arguments) else {
            return
        }
        #expect(alias.stderr == grouped.stderr)
        #expect(alias.stdout == grouped.stdout)
        #expect(alias.status == grouped.status)
    }

    @Test("An unclaimed first argument still fails as an unknown command")
    func unknownVerbStaysUnknown() throws {
        guard let result = try runCLI(["nonsense", "select"]) else { return }
        #expect(result.stderr.contains("Unknown command 'nonsense'"))
        #expect(result.status == 1)
    }
}

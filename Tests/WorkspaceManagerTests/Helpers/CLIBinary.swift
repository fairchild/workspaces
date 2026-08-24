//
//  CLIBinary.swift
//  WorkspaceManagerTests
//
//  Finds and runs the real `workspaces` executable, for the tests whose whole point
//  is the process boundary — argv, stdout/stderr, exit status — rather than the
//  functions behind it.
//

import Foundation
import Testing

enum CLIBinary {
    /// The `workspaces` product, built beside the test bundle by both `swift build` and
    /// `swift test`. Discovery walks from the most specific source outward: an explicit
    /// override, the test bundle the runner was handed, then the package's own build
    /// directory.
    ///
    /// Why a filesystem lookup instead of a build-graph edge: SwiftPM's only way for a test
    /// target to depend on an executable target is to *link* it, which pulls `main.swift`'s
    /// top-level code and its AppKit dependency into the test bundle and still hands back no
    /// path — and these tests' whole point is launching the real process. What the build
    /// graph does guarantee is placement: `swift build` and `swift test` both build every
    /// product in the package into the configuration directory the test bundle also lands
    /// in, so the binary is beside the bundle in either flow. A missing binary therefore
    /// means a broken invocation, not an unsupported environment, and callers fail on it
    /// with the searched paths rather than skipping.
    static var url: URL? {
        candidateURLs.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var candidateURLs: [URL] {
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

    static var searchedPathsDescription: String {
        candidateURLs.map(\.path).joined(separator: ", ")
    }

    static var missingBinaryMessage: Comment {
        """
        workspaces binary not found — build the package first ('swift build' or 'swift test' \
        builds it into the same configuration directory as this bundle), or point \
        WORKSPACES_TEST_CLI_BINARY at it. Searched: \(CLIBinary.searchedPathsDescription)
        """
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

    struct Invocation {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs the CLI with the caller's environment additions applied. Callers redirect
    /// `XDG_CONFIG_HOME` into a scratch directory so dispatch is exercised without
    /// reading or writing the developer's real CLI state.
    static func run(
        _ binary: URL,
        arguments: [String],
        currentDirectory: URL,
        environment extraEnvironment: [String: String] = [:]
    ) throws -> Invocation {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
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
}

//
//  GhosttySurfaceSpawnContractTests.swift
//  WorkspaceManagerAppTests
//
//  #889 at the spawn layer: every surface's child must start with the command,
//  environment, working directory and initial input it was configured with — the first
//  surface of an app and every later one alike. Each child writes what it saw to a file,
//  so a dropped field shows up as a missing or wrong line rather than as a shell that
//  merely looks right. No repair layer runs here; nothing types into these surfaces.
//

import AppKit
import Foundation
import Testing

@testable import WorkspaceManager

@Suite("Ghostty surface spawn contract", .serialized)
@MainActor
struct GhosttySurfaceSpawnContractTests {
    private static let spawnTimeout: TimeInterval = 60

    @Test("Every surface in a burst starts with its own command, environment, directory and input")
    func burstSurfacesEachGetTheirLaunchConfig() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }

        let launches = try (0..<8).map { index in try scratch.launch(index) }
        let views = try launches.map { try harness.makeSurface($0.config) }

        let arrived = await BareGhosttyApp.poll(timeout: Self.spawnTimeout) {
            launches.allSatisfy { $0.report() != nil }
        }
        let reports = launches.map { ($0, $0.report()) }
        #expect(arrived, "children that never reported: \(scratch.missing(reports))")
        for (launch, report) in reports {
            #expect(report == launch.expected, "surface \(launch.index)")
        }
        for view in views { harness.free(view) }
    }

    @Test("A surface created right after another is freed still gets its own launch config")
    func surfaceAfterFreeGetsItsLaunchConfig() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let harness = try BareGhosttyApp()
        defer { harness.shutdown() }

        let first = try scratch.launch(0)
        let firstView = try harness.makeSurface(first.config)
        #expect(await BareGhosttyApp.poll(timeout: Self.spawnTimeout) { first.report() != nil })
        harness.free(firstView)

        let second = try scratch.launch(1)
        let secondView = try harness.makeSurface(second.config)
        #expect(await BareGhosttyApp.poll(timeout: Self.spawnTimeout) { second.report() != nil })
        #expect(second.report() == second.expected)
        harness.free(secondView)
    }

    @Test("Surfaces built through the app's own marshalling run their command with its environment")
    func appMarshalledSurfacesRunTheirCommand() async throws {
        BareGhosttyApp.prepareProcess()
        let scratch = try Scratch()
        defer { scratch.remove() }
        let expectedPath = try #require(GhosttyTerminalConfig(customCommand: "true").environmentVariables["PATH"])

        let outputs = (0..<6).map { scratch.root.appendingPathComponent("app-\($0).out") }
        var views: [GhosttySurfaceView] = outputs.map { output in
            GhosttySurfaceView(customCommand: Scratch.reportingCommand(fields: ["$PATH"], output: output))
        }
        #expect(views.allSatisfy { $0.surface != nil })

        let arrived = await BareGhosttyApp.poll(timeout: Self.spawnTimeout) {
            outputs.allSatisfy { Scratch.lines(at: $0) != nil }
        }
        #expect(
            arrived,
            "children that never reported: \(outputs.filter { Scratch.lines(at: $0) == nil }.map(\.lastPathComponent))")
        for output in outputs {
            #expect(Scratch.lines(at: output) == [expectedPath], "\(output.lastPathComponent)")
        }
        views.removeAll()
    }
}

/// A temporary directory of per-surface launch specs and the reports their children write.
private struct Scratch {
    struct Launch {
        let index: Int
        let config: BareSurfaceConfig
        let output: URL
        let expected: [String]

        func report() -> [String]? { Scratch.lines(at: output) }
    }

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spawn-contract-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Surface `index` reads one line of initial input, then reports it, its own token
    /// from the environment, and its working directory.
    func launch(_ index: Int) throws -> Launch {
        let directory = root.appendingPathComponent("cwd-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("surface-\(index).out")
        let token = "token-\(index)-\(UUID().uuidString.prefix(8))"
        let input = "input-\(index)"
        return Launch(
            index: index,
            config: BareSurfaceConfig(
                command: Self.reportingCommand(
                    fields: ["$line", "$WS_SPAWN_TOKEN", "$(pwd -P)"], output: output, readsLine: true),
                workingDirectory: directory.path,
                environment: ["WS_SPAWN_TOKEN": token],
                initialInput: input + "\n"
            ),
            output: output,
            expected: [input, token, directory.path]
        )
    }

    func missing(_ reports: [(Launch, [String]?)]) -> [Int] {
        reports.filter { $0.1 == nil }.map(\.0.index)
    }

    /// A command libghostty runs as `bash -c "exec -l <command>"`. `--noprofile` keeps the
    /// login-mode bash from sourcing profiles that could rewrite the environment under test;
    /// the report lands by rename, so a reader never sees half a file.
    static func reportingCommand(fields: [String], output: URL, readsLine: Bool = false) -> String {
        let read = readsLine ? "IFS= read -r line; " : ""
        let format = Array(repeating: "%s", count: fields.count).joined(separator: "\\n") + "\\n"
        let values = fields.map { "\"\($0)\"" }.joined(separator: " ")
        let script = "\(read)printf \"\(format)\" \(values) > \"$0.tmp\" && mv \"$0.tmp\" \"$0\""
        return "/bin/bash --noprofile --norc -c '\(script)' \(output.path)"
    }

    static func lines(at url: URL) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }
}

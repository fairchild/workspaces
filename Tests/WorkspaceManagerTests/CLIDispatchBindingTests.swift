//
//  CLIDispatchBindingTests.swift
//  WorkspaceManagerTests
//
//  Binds the alias spellings the smoke scripts type — `workspaces workspace select`,
//  `workspaces window snapshot`, `workspaces wait` — to the handlers they must reach, by
//  running the real `workspaces` binary (found and launched by `Helpers/CLIBinary`).
//  `CLIVerbCatalogTests` proves canonicalization is correct in isolation; only this proves
//  the dispatch path actually calls it.
//

import Foundation
import Testing

@Suite("CLI dispatch binding")
struct CLIDispatchBindingTests {
    /// Runs the CLI with its state store redirected into a scratch directory, so dispatch is
    /// exercised without reading or writing the developer's real CLI state.
    private func runCLI(_ arguments: [String]) throws -> CLIBinary.Invocation {
        let binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-dispatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        return try CLIBinary.run(
            binary,
            arguments: arguments,
            currentDirectory: scratch,
            environment: ["XDG_CONFIG_HOME": scratch.path]
        )
    }

    /// Both invocations stop in argument parsing, before any socket or credential read, so
    /// the assertion is about which handler received them and nothing else.
    @Test(
        "Smoke-script alias spellings reach their grouped handlers",
        arguments: [
            (["workspace", "select"], "Usage: workspaces automation workspace select"),
            (["window", "snapshot"], "Usage: workspaces automation window snapshot --out <path>"),
            // #1265 shipped `wait`/`focus` at top level and api-select-smoke.sh types
            // `workspaces wait`; grouping them under `automation` must not move that spelling.
            (["wait"], "Usage: workspaces automation wait --for"),
            (["focus", "--bogus"], "Usage: workspaces automation focus [--json]"),
        ]
    )
    func aliasSpellingsDispatchToHandlers(arguments: [String], expected: String) throws {
        let result = try runCLI(arguments)
        #expect(result.stderr.contains(expected))
        // The failure mode this guards: dispatching the raw vector instead of the
        // canonicalized one leaves 'workspace'/'window' unknown at top level.
        #expect(!result.stderr.contains("Unknown command"))
        #expect(result.status == 1)
    }

    @Test(
        "Alias and grouped spellings produce identical output",
        arguments: [["workspace", "select"], ["window", "snapshot"], ["wait"], ["focus", "--bogus"]]
    )
    func aliasAndGroupedSpellingsAgree(arguments: [String]) throws {
        let alias = try runCLI(arguments)
        let grouped = try runCLI(["automation"] + arguments)
        #expect(alias.stderr == grouped.stderr)
        #expect(alias.stdout == grouped.stdout)
        #expect(alias.status == grouped.status)
    }

    @Test("An unclaimed first argument still fails as an unknown command")
    func unknownVerbStaysUnknown() throws {
        let result = try runCLI(["nonsense", "select"])
        #expect(result.stderr.contains("Unknown command 'nonsense'"))
        #expect(result.status == 1)
    }
}

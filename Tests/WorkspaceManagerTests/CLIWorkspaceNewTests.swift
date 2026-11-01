//
//  CLIWorkspaceNewTests.swift
//  WorkspaceManagerTests
//
//  Drives `ws new --from-ref` through the real binary against a real remote, because the
//  property that matters is about three repositories at once: a workspace starts from what
//  the remote has now, while the base clone it was created from stays where it was.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLI ws new", .serialized)
struct CLIWorkspaceNewTests {

    /// A remote, a clone of it, and one commit the clone has not fetched.
    private struct Fixture {
        let binary: URL
        let root: URL
        let originCommit: String
        let cloneCommit: String

        var clone: URL { root.appendingPathComponent("repo") }

        var environment: [String: String] {
            [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "WORKSPACES_SYNTHETIC_ROOT": root.appendingPathComponent("workspaces").path,
            ]
        }

        func run(_ arguments: [String]) throws -> CLIBinary.Invocation {
            try CLIBinary.run(binary, arguments: arguments, currentDirectory: root, environment: environment)
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeFixture() throws -> Fixture {
        let binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-new-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        let origin = root.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)

        do {
            try Self.git(["init", "-q", "-b", "main", "."], at: origin)
            try Self.git(["commit", "-q", "--allow-empty", "-m", "first"], at: origin)
            try Self.git(["clone", "-q", origin.path, "repo"], at: root)
            let clone = root.appendingPathComponent("repo")
            let cloneCommit = try Self.git(["rev-parse", "HEAD"], at: clone)
            try Self.git(["commit", "-q", "--allow-empty", "-m", "second"], at: origin)
            let originCommit = try Self.git(["rev-parse", "HEAD"], at: origin)

            let fixture = Fixture(
                binary: binary,
                root: root,
                originCommit: originCommit,
                cloneCommit: cloneCommit
            )
            let added = try fixture.run(["repo", "add", clone.path])
            try #require(added.status == 0)
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("--from-ref starts from what the remote has now, and leaves the base clone alone")
    func fromRefFetchesFirst() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "fresh", "--from-ref", "origin/main", "--json"])
        #expect(created.status == 0)
        let result = try JSONDecoder().decode(WorkspaceNewResult.self, from: Data(created.stdout.utf8))

        #expect(result.fromRef == "origin/main")
        #expect(result.baseCommit == fixture.originCommit)
        #expect(result.branch == "workspace/fresh")
        let workspace = URL(fileURLWithPath: result.path)
        #expect(try Self.git(["rev-parse", "HEAD"], at: workspace) == fixture.originCommit)
        #expect(try Self.git(["rev-parse", "HEAD"], at: fixture.clone) == fixture.cloneCommit)
    }

    @Test("Without --from-ref a workspace still branches from the base clone's HEAD")
    func defaultBaseIsUnchanged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "plain", "--json"])
        #expect(created.status == 0)
        let result = try JSONDecoder().decode(WorkspaceNewResult.self, from: Data(created.stdout.utf8))

        #expect(result.fromRef == nil)
        #expect(result.baseCommit == fixture.cloneCommit)
    }

    @Test("The human output names the base it started from")
    func humanOutputNamesTheBase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "fresh", "--from-ref", "origin/main"])
        #expect(created.status == 0)
        #expect(created.stdout.contains("Base: origin/main (\(fixture.originCommit))"))
    }

    @Test("A ref the remote does not have fails and leaves no workspace behind")
    func missingRefFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "lost", "--from-ref", "origin/absent"])
        #expect(created.status == 1)
        let workspace = fixture.root.appendingPathComponent("workspaces/repo/lost")
        #expect(!FileManager.default.fileExists(atPath: workspace.path))
    }

    @Test(
        "A malformed ref is refused in the flag's own words",
        arguments: ["", " origin/main", "origin/main "]
    )
    func malformedRefIsRefused(ref: String) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "bad", "--from-ref", ref])
        #expect(created.status == 1)
        #expect(created.stderr.contains("--from-ref"))
    }

    @Test("--from-ref needs a value")
    func missingValue() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "bad", "--from-ref"])
        #expect(created.status == 1)
        #expect(created.stderr.contains("Missing value for --from-ref"))
    }

    @Test("A name of several words still joins into one")
    func multiWordName() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let created = try fixture.run(["ws", "new", "repo", "two", "words", "--json"])
        #expect(created.status == 0)
        let result = try JSONDecoder().decode(WorkspaceNewResult.self, from: Data(created.stdout.utf8))
        #expect(result.workspace.hasPrefix("repo/two"))
    }
}

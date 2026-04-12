//
//  HostTerminalDefaultsTests.swift
//  WorkspaceManagerTests
//
//  Tests host terminal launch directory fallback order.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("HostTerminalDefaults", .serialized)
struct HostTerminalDefaultsTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostTerminalDefaultsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Prefers ~/code when present")
    func prefersTildeCodeDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tildeHome = root.appendingPathComponent("tilde-home", isDirectory: true)
        let envHome = root.appendingPathComponent("env-home", isDirectory: true)

        try FileManager.default.createDirectory(
            at: tildeHome.appendingPathComponent("code", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: envHome.appendingPathComponent("code", isDirectory: true), withIntermediateDirectories: true)

        let resolved = HostTerminalDefaults.resolveDefaultWorkingDirectory(
            tildeHomeDirectory: tildeHome,
            environmentHome: envHome.path
        )

        #expect(resolved == tildeHome.appendingPathComponent("code", isDirectory: true).standardizedFileURL)
    }

    @Test("Falls back to $HOME/code when ~/code is missing")
    func fallsBackToEnvironmentCodeDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tildeHome = root.appendingPathComponent("tilde-home", isDirectory: true)
        let envHome = root.appendingPathComponent("env-home", isDirectory: true)

        try FileManager.default.createDirectory(at: tildeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: envHome.appendingPathComponent("code", isDirectory: true), withIntermediateDirectories: true)

        let resolved = HostTerminalDefaults.resolveDefaultWorkingDirectory(
            tildeHomeDirectory: tildeHome,
            environmentHome: envHome.path
        )

        #expect(resolved == envHome.appendingPathComponent("code", isDirectory: true).standardizedFileURL)
    }

    @Test("Falls back to $HOME when code directories are missing")
    func fallsBackToEnvironmentHomeDirectory() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tildeHome = root.appendingPathComponent("tilde-home", isDirectory: true)
        let envHome = root.appendingPathComponent("env-home", isDirectory: true)

        try FileManager.default.createDirectory(at: tildeHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: envHome, withIntermediateDirectories: true)

        let resolved = HostTerminalDefaults.resolveDefaultWorkingDirectory(
            tildeHomeDirectory: tildeHome,
            environmentHome: envHome.path
        )

        #expect(resolved == envHome.standardizedFileURL)
    }

    @Test("Falls back to ~/ when HOME is unavailable")
    func fallsBackToTildeHomeWhenEnvironmentHomeUnavailable() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let tildeHome = root.appendingPathComponent("tilde-home", isDirectory: true)
        try FileManager.default.createDirectory(at: tildeHome, withIntermediateDirectories: true)

        let resolved = HostTerminalDefaults.resolveDefaultWorkingDirectory(
            tildeHomeDirectory: tildeHome,
            environmentHome: nil
        )

        #expect(resolved == tildeHome.standardizedFileURL)
    }
}

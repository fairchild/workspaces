//
//  TestGitRepository.swift
//  WorkspaceManagerTests
//
//  Test fixture for creating temporary git repositories
//

import Foundation

/// Creates a real temporary git repository for testing
final class TestGitRepository {
    let url: URL

    private init(url: URL) {
        self.url = url
    }

    /// Create a new temporary git repository
    static func create() throws -> TestGitRepository {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceManagerTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Initialize git repo
        try run(["git", "init"], at: tempDir)
        try run(["git", "config", "user.email", "test@example.com"], at: tempDir)
        try run(["git", "config", "user.name", "Test User"], at: tempDir)

        return TestGitRepository(url: tempDir)
    }

    /// Create a file in the repository
    func createFile(_ relativePath: String, content: String = "") throws {
        let filePath = url.appendingPathComponent(relativePath)
        let parentDir = filePath.deletingLastPathComponent()

        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try content.write(to: filePath, atomically: true, encoding: .utf8)
    }

    /// Stage all changes and commit
    func commit(message: String) throws {
        try Self.run(["git", "add", "-A"], at: url)
        try Self.run(["git", "commit", "-m", message], at: url)
    }

    /// Create a directory (e.g., for testing ignored dirs)
    func createDirectory(_ relativePath: String) throws {
        let dirPath = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
    }

    /// Delete a file
    func deleteFile(_ relativePath: String) throws {
        let filePath = url.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: filePath)
    }

    /// Modify a file
    func modifyFile(_ relativePath: String, content: String) throws {
        let filePath = url.appendingPathComponent(relativePath)
        try content.write(to: filePath, atomically: true, encoding: .utf8)
    }

    /// Add a remote
    func addRemote(_ name: String, url: String) throws {
        try Self.run(["git", "remote", "add", name, url], at: self.url)
    }

    /// Create and switch to a new branch
    func createBranch(_ name: String) throws {
        try Self.run(["git", "checkout", "-b", name], at: url)
    }

    /// Create a detached HEAD state
    func detachHead() throws {
        let head = try Self.runOutput(["git", "rev-parse", "HEAD"], at: url)
        try Self.run(["git", "checkout", head.trimmingCharacters(in: .whitespacesAndNewlines)], at: url)
    }

    /// Cleanup the temporary repository
    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private Helpers

    private static func run(_ args: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw TestError.commandFailed(args.joined(separator: " "))
        }
    }

    private static func runOutput(_ args: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    enum TestError: Error {
        case commandFailed(String)
    }
}

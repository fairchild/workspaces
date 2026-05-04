//
//  TerminalContinuityManifestTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalContinuityManifest")
struct TerminalContinuityManifestTests {
    @Test("Manifest round trips terminal continuity fields")
    func manifestRoundTrips() throws {
        let targetID = UUID()
        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: targetID,
            rootURL: URL(fileURLWithPath: "/tmp/repo/workspace", isDirectory: true),
            launchURL: URL(fileURLWithPath: "/tmp/repo/workspace/subdir", isDirectory: true),
            terminalMode: .tmuxPerSession,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let decoded = try #require(TerminalContinuityManifest.decode(from: manifest.rawValue))

        #expect(decoded == manifest)
        #expect(decoded.targetKind == .workspace)
        #expect(decoded.targetID == targetID)
        #expect(decoded.terminalMode == .tmuxPerSession)
        #expect(decoded.tmuxSessionName.hasPrefix("wm-subdir-"))
    }

    @Test("Launch directory restores only for matching target")
    func launchDirectoryRequiresMatchingTarget() throws {
        let root = try temporaryDirectory()
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let targetID = UUID()
        let manifest = TerminalContinuityManifest(
            targetKind: .repo,
            targetID: targetID,
            rootURL: root,
            launchURL: child,
            terminalMode: .tmuxPerSession
        )

        #expect(
            manifest.launchDirectory(
                for: .repo,
                targetID: targetID,
                rootURL: root
            )?.path == child.path
        )
        #expect(
            manifest.launchDirectory(
                for: .workspace,
                targetID: targetID,
                rootURL: root
            ) == nil
        )
        #expect(
            manifest.launchDirectory(
                for: .repo,
                targetID: UUID(),
                rootURL: root
            ) == nil
        )
    }

    @Test("Missing launch directory falls back to root")
    func missingLaunchDirectoryFallsBackToRoot() throws {
        let root = try temporaryDirectory()
        let missingChild = root.appendingPathComponent("missing", isDirectory: true)
        let targetID = UUID()
        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: targetID,
            rootURL: root,
            launchURL: missingChild,
            terminalMode: .ghosttyManagedSplits
        )

        let restored = try #require(
            manifest.launchDirectory(
                for: .workspace,
                targetID: targetID,
                rootURL: root
            )
        )

        #expect(restored.path == root.path)
    }

    @Test("Launch directory outside root is rejected")
    func launchDirectoryOutsideRootIsRejected() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let targetID = UUID()
        let manifest = TerminalContinuityManifest(
            targetKind: .repo,
            targetID: targetID,
            rootURL: root,
            launchURL: outside,
            terminalMode: .tmuxPerSession
        )

        let restored = try #require(
            manifest.launchDirectory(
                for: .repo,
                targetID: targetID,
                rootURL: root
            )
        )

        #expect(restored.path == root.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalContinuityManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

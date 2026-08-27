//
//  TerminalContinuityManifestTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing
import WorkspaceManagerCore

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

    /// A restore that reattached to a probed name carries an override. Dropping it on the way
    /// through the manifest would retarget the surface at its directory derivation, which on a
    /// shared tmux socket can be a different live session (#1374).
    @Test("A session's chosen tmux name survives the manifest")
    func manifestKeepsTmuxSessionNameOverride() throws {
        let directory = try temporaryDirectory()
        let session = HostTerminalSession(
            key: .hostPath(directory.path),
            directory: directory,
            tmuxSessionNameOverride: "wm-alpha-probed"
        )
        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: UUID(),
            rootURL: directory,
            launchURL: directory,
            terminalMode: .tmuxPerSession,
            sessions: [session],
            activeSessionID: session.id
        )

        let decoded = try #require(TerminalContinuityManifest.decode(from: manifest.rawValue))
        let restored = try #require(decoded.hostSessionSnapshot()?.sessions.first)

        #expect(restored.tmuxSessionNameOverride == "wm-alpha-probed")
        #expect(restored.effectiveTmuxSessionName == "wm-alpha-probed")
    }

    /// Manifests written before the override was persisted decode without it, and their
    /// sessions fall back to the directory derivation they were already using.
    @Test("A manifest without the tmux name field still decodes")
    func manifestWithoutOverrideFieldDecodes() throws {
        let directory = try temporaryDirectory()
        let session = HostTerminalSession(key: .hostPath(directory.path), directory: directory)
        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: UUID(),
            rootURL: directory,
            launchURL: directory,
            terminalMode: .tmuxPerSession,
            sessions: [session],
            activeSessionID: session.id
        )
        let withoutField = manifest.rawValue.replacingOccurrences(
            of: "\"tmuxSessionNameOverride\"",
            with: "\"unusedLegacyField\""
        )

        let decoded = try #require(TerminalContinuityManifest.decode(from: withoutField))
        let restored = try #require(decoded.hostSessionSnapshot()?.sessions.first)

        #expect(restored.tmuxSessionNameOverride == nil)
        #expect(restored.effectiveTmuxSessionName == session.effectiveTmuxSessionName)
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

    @Test("Host session snapshot restores tabs and active tab by scope")
    func hostSessionSnapshotRestoresTabsByScope() throws {
        let home = try temporaryDirectory()
        let repo = try temporaryDirectory()
        let homeSession = HostTerminalSession(key: .defaultHome, directory: home)
        let repoSession = HostTerminalSession(key: .repoPath(repo.path), directory: repo)
        let secondRepoSession = HostTerminalSession(key: .repoPath(repo.path), directory: repo)

        let manifest = TerminalContinuityManifest(
            targetKind: .repo,
            targetID: UUID(),
            rootURL: repo,
            launchURL: repo,
            terminalMode: .ghosttyManagedSplits,
            sessions: [homeSession, repoSession, secondRepoSession],
            activeSessionID: secondRepoSession.id,
            activeSessionIDByScopeKey: [
                .defaultHome: homeSession.id,
                .repoPath(repo.path): secondRepoSession.id,
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let decoded = try #require(TerminalContinuityManifest.decode(from: manifest.rawValue))
        let snapshot = try #require(decoded.hostSessionSnapshot())

        #expect(snapshot.sessions.map(\.id) == [homeSession.id, repoSession.id, secondRepoSession.id])
        #expect(snapshot.activeSessionID == secondRepoSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.defaultHome] == homeSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.repoPath(repo.path)] == secondRepoSession.id)
    }

    @Test("Host session snapshot skips provider-backed command sessions")
    func hostSessionSnapshotSkipsProviderBackedCommandSessions() throws {
        let home = try temporaryDirectory()
        let remoteWorkingDirectory = try temporaryDirectory()
        let homeSession = HostTerminalSession(key: .defaultHome, directory: home)
        let remoteSession = HostTerminalSession(
            key: .backendSession(providerID: "lume", instanceID: "vm-123"),
            directory: remoteWorkingDirectory,
            customCommand: "/usr/local/bin/lume ssh vm-123"
        )

        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: UUID(),
            rootURL: home,
            launchURL: home,
            terminalMode: .ghosttyManagedSplits,
            sessions: [homeSession, remoteSession],
            activeSessionID: remoteSession.id,
            activeSessionIDByScopeKey: [
                .defaultHome: homeSession.id,
                .backendSession(providerID: "lume", instanceID: "vm-123"): remoteSession.id,
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let snapshot = try #require(manifest.hostSessionSnapshot())

        #expect(snapshot.sessions.map(\.id) == [homeSession.id])
        #expect(snapshot.activeSessionID == homeSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.defaultHome] == homeSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.backendSession(providerID: "lume", instanceID: "vm-123")] == nil)
    }

    @Test("Host session snapshot excludes archived workspace scopes")
    func hostSessionSnapshotExcludesArchivedWorkspaceScopes() throws {
        let home = try temporaryDirectory()
        let workspace = try temporaryDirectory()
        let homeSession = HostTerminalSession(key: .defaultHome, directory: home)
        let workspaceSession = HostTerminalSession(key: .hostPath(workspace.path), directory: workspace)
        let secondWorkspaceSession = HostTerminalSession(key: .hostPath(workspace.path), directory: workspace)

        let manifest = TerminalContinuityManifest(
            targetKind: .workspace,
            targetID: UUID(),
            rootURL: workspace,
            launchURL: workspace,
            terminalMode: .ghosttyManagedSplits,
            sessions: [homeSession, workspaceSession, secondWorkspaceSession],
            activeSessionID: secondWorkspaceSession.id,
            activeSessionIDByScopeKey: [
                .defaultHome: homeSession.id,
                .hostPath(workspace.path): secondWorkspaceSession.id,
            ],
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let snapshot = try #require(
            manifest.hostSessionSnapshot(excludingScopeKeys: [.hostPath(workspace.path)])
        )

        #expect(snapshot.sessions.map(\.id) == [homeSession.id])
        #expect(snapshot.activeSessionID == homeSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.defaultHome] == homeSession.id)
        #expect(snapshot.activeSessionIDByScopeKey[.hostPath(workspace.path)] == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalContinuityManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

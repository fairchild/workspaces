import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TerminalRestoreTargetResolver")
struct TerminalRestoreTargetResolverTests {
    private static let index = RestoreTargetIndex(
        homeDirectoryPath: "/Users/me",
        repos: [RestoreTargetIndex.Entry(normalizedPath: "/code/app", rootPath: "/code/app")],
        // Workspaces are pre-filtered to non-archived by the builder, so an
        // archived workspace simply isn't present here.
        workspaces: [RestoreTargetIndex.Entry(normalizedPath: "/code/app/wt", rootPath: "/code/app/wt")]
    )

    // Identity normalizer keeps tests hermetic (no filesystem/symlink access).
    private func makeResolver(
        normalizePath: @escaping @Sendable (String) -> String = { $0 }
    ) -> TerminalRestoreTargetResolver {
        TerminalRestoreTargetResolver(index: Self.index, normalizePath: normalizePath)
    }

    private func row(targetKind: String, targetPath: String?) -> TerminalSessionContinuityRow {
        TerminalSessionContinuityRow(
            hostSessionID: UUID(),
            sessionKey: "k",
            targetKind: targetKind,
            targetID: nil,
            targetPath: targetPath,
            backendIdentifier: nil,
            backendInstanceID: nil,
            directoryPath: targetPath ?? "/",
            terminalMode: "ghostty_managed_splits",
            tmuxSessionName: nil,
            customCommandPresent: false,
            isActive: true,
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: Date(timeIntervalSince1970: 0),
            endedAt: nil,
            agentSessionID: nil,
            agentKind: nil,
            agentRunState: nil,
            agentCwd: nil,
            agentModelDisplayName: nil,
            agentEventAt: nil
        )
    }

    @Test("A repo row matching a live repo resolves to a repo target")
    func repoMatchResolves() throws {
        let resolved = try #require(makeResolver().resolve(row(targetKind: "repo", targetPath: "/code/app")))
        #expect(resolved.key == .repoPath("/code/app"))
        #expect(resolved.rootDirectory == URL(fileURLWithPath: "/code/app"))
    }

    @Test("A repo row with no matching repo is dropped")
    func repoNoMatchDropped() {
        #expect(makeResolver().resolve(row(targetKind: "repo", targetPath: "/code/gone")) == nil)
    }

    @Test("A host_path row matching a non-archived workspace resolves")
    func workspaceMatchResolves() throws {
        let resolved = try #require(makeResolver().resolve(row(targetKind: "host_path", targetPath: "/code/app/wt")))
        #expect(resolved.key == .hostPath("/code/app/wt"))
        #expect(resolved.rootDirectory == URL(fileURLWithPath: "/code/app/wt"))
    }

    @Test("A host_path row whose workspace is archived (absent from the index) is dropped")
    func archivedWorkspaceDropped() {
        #expect(makeResolver().resolve(row(targetKind: "host_path", targetPath: "/code/archived")) == nil)
    }

    @Test("default_home always resolves, even against an empty index")
    func defaultHomeAlwaysResolves() throws {
        let emptyIndex = RestoreTargetIndex(homeDirectoryPath: "/Users/me", repos: [], workspaces: [])
        let resolver = TerminalRestoreTargetResolver(index: emptyIndex, normalizePath: { $0 })
        let resolved = try #require(resolver.resolve(row(targetKind: "default_home", targetPath: nil)))
        #expect(resolved.key == .defaultHome)
        #expect(resolved.rootDirectory == URL(fileURLWithPath: "/Users/me"))
    }

    @Test("Backend sessions and unknown kinds are dropped conservatively")
    func backendAndUnknownDropped() {
        #expect(makeResolver().resolve(row(targetKind: "backend_session", targetPath: nil)) == nil)
        #expect(makeResolver().resolve(row(targetKind: "something_new", targetPath: "/code/app")) == nil)
    }

    @Test("A missing target path never matches")
    func missingTargetPathDropped() {
        #expect(makeResolver().resolve(row(targetKind: "repo", targetPath: nil)) == nil)
    }

    @Test("Normalization is applied before matching")
    func normalizationApplied() throws {
        // A trailing-slash variant matches once the injected normalizer strips it.
        let resolver = makeResolver(normalizePath: { path in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        })
        let resolved = try #require(resolver.resolve(row(targetKind: "repo", targetPath: "/code/app/")))
        #expect(resolved.key == .repoPath("/code/app"))
    }
}

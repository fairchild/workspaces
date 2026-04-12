import Foundation
import Testing

@testable import WorkspaceManager

@Suite("AppBuildIdentity")
struct AppBuildIdentityTests {
    @Test("SwiftPM debug executable resolves back to the source root")
    func swiftPMDebugExecutableResolvesSourceRoot() {
        let bundleURL = URL(
            fileURLWithPath: "/Users/fairchild/.codex/worktrees/15a4/workspaces"
        )
        let executableURL = URL(
            fileURLWithPath:
                "/Users/fairchild/.codex/worktrees/15a4/workspaces/.build/arm64-apple-macosx/debug/WorkspaceManager"
        )

        let identity = AppBuildIdentity.resolve(
            bundleURL: bundleURL,
            executableURL: executableURL,
            isDebugConfiguration: false
        )

        #expect(identity.channel == .development)
        #expect(identity.fullPath == "/Users/fairchild/.codex/worktrees/15a4/workspaces")
        #expect(identity.displayPath == "worktrees/15a4/workspaces")
        #expect(identity.launchPath == executableURL.path)
    }

    @Test("Installed app stays unbadged outside debug builds")
    func installedAppStaysUnbadged() {
        let bundleURL = URL(
            fileURLWithPath: "/Applications/WorkspaceManager.app"
        )
        let executableURL = URL(
            fileURLWithPath: "/Applications/WorkspaceManager.app/Contents/MacOS/WorkspaceManager"
        )

        let identity = AppBuildIdentity.resolve(
            bundleURL: bundleURL,
            executableURL: executableURL,
            isDebugConfiguration: false
        )

        #expect(identity.channel == .installed)
        #expect(identity.displayPath == nil)
        #expect(identity.fullPath == bundleURL.path)
        #expect(identity.launchPath == bundleURL.path)
    }

    @Test("Non-worktree paths compact to the trailing components")
    func nonWorktreePathsCompactToTrailingComponents() {
        let label = AppBuildIdentity.compactDisplayPath(
            for: URL(fileURLWithPath: "/Users/fairchild/DerivedData/WorkspaceManager.app")
        )

        #expect(label == "fairchild/DerivedData/WorkspaceManager.app")
    }
}

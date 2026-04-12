import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceDeepLink")
struct WorkspaceDeepLinkTests {
    @Test("Parses cwd and repo root from focus URL")
    func parsesCWDAndRepoRoot() {
        let url = URL(
            string:
                "workspaces://focus?cwd=%2Ftmp%2Fproject%2FSources&repo_root=%2Ftmp%2Fproject&source=cli"
        )!

        let deepLink = WorkspaceDeepLink(url: url)

        #expect(deepLink?.cwd == "/tmp/project/Sources")
        #expect(deepLink?.repoRoot == "/tmp/project")
        #expect(deepLink?.source == "cli")
    }

    @Test("Rejects links with relative cwd")
    func rejectsRelativeCWD() {
        let url = URL(string: "workspaces://focus?cwd=../etc")!

        #expect(WorkspaceDeepLink(url: url) == nil)
    }

    @Test("Rejects links with missing cwd")
    func rejectsMissingCWD() {
        let url = URL(string: "workspaces://focus?repo_root=%2Ftmp%2Fproject")!

        #expect(WorkspaceDeepLink(url: url) == nil)
    }

    @Test("Rejects unsupported scheme and host")
    func rejectsUnsupportedSchemeAndHost() {
        let wrongScheme = URL(string: "https://focus?cwd=%2Ftmp%2Fproject")!
        let wrongHost = URL(string: "workspaces://open?cwd=%2Ftmp%2Fproject")!

        #expect(WorkspaceDeepLink(url: wrongScheme) == nil)
        #expect(WorkspaceDeepLink(url: wrongHost) == nil)
    }

    @Test("Expands tilde cwd")
    func expandsTildeCWD() {
        let url = URL(string: "workspaces://focus?cwd=~%2Fproject")!
        let expectedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("project", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        let deepLink = WorkspaceDeepLink(url: url)

        #expect(deepLink?.cwd == expectedPath)
    }

    @Test("Focus link builder round-trips through parser")
    func focusLinkBuilderRoundTripsThroughParser() {
        let focusLink = WorkspacesFocusLink(
            cwd: "/tmp/project/Sources",
            repoRoot: "/tmp/project",
            source: "cli"
        )

        let deepLink = WorkspaceDeepLink(url: focusLink.url)

        #expect(deepLink?.cwd == "/tmp/project/Sources")
        #expect(deepLink?.repoRoot == "/tmp/project")
        #expect(deepLink?.source == "cli")
    }
}

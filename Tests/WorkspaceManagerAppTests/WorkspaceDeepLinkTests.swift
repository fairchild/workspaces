import Foundation
import Testing

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
}

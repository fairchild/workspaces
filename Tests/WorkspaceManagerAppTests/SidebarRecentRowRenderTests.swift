import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Recent arrangement row render")
struct SidebarRecentRowRenderTests {
    /// Renders the flat Recent rows — `repo / workspace` breadcrumb, activity dots, pane
    /// badges — under their bucket headers. Asserts a non-empty image (layout smoke) and,
    /// when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG for PR evidence without launching
    /// the app. The last row's repo name is long enough to show that the repo half truncates
    /// first while the workspace name stays whole.
    @Test("Recent rows render the repo breadcrumb and truncate the repo half first")
    func rendersRecentRows() throws {
        let bertramChat = repo("bertram-chat")
        let skills = repo("skills")
        let breadBuilder = repo("bread-builder")
        let verbose = repo("a-very-long-repository-name-that-cannot-fit")

        let list = VStack(alignment: .leading, spacing: 2) {
            bucketHeader("Today")
            row(workspace("feature-auth", in: bertramChat), repo: bertramChat, activity: .thinking, isSelected: true)
            bucketHeader("This Week")
            row(workspace("skills-v13", in: skills), repo: skills, activity: .live, paneCount: 3)
            row(workspace("refactor-state", in: bertramChat), repo: bertramChat)
            bucketHeader("Earlier")
            row(
                workspace("refactor-runtime", in: breadBuilder),
                repo: breadBuilder,
                activity: .errored(category: .toolFailure)
            )
            row(workspace("bugfix-422", in: verbose), repo: verbose)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: list)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)

        guard let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"],
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-recent-rows.png")
        try png.write(to: url)
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func workspace(_ name: String, in repo: Repo) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            gitBranch: "workspace/\(name)"
        )
    }

    private func bucketHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(
        _ workspace: Workspace,
        repo: Repo,
        activity: SidebarSessionActivity = .inactive,
        paneCount: Int = 0,
        isSelected: Bool = false
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: isSelected,
            sessionActivity: activity,
            paneCount: paneCount,
            repoContext: repo.name,
            isNested: false
        )
    }
}

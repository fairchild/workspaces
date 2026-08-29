import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Archived disclosure pill render")
struct SidebarArchivedPillRenderTests {
    /// Renders the archived disclosure in both of its states, each in the subtree it heads:
    /// collapsed under a repo whose live rows sit above it, and expanded with the archived
    /// rows it uncovers. Both appearances, so the pill's quiet fill and hairline can be
    /// checked against a light and a dark sidebar. Asserts a non-empty image (layout smoke)
    /// and, when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG per appearance for PR
    /// evidence without launching the app.
    @Test("The archived pill renders collapsed and expanded in both appearances")
    func rendersArchivedPill() throws {
        for (scheme, slug) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let renderer = ImageRenderer(content: subtrees(scheme: scheme))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)

            guard let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"],
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                continue
            }
            let url = URL(fileURLWithPath: dir)
                .appendingPathComponent("sidebar-archived-pill-\(slug).png")
            try png.write(to: url)
        }
    }

    private func subtrees(scheme: ColorScheme) -> some View {
        let bertramChat = repo("bertram-chat")
        let skills = repo("skills")

        return VStack(alignment: .leading, spacing: 2) {
            repoRow(bertramChat, workspaceCount: 2)
            workspaceRow(workspace("feature-auth", in: bertramChat), activity: .thinking)
            workspaceRow(workspace("bugfix-422", in: bertramChat))
            ArchivedDisclosureRow(count: 1, isExpanded: false, onToggle: {})

            repoRow(skills, workspaceCount: 0)
            ArchivedDisclosureRow(count: 3, isExpanded: true, onToggle: {})
            workspaceRow(archived("skills-v13", in: skills))
            workspaceRow(archived("skills-v12", in: skills))
            workspaceRow(archived("skills-v11", in: skills))
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
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

    private func archived(_ name: String, in repo: Repo) -> Workspace {
        let workspace = workspace(name, in: repo)
        workspace.status = .archived
        workspace.archivedAt = Date(timeIntervalSince1970: 1_755_864_000)
        return workspace
    }

    private func repoRow(_ repo: Repo, workspaceCount: Int) -> some View {
        RepoRow(
            repo: repo,
            activeWorkspaceCount: workspaceCount,
            sessionActivity: .inactive,
            paneCount: 0,
            isSelected: false,
            isExpanded: true,
            onToggleExpansion: {},
            onSelectRepo: {},
            onNewWorkspace: {},
            onNewWebView: {}
        )
    }

    private func workspaceRow(
        _ workspace: Workspace,
        activity: SidebarSessionActivity = .inactive
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            sessionActivity: activity,
            isNested: true
        )
    }
}

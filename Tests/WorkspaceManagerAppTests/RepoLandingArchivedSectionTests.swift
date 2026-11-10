import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// A repo overview folds archived workspaces under one collapsed Archived section, so the
/// header's count and the section's two states are what a reader sees of them.
@MainActor
@Suite("Repo overview archived section")
struct RepoLandingArchivedSectionTests {
    @Test(
        "The header counts live workspaces and names archived ones apart",
        arguments: [
            (1, 0, "1 workspace"),
            (3, 0, "3 workspaces"),
            (1, 30, "1 workspace · 30 archived"),
            (0, 2, "0 workspaces · 2 archived"),
        ]
    )
    func countSummary(active: Int, archived: Int, expected: String) {
        #expect(RepoLandingView.workspaceCountSummary(active: active, archived: archived) == expected)
    }

    /// Renders the section collapsed and expanded in both appearances. The overview itself sits
    /// in a ScrollView, which ImageRenderer draws blank, so this stages the section as the
    /// overview lays it out. Writes a PNG per appearance when `WORKSPACES_EVIDENCE_DIR` is set.
    @Test("The archived section renders collapsed and expanded in both appearances")
    func rendersArchivedSection() throws {
        for (scheme, slug) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let renderer = ImageRenderer(content: sections(scheme: scheme))
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
            try png.write(
                to: URL(fileURLWithPath: dir).appendingPathComponent("repo-overview-archived-\(slug).png")
            )
        }
    }

    private func sections(scheme: ColorScheme) -> some View {
        let repo = Repo(name: "bertram-chat", localPath: URL(fileURLWithPath: "/tmp/bertram-chat"))
        let archived = ["refactor-state", "spike-sync"].map { archivedWorkspace($0, in: repo) }

        return VStack(alignment: .leading, spacing: 26) {
            ArchivedSectionHeader(count: archived.count, isExpanded: false, onToggle: {})

            VStack(alignment: .leading, spacing: 14) {
                ArchivedSectionHeader(count: archived.count, isExpanded: true, onToggle: {})
                HStack(spacing: 16) {
                    ForEach(archived) { workspace in
                        WorkspaceCardView(workspace: workspace, agentStatus: .inactive, onSelect: {})
                            .frame(width: 250)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 580, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    }

    private func archivedWorkspace(_ name: String, in repo: Repo) -> Workspace {
        let workspace = Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            gitBranch: "workspace/\(name)"
        )
        workspace.status = .archived
        workspace.archivedAt = Date(timeIntervalSince1970: 1_755_864_000)
        return workspace
    }
}

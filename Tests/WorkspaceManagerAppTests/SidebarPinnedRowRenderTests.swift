import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Pinned section row render")
struct SidebarPinnedRowRenderTests {
    /// Renders the Pinned section above a Recent bucket — the two pinned rows carry their
    /// `repo / workspace` breadcrumb and the hover star (filled when pinned, hollow when
    /// not), and the bucket below holds only the unpinned rows. Asserts a non-empty image
    /// (layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG for PR
    /// evidence without launching the app.
    @Test("Pinned rows render above the buckets with the star affordance")
    func rendersPinnedSection() throws {
        let bertramChat = repo("bertram-chat")
        let skills = repo("skills")
        let breadBuilder = repo("bread-builder")

        let featureAuth = workspace("feature-auth", in: bertramChat, pinOrder: 0)
        let skillsV13 = workspace("skills-v13", in: skills, pinOrder: 1)

        let list = VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Pinned")
            row(featureAuth, repo: bertramChat, activity: .thinking, isSelected: true, isHovering: true)
            row(skillsV13, repo: skills, activity: .live, paneCount: 3)
            sectionHeader("Today")
            row(workspace("refactor-state", in: bertramChat), repo: bertramChat, isHovering: true)
            sectionHeader("Earlier")
            row(
                workspace("refactor-runtime", in: breadBuilder),
                repo: breadBuilder,
                activity: .errored(category: .toolFailure)
            )
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-pinned-rows.png")
        try png.write(to: url)
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func workspace(_ name: String, in repo: Repo, pinOrder: Int? = nil) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            gitBranch: "workspace/\(name)",
            pinOrder: pinOrder
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    /// `ImageRenderer` never delivers a hover event, so the star is forced visible by
    /// rendering the row's hovering state directly.
    private func row(
        _ workspace: Workspace,
        repo: Repo,
        activity: SidebarSessionActivity = .inactive,
        paneCount: Int = 0,
        isSelected: Bool = false,
        isHovering: Bool = false
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: isSelected,
            sessionActivity: activity,
            paneCount: paneCount,
            repoContext: repo.name,
            isNested: false,
            isPinned: workspace.isPinned,
            onTogglePin: {},
            revealsHoverActions: isHovering
        )
    }
}

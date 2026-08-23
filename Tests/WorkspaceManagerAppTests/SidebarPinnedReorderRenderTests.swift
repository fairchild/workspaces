//
//  SidebarPinnedReorderRenderTests.swift
//  WorkspaceManagerAppTests
//
//  Renders the Pinned section either side of a Move Up, so PR evidence shows the reorder
//  as the controller actually produces it rather than as a hand-arranged mock. Writes a PNG
//  when `WORKSPACES_EVIDENCE_DIR` is set; asserts the order and a non-empty image otherwise.
//

import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Pinned section reorder render")
struct SidebarPinnedReorderRenderTests {
    private let controller = SidebarPinController()

    @Test("Move Up on the second pinned row swaps the rendered order")
    func rendersReorderedPinnedSection() throws {
        let bertramChat = repo("bertram-chat")
        let skills = repo("skills")
        let featureAuth = workspace("feature-auth", in: bertramChat, pinOrder: 0)
        let skillsV13 = workspace("skills-v13", in: skills, pinOrder: 1)
        let all = [featureAuth, skillsV13]

        let before = controller.pinnedWorkspaces(in: all)
        #expect(before.map(\.name) == ["feature-auth", "skills-v13"])

        controller.move(skillsV13, by: -1, in: all)

        let after = controller.pinnedWorkspaces(in: all)
        #expect(after.map(\.name) == ["skills-v13", "feature-auth"])
        #expect(after.map(\.pinOrder) == [0, 1])

        let comparison = HStack(alignment: .top, spacing: 20) {
            column(
                "Before",
                caption: "Move Up on skills-v13 — disabled on feature-auth, the first row",
                rows: before
            )
            column("After", caption: "skills-v13 renumbered to pinOrder 0", rows: after)
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: comparison)
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-pinned-reorder.png")
        try png.write(to: url)
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func workspace(_ name: String, in repo: Repo, pinOrder: Int?) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            gitBranch: "workspace/\(name)",
            pinOrder: pinOrder
        )
    }

    private func column(_ title: String, caption: String, rows: [Workspace]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)
            Text("Pinned")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(rows) { workspace in
                row(workspace)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(width: 280, alignment: .leading)
    }

    /// `ImageRenderer` never delivers a hover event, so the star is forced visible the same
    /// way `SidebarPinnedRowRenderTests` does.
    private func row(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            sessionActivity: workspace.name == "feature-auth" ? .thinking : .live,
            paneCount: workspace.name == "feature-auth" ? 0 : 3,
            repoContext: workspace.sourceRepo?.name,
            isNested: false,
            isPinned: workspace.isPinned,
            onTogglePin: {},
            revealsHoverActions: true
        )
    }
}

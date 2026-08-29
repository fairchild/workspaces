import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Repo row render")
struct SidebarRepoRowRenderTests {
    /// Renders a column of repo rows — selected, collapsed with its count badge, carrying a
    /// live session, and the flat repo root the Recent arrangement reuses — in both
    /// appearances, so the identity glyph's fixed hue can be checked against a light and a
    /// dark sidebar. Asserts a non-empty image (layout smoke) and, when
    /// `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG per appearance for PR evidence without
    /// launching the app.
    @Test("Repo rows render their identity glyph in both appearances")
    func rendersRepoRows() throws {
        for (scheme, slug) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let renderer = ImageRenderer(content: rowList(scheme: scheme))
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
                .appendingPathComponent("sidebar-repo-rows-\(slug).png")
            try png.write(to: url)
        }
    }

    private func rowList(scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            row("workspaces", workspaceCount: 4, isSelected: true, isExpanded: true)
            row("bertram-chat", workspaceCount: 3)
            row("skills", workspaceCount: 2, activity: .active, paneCount: 3, isExpanded: true)
            row("bread-builder", workspaceCount: 1, activity: .thinking, isExpanded: true)
            row("dotclaude", workspaceCount: 7)
            row("folio", workspaceCount: 0, showsExpansion: false)
            row("a-very-long-repository-name-that-cannot-fit", workspaceCount: 5)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    }

    private func row(
        _ name: String,
        workspaceCount: Int,
        activity: SidebarSessionActivity = .inactive,
        paneCount: Int = 0,
        isSelected: Bool = false,
        isExpanded: Bool = false,
        showsExpansion: Bool = true
    ) -> some View {
        RepoRow(
            repo: Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)")),
            activeWorkspaceCount: workspaceCount,
            sessionActivity: activity,
            paneCount: paneCount,
            isSelected: isSelected,
            isExpanded: isExpanded,
            showsExpansion: showsExpansion,
            onToggleExpansion: {},
            onSelectRepo: {},
            onNewWorkspace: {},
            onNewWebView: {}
        )
    }
}

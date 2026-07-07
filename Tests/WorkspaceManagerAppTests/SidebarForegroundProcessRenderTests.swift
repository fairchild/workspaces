import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("SidebarInfoCard foreground-process render")
struct SidebarForegroundProcessRenderTests {
    /// Renders the hover card with plain tabs whose titles are the real foreground process
    /// names (`vim`, `python`) that tmux-mode detection resolves. Asserts a non-empty image
    /// (layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG for PR evidence
    /// without launching the app.
    @Test("Hover card renders real foreground process names for plain tabs")
    func rendersForegroundProcessNames() throws {
        let card = SidebarInfoCard(
            name: "my-repo",
            branch: "feature/foreground-detection",
            tabs: [
                SidebarTabSummary(id: UUID(), title: "vim"),
                SidebarTabSummary(id: UUID(), title: "python"),
            ]
        )
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: card)
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-foreground-process.png")
        try png.write(to: url)
    }
}

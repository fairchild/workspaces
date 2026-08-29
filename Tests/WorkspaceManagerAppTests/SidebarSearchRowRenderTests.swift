import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("Sidebar search row render")
struct SidebarSearchRowRenderTests {
    /// Renders the search row as the sidebar pins it — inside the chrome bar's insets, over
    /// the surface fill, above the rule that separates it from the list. Both appearances, so
    /// the field's quiet fill and hairline can be checked against a light and a dark sidebar.
    /// Asserts a non-empty image (layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set,
    /// writes a PNG per appearance for PR evidence without launching the app.
    @Test("The search row renders in both appearances")
    func rendersSearchRow() throws {
        for (scheme, slug) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let renderer = ImageRenderer(content: searchBar(scheme: scheme))
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
                .appendingPathComponent("sidebar-search-row-\(slug).png")
            try png.write(to: url)
        }
    }

    /// The hint is read from the shortcut catalog, not spelled out in the row, so the two
    /// cannot drift. Pinning the rendered chord here is what makes that a contract.
    @Test("The row advertises the chord the session switcher is actually bound to")
    func advertisesTheSwitcherChord() {
        #expect(AppChromeShortcut.workspaceSwitcher.keyboardGlyphs == "⌘P")
    }

    private func searchBar(scheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            SidebarSearchRow(onActivate: {})
                .padding(.horizontal, SidebarChrome.Metrics.chromeBarHorizontalPadding)
                .padding(.vertical, SidebarChrome.Metrics.chromeBarVerticalPadding)
                .background(SidebarChrome.Fill.surface)

            Divider()
        }
        .frame(width: 280, alignment: .leading)
        .background(SidebarChrome.Fill.surface)
        .environment(\.colorScheme, scheme)
    }
}

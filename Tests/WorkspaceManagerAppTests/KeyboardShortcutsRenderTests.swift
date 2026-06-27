import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("KeyboardShortcutsView render")
struct KeyboardShortcutsRenderTests {
    /// Renders the cheat-sheet to a non-empty image (a crash/layout smoke), and — when
    /// `WORKSPACES_EVIDENCE_DIR` is set — writes a PNG there for PR evidence without launching the app.
    @Test("Cheat-sheet renders to a non-empty image")
    func rendersNonEmpty() throws {
        let content =
            KeyboardShortcutsContent()
            .padding(24)
            .frame(width: 440, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("keyboard-shortcuts.png")
        try png.write(to: url)
    }
}

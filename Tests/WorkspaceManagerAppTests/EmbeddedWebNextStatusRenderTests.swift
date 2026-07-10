import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("EmbeddedWebNextStatusView render")
struct EmbeddedWebNextStatusRenderTests {
    /// Renders the embedded surface's non-webview states to non-empty images
    /// (a layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set, writes PNGs
    /// there for PR evidence without launching the app or a real server.
    @Test("Starting and failed panes render to non-empty images")
    func rendersStatusPanes() throws {
        try render(
            EmbeddedWebNextStatusView(state: .connecting),
            named: "embedded-webnext-starting.png"
        )
        try render(
            EmbeddedWebNextStatusView(
                state: .failed(
                    "Timed out after 180s waiting for web-next health on port 3140."
                )
            ),
            named: "embedded-webnext-failed.png"
        )
    }

    private func render(_ view: some View, named name: String) throws {
        let content =
            VStack(spacing: 0) {
                embeddedHeader
                Divider()
                view
            }
            .frame(width: 720, height: 460)
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
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    private var embeddedHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Text("Web Session")
                .font(.headline)
            Spacer(minLength: 0)
            Text("Close")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

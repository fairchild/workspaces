import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("DiffReviewView render")
struct DiffReviewRenderTests {
    /// Renders the native diff review surface for a sample UnifiedDiff to a non-empty image
    /// (layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG for PR evidence
    /// without launching the app.
    @Test("Diff review renders additions/removals/context to a non-empty image")
    func rendersDiff() throws {
        let diff = UnifiedDiff(
            path: "Sources/App/Feature.swift",
            hunks: [
                UnifiedDiff.Hunk(
                    oldStart: 10, oldCount: 4, newStart: 10, newCount: 5,
                    lines: [
                        UnifiedDiff.Line(kind: .context, content: "func greet(_ name: String) {"),
                        UnifiedDiff.Line(kind: .removed, content: "    print(\"hi \\(name)\")"),
                        UnifiedDiff.Line(kind: .added, content: "    let message = \"hello, \\(name)\""),
                        UnifiedDiff.Line(kind: .added, content: "    print(message)"),
                        UnifiedDiff.Line(kind: .context, content: "}"),
                    ]
                )
            ]
        )

        let view =
            DiffReviewView(diff: diff)
            .frame(width: 460, height: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("diff-review.png")
        try png.write(to: url)
    }
}

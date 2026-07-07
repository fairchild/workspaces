import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("SidebarInfoCard transcript-tail render")
struct SidebarTranscriptTailRenderTests {
    /// Renders the hover card for a single Claude Code agent tab carrying a resolved transcript
    /// tail (the last assistant message, #680). Asserts a non-empty image (layout smoke) and,
    /// when `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG for PR evidence without launching the app.
    @Test("Hover card renders the latest assistant message for a sole Claude Code agent")
    func rendersTranscriptTail() throws {
        let status = AgentSessionStatus(
            hostSessionID: UUID(),
            agentSessionID: "abc-123",
            kind: .claudeCode,
            cwd: "/Users/me/code",
            run: .runningTool(name: "Bash", detail: "swift test"),
            contextUsedPercent: 42,
            costUSD: 0.37,
            modelDisplayName: "Claude Opus"
        )
        let card = SidebarInfoCard(
            name: "feature-mux",
            branch: "claude/680-snippets",
            tabs: [
                SidebarTabSummary(
                    id: UUID(),
                    title: "Claude Code",
                    agentStatus: status,
                    transcriptTail:
                        "Wired the transcript tail into the hover card and added fixture-backed parse tests."
                )
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-transcript-tail.png")
        try png.write(to: url)
    }
}

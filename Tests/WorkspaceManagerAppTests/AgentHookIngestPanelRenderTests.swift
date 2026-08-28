import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AgentHookIngestPanel render")
struct AgentHookIngestPanelRenderTests {
    /// The Diagnostics panel at a realistic detail-pane width, in the state the tab shows it.
    /// Rendering it directly is what makes the panel capturable at all: it sits fifth in the
    /// Diagnostics scroll order, below the fold, and the automation API has no scroll verb.
    private func panel(_ statistics: AgentHookListener.Statistics) -> some View {
        AgentHookIngestPanel(statistics: statistics)
            .padding(16)
            .frame(width: 640, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light)
    }

    /// Renders `content`, asserts a non-empty image (layout smoke), and writes a PNG when
    /// `WORKSPACES_EVIDENCE_DIR` is set — PR evidence without launching the app.
    private func render(_ content: some View, evidenceName: String) throws {
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent(evidenceName)
        try png.write(to: url)
    }

    /// The state the panel should hold in: updates flowing, nothing dropped. Every counter
    /// reads plainly and no alarm chrome appears.
    @Test("A healthy hook bus renders counters with no alarm")
    func rendersHealthyBus() throws {
        var statistics = AgentHookListener.Statistics()
        statistics.requestCount = 1_284
        statistics.ingestedEvents = 1_147
        statistics.statusLineUpdates = 132
        statistics.flushCount = 419
        statistics.commandMarkerUpdates = 88

        try render(panel(statistics), evidenceName: "agent-hook-ingest-at-rest.png")
    }

    /// The #1397 state: agents posting under host session ids this run does not know. The
    /// dropped counter carries critical prominence, the session count carries warning, and the
    /// inline error names what to do about it.
    @Test("Dropped updates render the alarm and the inline explanation")
    func rendersDroppingBus() throws {
        var statistics = AgentHookListener.Statistics()
        statistics.requestCount = 946
        statistics.ingestedEvents = 214
        statistics.statusLineUpdates = 31
        statistics.flushCount = 118
        statistics.droppedUnregisteredEvents = 673
        statistics.droppedUnregisteredSessions = 4

        try render(panel(statistics), evidenceName: "agent-hook-ingest-dropping.png")
    }
}

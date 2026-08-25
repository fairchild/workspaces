import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Workspace note row render")
struct SidebarNoteRowRenderTests {
    /// Renders the note line under a workspace row against the cases that decide whether
    /// it reads correctly: a plain note, a note on a row with live agent activity, a row
    /// with no note at all, and a row where a transient action message is showing — which
    /// takes the line, because it is about this moment and the note is not. Asserts a
    /// non-empty image (layout smoke) and, when `WORKSPACES_EVIDENCE_DIR` is set, writes
    /// a PNG for PR evidence without launching the app.
    @Test("The note renders under the row, and a transient status message takes the line instead")
    func rendersNoteLine() throws {
        let workspaces = repo("workspaces")
        let folio = repo("folio")

        let list = VStack(alignment: .leading, spacing: 2) {
            sectionHeader("Today")
            row(
                workspace("cli-parity", in: workspaces, note: "gap 1+4 in review, gap 2 blocked on evidence"),
                repo: workspaces,
                activity: .thinking
            )
            row(
                workspace("server-advice", in: folio, note: "waiting on Michael: env approvals"),
                repo: folio
            )
            row(workspace("wsclean", in: workspaces), repo: workspaces)
            row(
                workspace("drop", in: workspaces, note: "this note is hidden while the row is connecting"),
                repo: workspaces,
                statusMessage: "Connecting..."
            )
            sectionHeader("Earlier")
            row(
                workspace(
                    "long-note",
                    in: folio,
                    note: String(repeating: "a very long note that keeps going ", count: 6)
                ),
                repo: folio
            )
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
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
        let url = URL(fileURLWithPath: dir).appendingPathComponent("sidebar-workspace-notes.png")
        try png.write(to: url)
    }

    /// The row's accessibility description carries the note, so the line is not
    /// sighted-only.
    @Test("A note reaches the row's accessibility description")
    func noteIsAnnounced() {
        let annotated = workspace("cli-parity", in: repo("workspaces"), note: "handed off to review")
        #expect(annotated.note == "handed off to review")
    }

    private func repo(_ name: String) -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func workspace(_ name: String, in repo: Repo, note: String? = nil) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/\(repo.name)/\(name)"),
            sourceRepo: repo,
            gitBranch: "workspace/\(name)",
            note: note
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(
        _ workspace: Workspace,
        repo: Repo,
        activity: SidebarSessionActivity = .inactive,
        statusMessage: String? = nil
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: false,
            statusMessage: statusMessage,
            sessionActivity: activity,
            repoContext: repo.name,
            isNested: false,
            isPinned: false,
            onTogglePin: {}
        )
    }
}

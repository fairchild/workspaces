import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("Active workspace card render")
struct SidebarActiveCardRenderTests {
    /// The clock every row in the sheet reads, so the elapsed times and ages below are the
    /// same in every run of this test and no timer is mounted in a still render.
    private static let now = Date(timeIntervalSince1970: 1_756_000_000)

    /// Renders the selected workspace row as the raised card it becomes, in the three run
    /// states worth telling apart at a glance — thinking, awaiting input, errored — each with
    /// its live status line, alongside the unselected rows the card has to read against.
    /// Both appearances, because a card lifted off a light sidebar and off a dark one are two
    /// different judgements. Asserts a non-empty image (layout smoke) and, when
    /// `WORKSPACES_EVIDENCE_DIR` is set, writes a PNG per appearance for PR evidence without
    /// launching the app.
    @Test("The selected row renders as a raised card with a live status line, both appearances")
    func rendersActiveCard() throws {
        for (scheme, slug) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let renderer = ImageRenderer(content: sheet(scheme: scheme))
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
                .appendingPathComponent("sidebar-active-card-\(slug).png")
            try png.write(to: url)
        }
    }

    private func sheet(scheme: ColorScheme) -> some View {
        let workspaces = repo("workspaces")
        let folio = repo("folio")

        return VStack(alignment: .leading, spacing: 2) {
            caption("Selected — thinking")
            selectedRow(
                workspace("design-refresh", in: workspaces, note: "hidden while the session runs"),
                activity: .thinking,
                live: live(.thinking, startedAt: Self.now.addingTimeInterval(-452)),
                age: 5 * 86_400
            )

            caption("Selected — awaiting input")
            selectedRow(
                workspace("cli-parity", in: workspaces),
                activity: .awaitingInput,
                live: live(
                    .awaitingInput(reason: .permissionPrompt),
                    startedAt: Self.now.addingTimeInterval(-3_782)
                ),
                age: 3 * 3_600
            )

            caption("Selected — errored")
            selectedRow(
                workspace("server-advice", in: folio),
                activity: .errored(category: .rateLimit),
                live: live(
                    .errored(category: .rateLimit, message: nil),
                    startedAt: Self.now.addingTimeInterval(-14)
                ),
                age: 92 * 86_400
            )

            // The busy row's spinner is a live control, so a still render substitutes a
            // placeholder glyph for it. The line under the name is what this case is about.
            caption("Selected — a transient message still takes the line")
            selectedRow(
                workspace("wsclean", in: workspaces),
                activity: .thinking,
                live: live(.thinking, startedAt: Self.now.addingTimeInterval(-61)),
                age: 86_400,
                statusMessage: "Connecting..."
            )

            caption("Selected — long summary truncates before the readings do")
            selectedRow(
                workspace("very-long-workspace-name-here", in: folio),
                activity: .runningTool,
                live: live(
                    .runningTool(
                        name: "Bash(swift test --filter SidebarActiveCardRenderTests)",
                        detail: nil
                    ),
                    startedAt: Self.now.addingTimeInterval(-7_265)
                ),
                age: 400 * 86_400
            )

            caption("Unselected — unchanged")
            unselectedRow(
                workspace("bugfix-422", in: workspaces, note: "waiting on evidence"),
                activity: .thinking
            )
            unselectedRow(workspace("skills-v13", in: folio), activity: .live)
            unselectedRow(workspace("archive-sweep", in: workspaces))
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, scheme)
    }

    private func live(_ run: AgentRunState, startedAt: Date) -> SidebarLiveSessionStatus {
        SidebarLiveSessionStatus(
            kind: .claudeCode,
            summary: AgentChromeProjection.runState(run).summaryText,
            startedAt: startedAt
        )
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

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func selectedRow(
        _ workspace: Workspace,
        activity: SidebarSessionActivity,
        live: SidebarLiveSessionStatus,
        age: TimeInterval,
        statusMessage: String? = nil
    ) -> some View {
        workspace.createdAt = Self.now.addingTimeInterval(-age)
        return WorkspaceRow(
            workspace: workspace,
            isSelected: true,
            statusMessage: statusMessage,
            sessionActivity: activity,
            paneCount: 2,
            isNested: true,
            liveStatus: live,
            statusClock: Self.now
        )
    }

    private func unselectedRow(
        _ workspace: Workspace,
        activity: SidebarSessionActivity = .inactive
    ) -> some View {
        WorkspaceRow(
            workspace: workspace,
            sessionActivity: activity,
            isNested: true
        )
    }
}

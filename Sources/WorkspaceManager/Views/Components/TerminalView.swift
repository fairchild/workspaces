//
//  TerminalView.swift
//  WorkspaceManager
//

import SwiftUI
import WorkspaceManagerCore

struct TerminalContainerView: View {
    let workspace: Workspace
    @State private var restartGeneration = 0

    private var terminalIdentity: TerminalIdentity {
        TerminalIdentity(workspaceID: workspace.id, restartGeneration: restartGeneration)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)

                Text(workspace.workspaceURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button {
                    restartGeneration &+= 1
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart Terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            GhosttyTerminalRepresentable(
                workingDirectory: workspace.workspaceURL,
                onProcessExit: {
                    NSLog("[GhosttyTerminal] Process exited for workspace: %@", workspace.name)
                }
            )
            .id(terminalIdentity)
        }
    }
}

private struct TerminalIdentity: Hashable {
    let workspaceID: UUID
    let restartGeneration: Int
}

struct GhosttyTerminalRepresentable: NSViewRepresentable {
    let workingDirectory: URL
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(
            workingDirectory: workingDirectory,
            onProcessExit: onProcessExit
        )
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        _ = context
        _ = nsView
    }
}

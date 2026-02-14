//
//  TerminalView.swift
//  WorkspaceManager
//

import SwiftUI
import WorkspaceManagerCore

struct TerminalContainerView: View {
    let modeLabel: String
    let workingDirectory: URL
    let processExitContext: String
    @State private var restartGeneration = 0

    private var terminalIdentity: TerminalIdentity {
        TerminalIdentity(
            workingDirectoryPath: workingDirectory.path,
            restartGeneration: restartGeneration
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)

                Text(modeLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(workingDirectory.path)
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
                workingDirectory: workingDirectory,
                onProcessExit: {
                    NSLog("[GhosttyTerminal] Process exited for %@", processExitContext)
                }
            )
            .id(terminalIdentity)
        }
    }
}

extension TerminalContainerView {
    init(workspace: Workspace) {
        self.init(
            modeLabel: "Workspace",
            workingDirectory: workspace.workspaceURL,
            processExitContext: "workspace '\(workspace.name)'"
        )
    }

    init(hostDirectory: URL) {
        self.init(
            modeLabel: "Host",
            workingDirectory: hostDirectory,
            processExitContext: "host terminal"
        )
    }
}

private struct TerminalIdentity: Hashable {
    let workingDirectoryPath: String
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

//
//  TerminalView.swift
//  WorkspaceManager
//

import SwiftUI
import WorkspaceManagerCore

@MainActor
final class HostTerminalSurfaceStore {
    private var surfaces: [UUID: GhosttySurfaceView] = [:]

    func view(for session: HostTerminalSession, onProcessExit: (() -> Void)? = nil) -> GhosttySurfaceView {
        if let existing = surfaces[session.id] {
            return existing
        }

        let created = GhosttySurfaceView(
            workingDirectory: session.directoryURL,
            onProcessExit: onProcessExit
        )
        surfaces[session.id] = created
        return created
    }

    func invalidate(sessionID: UUID) {
        surfaces.removeValue(forKey: sessionID)
    }
}

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

struct PersistentHostTerminalContainerView: View {
    let session: HostTerminalSession
    let surfaceStore: HostTerminalSurfaceStore
    @State private var restartGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(.secondary)

                Text("Host")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                Text(session.directoryPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Button {
                    surfaceStore.invalidate(sessionID: session.id)
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

            PersistentHostGhosttyRepresentable(
                session: session,
                surfaceStore: surfaceStore,
                onProcessExit: {
                    NSLog("[GhosttyTerminal] Process exited for host session %@", session.id.uuidString)
                }
            )
            .id(PersistentHostTerminalIdentity(sessionID: session.id, restartGeneration: restartGeneration))
        }
    }
}

private struct PersistentHostTerminalIdentity: Hashable {
    let sessionID: UUID
    let restartGeneration: Int
}

private struct PersistentHostGhosttyRepresentable: NSViewRepresentable {
    let session: HostTerminalSession
    let surfaceStore: HostTerminalSurfaceStore
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttySurfaceView {
        surfaceStore.view(for: session, onProcessExit: onProcessExit)
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        _ = context
        _ = nsView
    }
}

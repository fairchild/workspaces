//
//  TerminalView.swift
//  WorkspaceManager
//

import SwiftUI
import WorkspaceManagerCore

@MainActor
final class HostTerminalSurfaceStore {
    // Current refinement-gate policy: keep surfaces unbounded for deterministic
    // session restore. Revisit with an inactive-surface LRU if sustained usage
    // exceeds the threshold below or memory pressure is observed in profiling.
    private let revisitThreshold = 24
    private var didEmitRevisitLog = false
    private var surfaces: [UUID: GhosttySurfaceView] = [:]
    private var sessionIDsBySurfaceIdentity: [ObjectIdentifier: UUID] = [:]

    func view(for session: HostTerminalSession, onProcessExit: (() -> Void)? = nil) -> GhosttySurfaceView {
        if let existing = surfaces[session.id] {
            sessionIDsBySurfaceIdentity[ObjectIdentifier(existing)] = session.id
            return existing
        }

        let created = GhosttySurfaceView(
            workingDirectory: session.directoryURL,
            onProcessExit: onProcessExit
        )
        surfaces[session.id] = created
        sessionIDsBySurfaceIdentity[ObjectIdentifier(created)] = session.id

        if surfaces.count >= revisitThreshold, !didEmitRevisitLog {
            didEmitRevisitLog = true
            NSLog(
                "[HostSurfaceStore] Unbounded policy threshold reached (surfaces=%ld). Consider inactive LRU cap if memory pressure appears.",
                surfaces.count
            )
        }

        return created
    }

    func terminal(for sessionID: UUID) -> GhosttySurfaceView? {
        surfaces[sessionID]
    }

    func sessionID(for terminal: GhosttySurfaceView) -> UUID? {
        sessionIDsBySurfaceIdentity[ObjectIdentifier(terminal)]
    }

    func invalidate(sessionID: UUID) {
        if let removed = surfaces.removeValue(forKey: sessionID) {
            sessionIDsBySurfaceIdentity.removeValue(forKey: ObjectIdentifier(removed))
        }
    }
}

struct TerminalContainerView: View {
    let workingDirectory: URL
    let processExitContext: String

    private var terminalIdentity: TerminalIdentity {
        TerminalIdentity(
            workingDirectoryPath: workingDirectory.path
        )
    }

    var body: some View {
        GhosttyTerminalRepresentable(
            workingDirectory: workingDirectory,
            onProcessExit: {
                NSLog("[GhosttyTerminal] Process exited for %@", processExitContext)
            }
        )
        .id(terminalIdentity)
    }
}

extension TerminalContainerView {
    init(workspace: Workspace) {
        self.init(
            workingDirectory: workspace.workspaceURL,
            processExitContext: "workspace '\(workspace.name)'"
        )
    }

    init(hostDirectory: URL) {
        self.init(
            workingDirectory: hostDirectory,
            processExitContext: "host terminal"
        )
    }
}

private struct TerminalIdentity: Hashable {
    let workingDirectoryPath: String
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
    var onProcessExit: (() -> Void)?

    var body: some View {
        PersistentHostGhosttyRepresentable(
            session: session,
            surfaceStore: surfaceStore,
            onProcessExit: {
                NSLog("[GhosttyTerminal] Process exited for host session %@", session.id.uuidString)
                onProcessExit?()
            }
        )
        .id(session.id)
    }
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

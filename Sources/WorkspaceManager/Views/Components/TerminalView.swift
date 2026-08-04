//
//  TerminalView.swift
//  WorkspaceManager
//

import AppKit
import SwiftUI
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "TerminalView")

enum TerminalPaneChromePolicy: Equatable, Sendable {
    case minimal

    static let current: Self = .minimal

    var showsPaneHeader: Bool {
        false
    }

    var showsManualRestartControl: Bool {
        false
    }
}

struct TerminalContainerView: View {
    let workingDirectory: URL
    let processExitContext: String
    let chromePolicy: TerminalPaneChromePolicy = .current

    static func identityToken(for workingDirectory: URL) -> String {
        workingDirectory.path
    }

    @ViewBuilder
    private var terminalSurface: some View {
        switch chromePolicy {
        case .minimal:
            GhosttyTerminalRepresentable(
                workingDirectory: workingDirectory,
                onProcessExit: {
                    log.info("[GhosttyTerminal] Process exited for \(processExitContext, privacy: .public)")
                }
            )
        }
    }

    var body: some View {
        terminalSurface
            .id(Self.identityToken(for: workingDirectory))
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

struct GhosttyTerminalRepresentable: NSViewRepresentable {
    let workingDirectory: URL
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalScrollContainerView {
        let surfaceView = GhosttySurfaceView(
            workingDirectory: workingDirectory,
            onProcessExit: onProcessExit
        )
        return GhosttyTerminalScrollContainerView(surfaceView: surfaceView)
    }

    func updateNSView(_ nsView: GhosttyTerminalScrollContainerView, context: Context) {
        _ = context
        _ = nsView
    }
}

struct PersistentHostTerminalContainerView: View {
    let tileID: TileID
    let session: HostTerminalSession
    let surfaceStore: SurfaceStore
    var onProcessExit: (() -> Void)?
    var onCloseConfirmationRequired: (() -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    let chromePolicy: TerminalPaneChromePolicy = .current

    static func identityToken(for sessionID: UUID) -> UUID {
        sessionID
    }

    @ViewBuilder
    private var terminalSurface: some View {
        switch chromePolicy {
        case .minimal:
            PersistentHostGhosttyRepresentable(
                tileID: tileID,
                session: session,
                surfaceStore: surfaceStore,
                contextMenuProvider: contextMenuProvider,
                onCloseConfirmationRequired: onCloseConfirmationRequired,
                onProcessExit: {
                    log.info(
                        "[GhosttyTerminal] Process exited for host session \(session.id.uuidString, privacy: .public)"
                    )
                    onProcessExit?()
                }
            )
        }
    }

    var body: some View {
        terminalSurface
            .id(Self.identityToken(for: session.id))
    }
}

private struct PersistentHostGhosttyRepresentable: NSViewRepresentable {
    let tileID: TileID
    let session: HostTerminalSession
    let surfaceStore: SurfaceStore
    var contextMenuProvider: (() -> NSMenu?)?
    var onCloseConfirmationRequired: (() -> Void)?
    var onProcessExit: (() -> Void)?

    func makeNSView(context: Context) -> GhosttyTerminalScrollContainerView {
        let surfaceView = surfaceStore.terminalSurface(
            for: tileID,
            session: session,
            onProcessExit: onProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired,
            contextMenuProvider: contextMenuProvider
        ).surfaceView
        return GhosttyTerminalScrollContainerView(surfaceView: surfaceView)
    }

    func updateNSView(_ nsView: GhosttyTerminalScrollContainerView, context: Context) {
        _ = context
        nsView.surfaceView.onCloseConfirmationRequired = onCloseConfirmationRequired
        nsView.updateContextMenuProvider(contextMenuProvider)
    }
}

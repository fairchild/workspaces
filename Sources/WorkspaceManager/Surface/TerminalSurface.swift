import AppKit
import WorkspaceManagerCore

/// `Surface` conformer backing a terminal tile with one libghostty `GhosttySurfaceView`.
///
/// Owns the view's lifecycle (create, focus, close, teardown) and holds the `HostTerminalSession`
/// binding that ties this layout tile to its agent-domain identity. The agent registry, OSC routing,
/// command status, and local-state coupling deliberately stay *outside* this type — they remain
/// orchestrated by `HostTerminalStateStore` until Phase 5 moves eviction authority into the store —
/// so the seam carries only what a generic surface needs.
@MainActor
final class TerminalSurface: Surface {
    let kind: SurfaceKind = .terminal
    let tileID: TileID

    /// Agent-domain identity for this tile's terminal (registry / OSC / command status / local state).
    let session: HostTerminalSession

    let surfaceView: GhosttySurfaceView

    init(
        tileID: TileID,
        session: HostTerminalSession,
        hooksSocketPath: String?,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil,
        contextMenuProvider: (() -> NSMenu?)? = nil
    ) {
        self.tileID = tileID
        self.session = session

        if let customCommand = session.customCommand {
            self.surfaceView = GhosttySurfaceView(
                customCommand: customCommand,
                onProcessExit: onProcessExit,
                onCloseConfirmationRequired: onCloseConfirmationRequired
            )
        } else {
            self.surfaceView = GhosttySurfaceView(
                workingDirectory: session.directoryURL,
                hostSessionID: session.id,
                hooksSocketPath: hooksSocketPath,
                onProcessExit: onProcessExit,
                onCloseConfirmationRequired: onCloseConfirmationRequired
            )
        }
        self.surfaceView.contextMenuProvider = contextMenuProvider
    }

    /// Refresh the per-render callbacks on surface reuse, mirroring the legacy store's reuse path.
    func update(
        onProcessExit: (() -> Void)?,
        onCloseConfirmationRequired: (() -> Void)?,
        contextMenuProvider: (() -> NSMenu?)?
    ) {
        surfaceView.onProcessExit = onProcessExit
        surfaceView.onCloseConfirmationRequired = onCloseConfirmationRequired
        surfaceView.contextMenuProvider = contextMenuProvider
    }

    func makeContentView() -> NSView {
        surfaceView
    }

    var displayTitle: String {
        let title = surfaceView.terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        let fallback = session.directoryURL.lastPathComponent
        return fallback.isEmpty ? "Terminal" : fallback
    }

    func focus() {
        TerminalFocusManager.shared.requestFocus(for: surfaceView)
    }

    func resignFocus() {
        guard let window = surfaceView.window, window.firstResponder === surfaceView else { return }
        window.makeFirstResponder(nil)
    }

    func requestClose() {
        surfaceView.requestClose()
    }

    func tearDown() {
        // Detach the view; the libghostty C handle frees via ARC/`deinit`, matching the legacy
        // `HostTerminalSurfaceStore.invalidate` eviction path (no explicit free exists today).
        surfaceView.removeFromSuperview()
    }
}

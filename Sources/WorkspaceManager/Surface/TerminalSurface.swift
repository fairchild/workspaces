import AppKit
import WorkspaceManagerCore

/// `Surface` conformer backing a terminal tile with one libghostty `GhosttySurfaceView`.
///
/// Owns the view's lifecycle (create, focus, close, teardown) and holds the `HostTerminalSession`
/// binding that ties this layout tile to its agent-domain identity. The agent registry, OSC routing,
/// command status, and local-state coupling deliberately stay *outside* this type — they remain
/// orchestrated by `TileTreeStore` so the seam carries only what a generic surface needs.
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
        automationEnvironment: AutomationTerminalEnvironment? = nil,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil,
        contextMenuProvider: (() -> NSMenu?)? = nil
    ) {
        self.tileID = tileID
        self.session = session

        let launchContext = TerminalSessionLaunchContext.hostSession(
            session,
            hooksSocketPath: hooksSocketPath,
            automationEnvironment: automationEnvironment
        )
        self.surfaceView = GhosttySurfaceView(
            launchContext: launchContext,
            onProcessExit: onProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired
        )
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

    /// Session-retirement close (process-alive teardown with confirmation-as-error semantics),
    /// driven through the tested `GhosttySurfaceRetirementCloser` state machine. The surface
    /// conformer owns this lifecycle so callers never reach into the libghostty view (#710).
    func closeForSessionRetirement() async throws {
        try await GhosttySurfaceRetirementCloser().close(surfaceView)
    }

    func tearDown() {
        // Detach the view and drop the title hook; the libghostty C handle frees via ARC/`deinit`
        // (no explicit free exists today). The title hook holds a strong `self`-capture into the
        // store's callback, so clearing it lets the surface deallocate promptly under a `sync` storm.
        surfaceView.onTerminalTitleChanged = nil
        surfaceView.removeFromSuperview()
    }
}

import Foundation

/// The focus and click-measurement calls the main window's selection paths make.
/// Selection depends on this narrow contract rather than on `TerminalFocusCoordinator`
/// itself, so the ordering can be exercised without an AppKit window or an app activation.
@MainActor
protocol MainWindowTerminalFocusRequesting: AnyObject {
    func cancelPendingFocusRequest(reason: String)
    func cancelPendingRepoClickMeasurement(reason: String)
    func beginRepoClickMeasurement(sessionID: UUID, repoPath: String)
    func completeRepoClickMeasurement(sessionID: UUID, outcome: String)
    func beginWorkspaceClickMeasurement(sessionID: UUID, workspacePath: String)
    func completeWorkspaceClickMeasurement(sessionID: UUID, outcome: String)
    func requestMainTerminalFocus(
        targetSessionID: UUID?,
        activateApp: Bool,
        surfaceStore: SurfaceStore,
        activeSessionID: UUID?,
        onTargetFocused: (() -> Void)?
    )
}

extension TerminalFocusCoordinator: MainWindowTerminalFocusRequesting {}

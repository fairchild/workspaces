import Foundation

/// The graceful-close contract a terminal surface offers session retirement: liveness and
/// process-exit observation, a close request, and the close-confirmation hook the runtime fires
/// when the shell still has a foreground process. `GhosttySurfaceView` conforms over libghostty;
/// tests conform with a fake — this seam is what makes the retirement state machine testable
/// without a live surface (#710).
@MainActor
protocol RetirementClosableSurface: AnyObject {
    /// Whether the libghostty surface still exists (freed surfaces read false).
    var isSurfaceAlive: Bool { get }
    /// Whether the surface's child process has exited.
    var hasProcessExited: Bool { get }
    /// Ask the runtime to close the surface (may trigger the confirmation hook instead).
    func requestSurfaceClose()
    /// Runtime hook fired when close needs user confirmation because a process is alive.
    var onCloseConfirmationRequired: (() -> Void)? { get set }
    /// Human-readable title for retirement errors.
    var retirementDisplayTitle: String { get }
}

/// Session-retirement close: request a graceful close and poll until the process exits, the
/// surface is freed, the runtime asks for confirmation (a foreground process is still running —
/// surfaced as an error, never a dialog), or the deadline passes. Extracted from
/// `GhosttySurfaceView` so the state machine is unit-tested against a fake surface.
@MainActor
struct GhosttySurfaceRetirementCloser {
    var timeout: Duration = .seconds(5)
    var pollInterval: Duration = .milliseconds(50)

    func close(_ surface: any RetirementClosableSurface) async throws {
        guard surface.isSurfaceAlive else { return }
        guard !surface.hasProcessExited else { return }

        var processStillRunning = false
        let previousCloseConfirmation = surface.onCloseConfirmationRequired
        surface.onCloseConfirmationRequired = {
            processStillRunning = true
        }
        defer {
            surface.onCloseConfirmationRequired = previousCloseConfirmation
        }

        surface.requestSurfaceClose()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !surface.isSurfaceAlive || surface.hasProcessExited {
                return
            }
            if processStillRunning {
                throw GhosttySurfaceRetirementCloseError.processStillRunning(
                    title: surface.retirementDisplayTitle)
            }
            try await Task.sleep(for: pollInterval)
        }

        if !surface.isSurfaceAlive || surface.hasProcessExited {
            return
        }
        throw GhosttySurfaceRetirementCloseError.timedOut(title: surface.retirementDisplayTitle)
    }
}

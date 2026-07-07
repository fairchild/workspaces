import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
private final class FakeRetirementSurface: RetirementClosableSurface {
    var aliveValue = true
    var exitedValue = false
    var onCloseConfirmationRequired: (() -> Void)?
    var retirementDisplayTitle = "fake-terminal"

    private(set) var closeRequests = 0
    private(set) var livenessChecks = 0
    /// Runs when the closer requests a close — the fake's stand-in for runtime behavior.
    var onCloseRequested: (() -> Void)?
    /// Runs on every liveness read — lets tests flip state after N polls, deterministically
    /// (no wall-clock timers to race a loaded test runner).
    var onLivenessCheck: ((Int) -> Void)?

    var isSurfaceAlive: Bool {
        livenessChecks += 1
        onLivenessCheck?(livenessChecks)
        return aliveValue
    }

    var hasProcessExited: Bool {
        exitedValue
    }

    func requestSurfaceClose() {
        closeRequests += 1
        onCloseRequested?()
    }
}

@MainActor
@Suite("GhosttySurfaceRetirementCloser")
struct GhosttySurfaceRetirementCloserTests {
    private func makeCloser(
        timeout: Duration = .milliseconds(300),
        pollInterval: Duration = .milliseconds(10)
    ) -> GhosttySurfaceRetirementCloser {
        GhosttySurfaceRetirementCloser(timeout: timeout, pollInterval: pollInterval)
    }

    @Test("A freed surface is a no-op — no close request")
    func freedSurfaceNoOp() async throws {
        let surface = FakeRetirementSurface()
        surface.aliveValue = false

        try await makeCloser().close(surface)
        #expect(surface.closeRequests == 0)
    }

    @Test("An already-exited process is a no-op — no close request")
    func exitedProcessNoOp() async throws {
        let surface = FakeRetirementSurface()
        surface.exitedValue = true

        try await makeCloser().close(surface)
        #expect(surface.closeRequests == 0)
    }

    @Test("Process exiting after the close request returns cleanly and restores the hook")
    func exitAfterCloseReturns() async throws {
        let surface = FakeRetirementSurface()
        var originalHookFired = false
        surface.onCloseConfirmationRequired = { originalHookFired = true }
        // The shell "exits" on the third liveness poll after the close request.
        surface.onLivenessCheck = { checks in
            if surface.closeRequests > 0, checks >= 3 {
                surface.exitedValue = true
            }
        }

        try await makeCloser(timeout: .seconds(5)).close(surface)

        #expect(surface.closeRequests == 1)
        // The original confirmation hook is restored, not lost to the closer's temporary capture.
        surface.onCloseConfirmationRequired?()
        #expect(originalHookFired)
    }

    @Test("A close-confirmation request means a live process — throws, never shows a dialog")
    func confirmationBecomesProcessStillRunning() async {
        let surface = FakeRetirementSurface()
        surface.onCloseRequested = {
            // The runtime answers the close request by asking for confirmation.
            surface.onCloseConfirmationRequired?()
        }

        do {
            try await makeCloser().close(surface)
            Issue.record("Expected processStillRunning")
        } catch let error as GhosttySurfaceRetirementCloseError {
            guard case .processStillRunning(let title) = error else {
                Issue.record("Expected processStillRunning, got \(error)")
                return
            }
            #expect(title == "fake-terminal")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Deadline passing with a live process throws timedOut")
    func deadlineThrowsTimedOut() async {
        let surface = FakeRetirementSurface()

        do {
            try await makeCloser(timeout: .milliseconds(80)).close(surface)
            Issue.record("Expected timedOut")
        } catch let error as GhosttySurfaceRetirementCloseError {
            guard case .timedOut(let title) = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
            #expect(title == "fake-terminal")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Surface freed mid-poll returns cleanly")
    func surfaceFreedMidPollReturns() async throws {
        let surface = FakeRetirementSurface()
        // The surface is "freed" on the third liveness poll after the close request.
        surface.onLivenessCheck = { checks in
            if surface.closeRequests > 0, checks >= 3 {
                surface.aliveValue = false
            }
        }

        try await makeCloser(timeout: .seconds(5)).close(surface)
        #expect(surface.closeRequests == 1)
    }

    @Test("The confirmation hook is restored even on the throwing paths")
    func hookRestoredAfterThrow() async {
        let surface = FakeRetirementSurface()
        var originalHookFired = false
        surface.onCloseConfirmationRequired = { originalHookFired = true }
        surface.onCloseRequested = {
            surface.onCloseConfirmationRequired?()
        }

        _ = try? await makeCloser().close(surface)

        surface.onCloseConfirmationRequired?()
        #expect(originalHookFired)
    }
}

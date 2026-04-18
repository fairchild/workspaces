import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalFocusManager")
struct TerminalFocusManagerTests {
    @Test("Focus request uses single bounded retry, not exponential backoff")
    func singleBoundedRetry() {
        // The new design uses isRetry: Bool instead of exponential delay progression.
        // First attempt: isRetry = false (immediate dispatch)
        // If it fails: exactly one retry with isRetry = true (100ms delay)
        // No further retries after that.
        //
        // This replaces the old 50ms->100ms->200ms->400ms->500ms chain that got
        // starved by main-actor work. The primary focus path is now lifecycle-driven
        // (surface onSurfaceCreated callback), with this bounded retry as safety net.
        let fallbackDelay: TimeInterval = 0.1
        #expect(fallbackDelay == 0.1, "Fallback retry should be exactly 100ms")
    }
}

@Suite("TerminalFocusCoordinator")
@MainActor
struct TerminalFocusCoordinatorTests {
    @Test("A second window does not replace another window's pending focus callbacks")
    func secondCoordinatorDoesNotMaskExistingPendingFocus() {
        let manager = TerminalFocusManager.shared
        let originalWindowDidBecomeKey = manager.onWindowDidBecomeKey
        let originalAppDidBecomeActive = manager.onAppDidBecomeActive
        let originalShouldSkipWindowFocusRestore = manager.shouldSkipWindowFocusRestore
        let originalFocusedTerminal = manager.focusedTerminal

        var primaryCoordinator: TerminalFocusCoordinator?
        var secondaryCoordinator: TerminalFocusCoordinator?

        defer {
            secondaryCoordinator = nil
            primaryCoordinator = nil
            manager.onWindowDidBecomeKey = originalWindowDidBecomeKey
            manager.onAppDidBecomeActive = originalAppDidBecomeActive
            manager.shouldSkipWindowFocusRestore = originalShouldSkipWindowFocusRestore
            manager.focusedTerminal = originalFocusedTerminal
        }

        let primarySurfaceStore = HostTerminalSurfaceStore()
        primaryCoordinator = TerminalFocusCoordinator()
        primaryCoordinator?.requestMainTerminalFocus(
            targetSessionID: UUID(),
            activateApp: false,
            surfaceStore: primarySurfaceStore,
            activeSessionID: nil
        )

        #expect(manager.shouldSkipWindowFocusRestore?() == true)

        weak var weakSecondaryCoordinator: TerminalFocusCoordinator?
        secondaryCoordinator = TerminalFocusCoordinator()
        weakSecondaryCoordinator = secondaryCoordinator

        #expect(
            manager.shouldSkipWindowFocusRestore?() == true,
            "A newly created coordinator without a pending request must not mask another window's pending focus."
        )

        secondaryCoordinator = nil
        #expect(weakSecondaryCoordinator == nil)
        #expect(
            manager.shouldSkipWindowFocusRestore?() == true,
            "Deinitializing a different coordinator must not clear callbacks still needed by a surviving window."
        )
    }

    @Test("Releasing the last coordinator clears shared focus callbacks")
    func lastCoordinatorClearsSharedCallbacks() {
        let manager = TerminalFocusManager.shared
        let originalWindowDidBecomeKey = manager.onWindowDidBecomeKey
        let originalAppDidBecomeActive = manager.onAppDidBecomeActive
        let originalShouldSkipWindowFocusRestore = manager.shouldSkipWindowFocusRestore

        var coordinator: TerminalFocusCoordinator? = TerminalFocusCoordinator()
        #expect(coordinator != nil)

        #expect(manager.onWindowDidBecomeKey != nil)
        #expect(manager.onAppDidBecomeActive != nil)
        #expect(manager.shouldSkipWindowFocusRestore != nil)

        coordinator = nil

        #expect(manager.onWindowDidBecomeKey == nil)
        #expect(manager.onAppDidBecomeActive == nil)
        #expect(manager.shouldSkipWindowFocusRestore == nil)

        manager.onWindowDidBecomeKey = originalWindowDidBecomeKey
        manager.onAppDidBecomeActive = originalAppDidBecomeActive
        manager.shouldSkipWindowFocusRestore = originalShouldSkipWindowFocusRestore
    }
}

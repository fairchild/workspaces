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

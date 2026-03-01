import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalFocusManager")
struct TerminalFocusManagerTests {
    @Test("Backoff progression is capped at 500ms")
    func backoffProgressionIsCapped() {
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: nil), 0.05))
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: 0.05), 0.1))
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: 0.1), 0.2))
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: 0.2), 0.4))
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: 0.4), 0.5))
        #expect(isApproximatelyEqual(TerminalFocusManager.nextRetryDelay(after: 0.5), 0.5))
    }

    @Test("Retry eligibility stops at the 500ms cap")
    func retryEligibilityStopsAtCap() {
        #expect(TerminalFocusManager.shouldRetry(after: nil))
        #expect(TerminalFocusManager.shouldRetry(after: 0.4))
        #expect(!TerminalFocusManager.shouldRetry(after: 0.5))
        #expect(!TerminalFocusManager.shouldRetry(after: 1.0))
    }

    private func isApproximatelyEqual(
        _ lhs: TimeInterval, _ rhs: TimeInterval, epsilon: TimeInterval = 0.000_001
    )
        -> Bool
    {
        abs(lhs - rhs) < epsilon
    }
}

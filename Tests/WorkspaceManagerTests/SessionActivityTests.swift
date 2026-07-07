import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("SessionActivity")
struct SessionActivityTests {
    private func status(_ run: AgentRunState) -> AgentSessionStatus {
        AgentSessionStatus(hostSessionID: UUID(), cwd: "/tmp/x", run: run)
    }

    // MARK: - AgentRunState → SessionActivity mapping

    @Test("Each agent run state maps to the expected activity")
    func runStateMapping() {
        #expect(SessionActivity.from(nil) == .inactive)
        #expect(SessionActivity.from(status(.idle)) == .live)
        #expect(SessionActivity.from(status(.thinking)) == .thinking)
        #expect(SessionActivity.from(status(.runningTool(name: "grep", detail: nil))) == .runningTool)
        #expect(SessionActivity.from(status(.awaitingInput(reason: .permissionPrompt))) == .awaitingInput)
        #expect(SessionActivity.from(status(.complete)) == .live)
        #expect(
            SessionActivity.from(status(.errored(category: .server, message: "boom")))
                == .errored(category: .server))
    }

    // MARK: - Severity ladder (the shared ordering)

    @Test("Severity ranks attention-demanding activities above active/idle ones")
    func severityLadder() {
        let ordered: [SessionActivity] = [
            .errored(category: .server),
            .awaitingInput,
            .runningTool,
            .active,
            .live,
            .inactive,
        ]
        // Strictly decreasing severity down the ladder.
        for (higher, lower) in zip(ordered, ordered.dropFirst()) {
            #expect(higher.severity > lower.severity, "\(higher) should outrank \(lower)")
        }
        // runningTool and thinking share a rung.
        #expect(SessionActivity.runningTool.severity == SessionActivity.thinking.severity)
    }

    @Test("mergedWithBubbled keeps the more severe activity")
    func mergePrefersSeverity() {
        #expect(SessionActivity.live.mergedWithBubbled(.awaitingInput) == .awaitingInput)
        #expect(SessionActivity.awaitingInput.mergedWithBubbled(.live) == .awaitingInput)
        // Tie prefers self (the baseline).
        #expect(SessionActivity.active.mergedWithBubbled(.active) == .active)
    }
}

import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("AgentKindPresentation")
struct AgentKindPresentationTests {
    @Test("Every agent kind has a non-empty display name and symbol")
    func everyKindHasDisplayNameAndSymbol() {
        for kind in [AgentKind.claudeCode, .opencode, .aider, .unknown] {
            #expect(!kind.displayName.isEmpty)
            #expect(!kind.symbolName.isEmpty)
        }
    }

    @Test("Display names match the known agents")
    func displayNamesAreStable() {
        #expect(AgentKind.claudeCode.displayName == "Claude Code")
        #expect(AgentKind.opencode.displayName == "OpenCode")
        #expect(AgentKind.aider.displayName == "Aider")
        #expect(AgentKind.unknown.displayName == "Agent")
    }

    @Test("Known agent kinds use distinct symbols")
    func knownKindsHaveDistinctSymbols() {
        let symbols = [AgentKind.claudeCode, .opencode, .aider].map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
    }

    @Test("Run states summarize to readable text")
    func runStateSummaries() {
        #expect(AgentRunState.idle.summaryText == "Idle")
        #expect(AgentRunState.thinking.summaryText == "Thinking…")
        #expect(AgentRunState.runningTool(name: "Bash", detail: nil).summaryText == "Running: Bash")
        #expect(AgentRunState.awaitingInput(reason: .permissionPrompt).summaryText == "Awaiting input")
        #expect(AgentRunState.complete.summaryText == "Done")
        #expect(AgentRunState.errored(category: .rateLimit, message: nil).summaryText == "Rate limited")
        #expect(AgentRunState.errored(category: .unknown, message: nil).summaryText == "Error")
    }
}

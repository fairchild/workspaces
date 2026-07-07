import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("SessionActivitySnippet")
struct SessionActivitySnippetTests {
    @Test("Idle and complete produce no snippet")
    func silentStates() {
        #expect(SessionActivitySnippet.text(for: .idle) == nil)
        #expect(SessionActivitySnippet.text(for: .complete) == nil)
    }

    @Test("Thinking is surfaced")
    func thinking() {
        #expect(SessionActivitySnippet.text(for: .thinking) == "Thinking…")
    }

    @Test("Running tool includes name and detail")
    func runningToolWithDetail() {
        #expect(
            SessionActivitySnippet.text(for: .runningTool(name: "Bash", detail: "swift test"))
                == "Running Bash: swift test")
    }

    @Test("Running tool without detail omits the colon")
    func runningToolWithoutDetail() {
        #expect(SessionActivitySnippet.text(for: .runningTool(name: "Bash", detail: nil)) == "Running Bash")
        #expect(
            SessionActivitySnippet.text(for: .runningTool(name: "Bash", detail: "   ")) == "Running Bash")
    }

    @Test("Awaiting input uses per-reason human phrasing")
    func awaitingPhrasing() {
        #expect(
            SessionActivitySnippet.text(for: .awaitingInput(reason: .permissionPrompt))
                == "Waiting for permission")
        #expect(
            SessionActivitySnippet.text(for: .awaitingInput(reason: .idlePrompt))
                == "Waiting for your reply")
        #expect(SessionActivitySnippet.text(for: .awaitingInput(reason: .custom)) == "Awaiting input")
    }

    @Test("Errored prefers the message, falling back to the category vocabulary")
    func erroredPhrasing() {
        #expect(
            SessionActivitySnippet.text(for: .errored(category: .toolFailure, message: "Tests failed"))
                == "Tests failed")
        #expect(
            SessionActivitySnippet.text(for: .errored(category: .rateLimit, message: nil))
                == "Rate limited")
        // Blank message falls through to the category vocabulary rather than an empty line.
        #expect(
            SessionActivitySnippet.text(for: .errored(category: .authentication, message: "  "))
                == "Auth error")
    }

    @Test("Snippets collapse whitespace to a single line")
    func singleLine() {
        #expect(
            SessionActivitySnippet.text(for: .runningTool(name: "Edit", detail: "a\n\tb   c"))
                == "Running Edit: a b c")
    }

    @Test("Long snippets are truncated with an ellipsis")
    func truncation() {
        let detail = String(repeating: "x", count: 300)
        let snippet = try? #require(
            SessionActivitySnippet.text(for: .runningTool(name: "Bash", detail: detail), maxLength: 40))
        #expect(snippet?.count == 40)
        #expect(snippet?.hasSuffix("…") == true)
    }
}

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("TerminalPromptReadinessSignpostController")
struct TerminalPromptReadinessSignpostControllerTests {
    @Test("prompt readiness completes launch and focus metrics once")
    func promptReadinessCompletesMetricsOnce() {
        let sessionID = UUID()
        var launchTriggers: [String] = []
        var repoCompletions: [(UUID, String)] = []
        var workspaceCompletions: [(UUID, String)] = []

        var controller = TerminalPromptReadinessSignpostController(
            hostSessionID: sessionID,
            completeLaunch: { trigger in launchTriggers.append(trigger) },
            completeRepoClick: { sessionID, outcome in repoCompletions.append((sessionID, outcome)) },
            completeWorkspaceClick: { sessionID, outcome in workspaceCompletions.append((sessionID, outcome)) }
        )

        controller.completeIfNeeded(signal: .setTitle)
        controller.completeIfNeeded(signal: .pwd)

        #expect(launchTriggers == ["terminal_set_title"])
        #expect(repoCompletions.count == 1)
        #expect(repoCompletions[0].0 == sessionID)
        #expect(repoCompletions[0].1 == "prompt_ready")
        #expect(workspaceCompletions.count == 1)
        #expect(workspaceCompletions[0].0 == sessionID)
        #expect(workspaceCompletions[0].1 == "prompt_ready")
    }

    @Test("prompt readiness without host session still completes launch")
    func promptReadinessWithoutHostSessionCompletesLaunchOnly() {
        var launchTriggers: [String] = []
        var repoCompletionCount = 0
        var workspaceCompletionCount = 0

        var controller = TerminalPromptReadinessSignpostController(
            hostSessionID: nil,
            completeLaunch: { trigger in launchTriggers.append(trigger) },
            completeRepoClick: { _, _ in repoCompletionCount += 1 },
            completeWorkspaceClick: { _, _ in workspaceCompletionCount += 1 }
        )

        controller.completeIfNeeded(signal: .pwd)

        #expect(launchTriggers == ["terminal_pwd"])
        #expect(repoCompletionCount == 0)
        #expect(workspaceCompletionCount == 0)
    }
}

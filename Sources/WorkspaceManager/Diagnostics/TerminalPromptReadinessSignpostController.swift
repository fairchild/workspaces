import Foundation

struct TerminalPromptReadinessSignpostController {
    typealias LaunchCompletion = (_ trigger: String) -> Void
    typealias SessionCompletion = (_ sessionID: UUID, _ outcome: String) -> Void

    private let hostSessionID: UUID?
    private let completeLaunch: LaunchCompletion
    private let completeRepoClick: SessionCompletion
    private let completeWorkspaceClick: SessionCompletion
    private var didComplete = false

    init(
        hostSessionID: UUID?,
        completeLaunch: @escaping LaunchCompletion = PerformanceSignposts.endLaunchToFirstPromptIfNeeded,
        completeRepoClick: @escaping SessionCompletion = PerformanceSignposts.endRepoClickToFocusedInputIfNeeded,
        completeWorkspaceClick: @escaping SessionCompletion = PerformanceSignposts
            .endWorkspaceClickToFocusedInputIfNeeded
    ) {
        self.hostSessionID = hostSessionID
        self.completeLaunch = completeLaunch
        self.completeRepoClick = completeRepoClick
        self.completeWorkspaceClick = completeWorkspaceClick
    }

    mutating func completeIfNeeded(signal: TerminalReadinessDiagnostics.Signal) {
        guard signal.indicatesPromptReady else { return }
        guard !didComplete else { return }

        didComplete = true
        completeLaunch("terminal_\(signal.rawValue)")

        guard let hostSessionID else { return }
        completeRepoClick(hostSessionID, "prompt_ready")
        completeWorkspaceClick(hostSessionID, "prompt_ready")
    }
}

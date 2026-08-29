import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarWorkspacePresentationController")
struct SidebarWorkspacePresentationControllerTests {
    private let controller = SidebarWorkspacePresentationController()

    @Test("Pane count defaults to zero for missing sessions")
    func paneCountDefaultsToZero() {
        let key = HostTerminalSessionKey.repoPath("/repo")

        #expect(controller.paneCount(for: key, paneCountBySessionKey: [:]) == 0)
        #expect(controller.paneCount(for: key, paneCountBySessionKey: [key: 3]) == 3)
    }

    @Test("Session activity derives live and active state from pane counts and active key")
    func sessionActivityDerivesState() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let otherKey = HostTerminalSessionKey.repoPath("/other")

        #expect(
            controller.sessionActivity(
                for: key,
                paneCountBySessionKey: [:],
                activeSessionKey: nil
            ) == .inactive
        )
        #expect(
            controller.sessionActivity(
                for: key,
                paneCountBySessionKey: [key: 1],
                activeSessionKey: otherKey
            ) == .live
        )
        #expect(
            controller.sessionActivity(
                for: key,
                paneCountBySessionKey: [:],
                activeSessionKey: key
            ) == .active
        )
    }

    @Test("Agent-derived activity is preferred over baseline pane-count signal")
    func agentDerivedActivityWinsWhenRegistryHasState() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let status = AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: "/repo",
            run: .awaitingInput(reason: .permissionPrompt),
            lastEventAt: Date(),
            hookActive: true
        )

        let activity = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: nil,
            sessions: [session],
            agentStatus: { [session.id: status][$0] }
        )
        #expect(activity == .awaitingInput)
    }

    @Test("Errored agent state surfaces error category in sidebar")
    func erroredAgentStateSurfaces() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let status = AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: "/repo",
            run: .errored(category: .rateLimit, message: "rate limit"),
            lastEventAt: Date(),
            hookActive: true
        )

        let activity = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: key,
            sessions: [session],
            agentStatus: { [session.id: status][$0] }
        )
        if case .errored(let category) = activity {
            #expect(category == .rateLimit)
        } else {
            Issue.record("expected errored(.rateLimit)")
        }
    }

    @Test("Idle agent state defers to baseline pane-count signal")
    func idleAgentStateDefersToBaseline() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let status = AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: "/repo",
            run: .idle,
            lastEventAt: Date(),
            hookActive: false
        )

        let activeActivity = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: key,
            sessions: [session],
            agentStatus: { [session.id: status][$0] }
        )
        #expect(activeActivity == .active)

        let liveActivity = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 1],
            activeSessionKey: nil,
            sessions: [session],
            agentStatus: { [session.id: status][$0] }
        )
        #expect(liveActivity == .live)
    }

    @Test("Empty agent map preserves the existing pane-count + active signal")
    func emptyAgentMapKeepsBaseline() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))

        let activity = controller.sessionActivity(
            for: key,
            paneCountBySessionKey: [key: 2],
            activeSessionKey: key,
            sessions: [session],
            agentStatus: { _ in nil }
        )
        #expect(activity == .active)
    }

    @Test("Local workspace session key falls back to normalized host path")
    func localWorkspaceSessionKeyUsesNormalizedHostPath() {
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "feature",
            path: URL(fileURLWithPath: "/tmp/repo/../repo/workspaces/feature"),
            sourceRepo: repo
        )

        let key = controller.sessionKey(
            for: workspace,
            registry: WorkspaceProviderRegistry(providers: []),
            normalizePath: { $0.standardizedFileURL.path }
        )

        #expect(key == .hostPath("/tmp/repo/workspaces/feature"))
    }

    @Test("Provider workspace session key delegates to provider")
    func providerWorkspaceSessionKeyDelegatesToProvider() {
        let provider = MockPresentationProvider(
            descriptor: descriptor(id: "test-provider", displayName: "Test Provider")
        )
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "remote",
            path: URL(fileURLWithPath: Workspace.remotePathSentinel),
            sourceRepo: repo,
            backendIdentifier: "test-provider",
            remoteId: "remote-123"
        )

        let key = controller.sessionKey(
            for: workspace,
            registry: WorkspaceProviderRegistry(providers: [provider]),
            normalizePath: { $0.path }
        )

        #expect(key == .backendSession(providerID: "test-provider", instanceID: "remote-123"))
    }

    @Test("Workspace status message prioritizes connecting over action message")
    func workspaceStatusMessagePriority() {
        let workspaceID = UUID()

        let message = controller.workspaceStatusMessage(
            workspaceID: workspaceID,
            connectingWorkspaceID: workspaceID,
            workspaceAction: WorkspaceActionState(workspaceID: workspaceID, message: "Starting...")
        )

        #expect(message == "Connecting...")
        #expect(
            controller.workspaceStatusMessage(
                workspaceID: workspaceID,
                connectingWorkspaceID: nil,
                workspaceAction: WorkspaceActionState(workspaceID: workspaceID, message: "Starting...")
            ) == "Starting..."
        )
        #expect(
            controller.workspaceStatusMessage(
                workspaceID: workspaceID,
                connectingWorkspaceID: nil,
                workspaceAction: WorkspaceActionState(workspaceID: UUID(), message: "Starting...")
            ) == nil
        )
    }

    @Test("Provider display name falls back to provider identifier")
    func providerDisplayNameFallback() {
        let provider = MockPresentationProvider(
            descriptor: descriptor(id: "lume", displayName: "Lume")
        )
        let registry = WorkspaceProviderRegistry(providers: [provider])

        #expect(controller.providerDisplayName(for: "lume", registry: registry) == "Lume")
        #expect(controller.providerDisplayName(for: "missing", registry: registry) == "missing")
    }

    @Test("Host workspace file policy uses provider descriptor before workspace fallback")
    func hostWorkspaceFilePolicyUsesProviderDescriptorBeforeFallback() {
        let hostFileProvider = MockPresentationProvider(
            descriptor: descriptor(
                id: "remote-host-files",
                displayName: "Remote Host Files",
                usesHostWorkspaceFiles: true
            )
        )
        let registry = WorkspaceProviderRegistry(providers: [hostFileProvider])
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let providerWorkspace = Workspace(
            name: "provider",
            path: URL(fileURLWithPath: Workspace.remotePathSentinel),
            sourceRepo: repo,
            backendIdentifier: "remote-host-files"
        )
        let remoteWithoutProvider = Workspace(
            name: "remote",
            path: URL(fileURLWithPath: Workspace.remotePathSentinel),
            sourceRepo: repo,
            backendIdentifier: "unknown-remote"
        )
        let localWorkspace = Workspace(
            name: "local",
            path: URL(fileURLWithPath: "/tmp/repo/local"),
            sourceRepo: repo
        )

        #expect(controller.usesHostWorkspaceFiles(for: providerWorkspace, registry: registry))
        #expect(!controller.usesHostWorkspaceFiles(for: remoteWithoutProvider, registry: registry))
        #expect(controller.usesHostWorkspaceFiles(for: localWorkspace, registry: registry))
    }

    @Test("The live status line carries the agent, its run summary, and the session's start")
    func liveSessionStatusComposesTheLine() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let startedAt = Date(timeIntervalSince1970: 1_756_000_000)
        let status = AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: "/repo",
            run: .runningTool(name: "Bash", detail: nil),
            lastEventAt: startedAt.addingTimeInterval(300),
            hookActive: true,
            createdAt: startedAt
        )

        let live = controller.liveSessionStatus(
            for: key,
            sessions: [session],
            agentStatus: { [session.id: status][$0] }
        )

        #expect(live?.kind == .claudeCode)
        #expect(live?.summary == "Running: Bash")
        // The timer counts from when the session registered, not from its latest event.
        #expect(live?.startedAt == startedAt)
    }

    /// A row with no registered agent status has no line to show and so mounts no timer.
    @Test("A session with no registered agent status yields no live status line")
    func liveSessionStatusIsAbsentWithoutAgentState() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let session = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))

        #expect(
            controller.liveSessionStatus(
                for: key, sessions: [session], agentStatus: { _ in nil }) == nil
        )
        #expect(
            controller.liveSessionStatus(
                for: key, sessions: [], agentStatus: { _ in nil }) == nil
        )
    }

    /// The line and the activity dot read the same session, so a row never describes one
    /// session's work beside another's colour.
    @Test("The line describes the same session the activity dot does — the freshest one")
    func liveSessionStatusFollowsTheFreshestSession() {
        let key = HostTerminalSessionKey.repoPath("/repo")
        let older = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let newer = HostTerminalSession(key: key, directory: URL(fileURLWithPath: "/repo"))
        let base = Date(timeIntervalSince1970: 1_756_000_000)
        let statuses = [
            older.id: AgentSessionStatus(
                hostSessionID: older.id,
                kind: .aider,
                cwd: "/repo",
                run: .idle,
                lastEventAt: base,
                createdAt: base
            ),
            newer.id: AgentSessionStatus(
                hostSessionID: newer.id,
                kind: .claudeCode,
                cwd: "/repo",
                run: .awaitingInput(reason: .permissionPrompt),
                lastEventAt: base.addingTimeInterval(60),
                createdAt: base.addingTimeInterval(30)
            ),
        ]

        let live = controller.liveSessionStatus(
            for: key,
            sessions: [older, newer],
            agentStatus: { statuses[$0] }
        )

        #expect(live?.kind == .claudeCode)
        #expect(live?.summary == "Awaiting input")
        #expect(live?.startedAt == base.addingTimeInterval(30))
    }

    private func descriptor(
        id: String,
        displayName: String,
        usesHostWorkspaceFiles: Bool = false
    ) -> WorkspaceProviderDescriptor {
        WorkspaceProviderDescriptor(
            id: id,
            displayName: displayName,
            description: "\(displayName) provider",
            usesHostWorkspaceFiles: usesHostWorkspaceFiles
        )
    }
}

private actor MockPresentationProvider: WorkspaceProviderProtocol {
    nonisolated let descriptor: WorkspaceProviderDescriptor

    init(descriptor: WorkspaceProviderDescriptor) {
        self.descriptor = descriptor
    }

    func availability() async -> WorkspaceProviderAvailability {
        .available
    }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(providerID: descriptor.id, instanceID: workspace.terminalSessionIdentifier)
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        throw WorkspaceProviderError.unavailable("Not used in this test.")
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        throw WorkspaceProviderError.unavailable("Not used in this test.")
    }
}

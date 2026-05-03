import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceProviderSetupCoordinator")
@MainActor
struct WorkspaceProviderSetupCoordinatorTests {
    @Test("Prepare if needed requests confirmation when provider setup is required")
    func prepareIfNeededRequestsConfirmation() async throws {
        let provider = MockSetupProvider(
            requirement: .confirmation(Self.confirmation(state: "setupRequired"))
        )
        let coordinator = WorkspaceProviderSetupCoordinator()

        let intercepted = try await coordinator.prepareIfNeeded(
            provider: provider,
            action: .createWorkspace(name: "feature-vm", guestOS: .macOS)
        ) {}

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.state == "setupRequired")
        #expect(
            coordinator.confirmationRequest?.action
                == .createWorkspace(name: "feature-vm", guestOS: .macOS)
        )
    }

    @Test("Confirm and continue performs provider setup then resumes pending action")
    func confirmAndContinueRunsProviderSetupAndResumes() async throws {
        let provider = MockSetupProvider(
            requirement: .confirmation(Self.confirmation(state: "setupRequired"))
        )
        let coordinator = WorkspaceProviderSetupCoordinator()

        let resumed = LockedFlag()
        let intercepted = try await coordinator.prepareIfNeeded(
            provider: provider,
            action: .openDesktop(workspaceName: "feature-vm")
        ) {
            await resumed.setTrue()
        }
        #expect(intercepted == true)

        coordinator.confirmAndContinue()
        try await waitUntilTrue(flag: resumed)

        #expect(await provider.performSetupCallCount == 1)
        #expect(coordinator.progressPresentation == nil)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Providers without setup capability do not intercept")
    func providerWithoutSetupCapabilityDoesNotIntercept() async throws {
        let coordinator = WorkspaceProviderSetupCoordinator()

        let intercepted = try await coordinator.prepareIfNeeded(
            provider: MockBasicProvider(),
            action: .openTerminal(workspaceName: "feature-vm")
        ) {}

        #expect(intercepted == false)
        #expect(coordinator.confirmationRequest == nil)
    }

    @Test("Already in progress setup intercepts without confirmation")
    func alreadyInProgressInterceptsWithoutConfirmation() async throws {
        let provider = MockSetupProvider(requirement: .alreadyInProgress)
        let coordinator = WorkspaceProviderSetupCoordinator()

        let intercepted = try await coordinator.prepareIfNeeded(
            provider: provider,
            action: .startWorkspace(workspaceName: "feature-vm")
        ) {}

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest == nil)
    }

    private func waitUntilTrue(flag: LockedFlag) async throws {
        for _ in 0..<50 {
            if await flag.value {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        Issue.record("Timed out waiting for the pending action to resume.")
    }

    private static func confirmation(state: String) -> WorkspaceProviderSetupConfirmation {
        WorkspaceProviderSetupConfirmation(
            providerID: LumeWorkspaceProvider.identifier,
            providerDisplayName: "Lume VM",
            state: state,
            title: "Set Up macOS VM Support",
            primaryButtonTitle: "Install Lume and Continue",
            introductoryText: ["Intro"],
            learnMoreLabel: "Learn more",
            learnMoreURL: URL(string: "https://example.com/setup"),
            explanatoryStepsTitle: "What WorkSpaces will do",
            explanatorySteps: ["Step 1", "Step 2"],
            supplementaryText: "Default macOS VM: Tahoe",
            footerText: "Footer",
            progressTitle: "Preparing macOS VM Support",
            progressBody: "Progress body",
            initialProgress: WorkspaceProviderSetupProgress(
                id: "checkingHost",
                label: "Checking this Mac"
            )
        )
    }
}

private actor MockSetupProvider: WorkspaceProviderSetupCapable {
    nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: LumeWorkspaceProvider.identifier,
        displayName: "Lume VM",
        description: "Mock setup provider.",
        supportedGuestOS: [.macOS, .linux],
        supportsDesktop: true,
        usesHostWorkspaceFiles: true
    )

    private let requirementValue: WorkspaceProviderSetupRequirement?
    private(set) var performSetupCallCount = 0

    init(requirement: WorkspaceProviderSetupRequirement?) {
        self.requirementValue = requirement
    }

    func availability() async -> WorkspaceProviderAvailability { .available }

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

    func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        throw WorkspaceProviderError.unavailable("Not used in this test.")
    }

    func setupRequirement(
        for action: WorkspaceProviderSetupAction
    ) async throws -> WorkspaceProviderSetupRequirement? {
        requirementValue
    }

    func performSetup(progress: WorkspaceProviderSetupProgressHandler?) async throws {
        performSetupCallCount += 1
        await progress?(
            WorkspaceProviderSetupProgress(
                id: "verifyingDaemon",
                label: "Verifying daemon"
            )
        )
    }
}

private actor MockBasicProvider: WorkspaceProviderProtocol {
    nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: LocalWorkspaceProvider.identifier,
        displayName: "Local",
        description: "Mock basic provider.",
        usesHostWorkspaceFiles: true
    )

    func availability() async -> WorkspaceProviderAvailability { .available }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .hostPath(workspace.workspaceURL.path)
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

private actor LockedFlag {
    private var isTrue = false

    func setTrue() {
        isTrue = true
    }

    var value: Bool {
        isTrue
    }
}

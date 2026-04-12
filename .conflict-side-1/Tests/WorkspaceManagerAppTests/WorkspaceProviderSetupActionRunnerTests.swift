import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceProviderSetupActionRunner")
@MainActor
struct WorkspaceProviderSetupActionRunnerTests {
    @Test("Create action resumes after setup completes")
    func createActionResumesAfterSetup() async throws {
        let (coordinator, runner, provider) = makeHarness(state: "setupRequired")
        let recorder = RunnerEventRecorder()

        let intercepted = try await runner.run(
            provider: provider,
            action: .createWorkspace(name: "feature-vm", guestOS: .macOS),
            afterSetup: {
                await recorder.record("refresh")
            },
            perform: {
                await recorder.record("create")
            }
        )

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.action == .createWorkspace(name: "feature-vm", guestOS: .macOS))
        #expect(await recorder.snapshot() == [])

        coordinator.confirmAndContinue()

        try await waitForEvents(["refresh", "create"], recorder: recorder)
        #expect(await provider.performSetupCallCount == 1)
    }

    @Test("Start action resumes after repair completes")
    func startActionResumesAfterRepair() async throws {
        let (coordinator, runner, provider) = makeHarness(state: "repairRequired")
        let recorder = RunnerEventRecorder()

        let intercepted = try await runner.run(
            provider: provider,
            action: .startWorkspace(workspaceName: "feature-vm"),
            afterSetup: {
                await recorder.record("refresh")
            },
            perform: {
                await recorder.record("start")
            }
        )

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.action == .startWorkspace(workspaceName: "feature-vm"))

        coordinator.confirmAndContinue()

        try await waitForEvents(["refresh", "start"], recorder: recorder)
        #expect(await provider.performSetupCallCount == 1)
    }

    @Test("Open terminal action resumes after setup completes")
    func openTerminalResumesAfterSetup() async throws {
        let (coordinator, runner, provider) = makeHarness(state: "setupRequired")
        let recorder = RunnerEventRecorder()

        let intercepted = try await runner.run(
            provider: provider,
            action: .openTerminal(workspaceName: "feature-vm")
        ) {
            await recorder.record("open-terminal")
        }

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.action == .openTerminal(workspaceName: "feature-vm"))

        coordinator.confirmAndContinue()

        try await waitForEvents(["open-terminal"], recorder: recorder)
        #expect(await provider.performSetupCallCount == 1)
    }

    @Test("Open desktop action resumes after repair completes")
    func openDesktopResumesAfterRepair() async throws {
        let (coordinator, runner, provider) = makeHarness(state: "repairRequired")
        let recorder = RunnerEventRecorder()

        let intercepted = try await runner.run(
            provider: provider,
            action: .openDesktop(workspaceName: "feature-vm"),
            afterSetup: {
                await recorder.record("refresh")
            },
            perform: {
                await recorder.record("open-desktop")
            }
        )

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.action == .openDesktop(workspaceName: "feature-vm"))

        coordinator.confirmAndContinue()

        try await waitForEvents(["refresh", "open-desktop"], recorder: recorder)
        #expect(await provider.performSetupCallCount == 1)
    }

    private func makeHarness(
        state: String
    ) -> (
        coordinator: WorkspaceProviderSetupCoordinator,
        runner: WorkspaceProviderSetupActionRunner,
        provider: MockRunnerSetupProvider
    ) {
        let coordinator = WorkspaceProviderSetupCoordinator()
        let provider = MockRunnerSetupProvider(
            requirement: .confirmation(Self.confirmation(state: state))
        )
        let runner = WorkspaceProviderSetupActionRunner(coordinator: coordinator)
        return (coordinator, runner, provider)
    }

    private func waitForEvents(
        _ expectedEvents: [String],
        recorder: RunnerEventRecorder
    ) async throws {
        for _ in 0..<50 {
            if await recorder.snapshot() == expectedEvents {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        Issue.record("Timed out waiting for events: \(expectedEvents.joined(separator: ", "))")
    }

    private static func confirmation(state: String) -> WorkspaceProviderSetupConfirmation {
        WorkspaceProviderSetupConfirmation(
            providerID: LumeWorkspaceProvider.identifier,
            providerDisplayName: "Lume VM",
            state: state,
            title: state == "repairRequired" ? "Repair macOS VM Support" : "Set Up macOS VM Support",
            primaryButtonTitle: state == "repairRequired"
                ? "Repair Lume and Continue"
                : "Install Lume and Continue",
            introductoryText: ["Intro"],
            learnMoreLabel: "Learn more",
            learnMoreURL: URL(string: "https://example.com/setup"),
            explanatoryStepsTitle: "What Workspaces will do",
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

private actor RunnerEventRecorder {
    private var events: [String] = []

    func record(_ value: String) {
        events.append(value)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor MockRunnerSetupProvider: WorkspaceProviderSetupCapable {
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

import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("AppRuntimeDependencies")
struct AppRuntimeDependenciesTests {
    @Test("Fixture environment uses deterministic Lume runtime and provider registry")
    func fixtureEnvironmentUsesDeterministicOverrides() async throws {
        let dependencies = AppRuntimeDependencies.resolved(
            environment: [UIFixtureLumeEnvironment.environmentKey: "1"]
        )

        let snapshot = await dependencies.lumeRuntimeService.snapshot()
        let lumeProvider = dependencies.workspaceProviderRegistry.provider(for: LumeWorkspaceProvider.identifier)
        let daytonaProvider = dependencies.workspaceProviderRegistry.provider(for: DaytonaWorkspaceProvider.identifier)

        #expect(snapshot.state == .setupRequired)
        #expect(snapshot.hostProfile?.displayName == "Tahoe 26.2 + Xcode 26.2")
        #expect(snapshot.defaultMacOSImage?.profileDisplayName == "macOS Tahoe 26.2 + Xcode 26.2")
        #expect(lumeProvider?.descriptor.id == LumeWorkspaceProvider.identifier)
        #expect(daytonaProvider?.descriptor.id == DaytonaWorkspaceProvider.identifier)
    }

    @Test("Fixture Lume runtime transitions to ready after install")
    func fixtureLumeRuntimeTransitionsToReadyAfterInstall() async throws {
        let runtimeService = UIFixtureLumeRuntimeService(
            environment: ["WORKSPACES_UI_FIXTURE_LUME_STEP_DELAY_MS": "1"]
        )

        let beforeInstall = await runtimeService.snapshot()
        _ = try await runtimeService.installIfNeeded(progress: nil)
        let afterInstall = await runtimeService.snapshot()

        #expect(beforeInstall.state == .setupRequired)
        #expect(afterInstall.state == .ready)
        #expect(afterInstall.executablePath?.contains("workspacemanager-ui-fixture-lume") == true)
        #expect(afterInstall.launchAgentInstalled == true)
        #expect(afterInstall.daemonReachable == true)
    }
}

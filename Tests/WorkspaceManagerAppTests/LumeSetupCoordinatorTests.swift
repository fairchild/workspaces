import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("LumeSetupCoordinator")
@MainActor
struct LumeSetupCoordinatorTests {
    @Test("Prepare if needed requests confirmation when setup is required")
    func prepareIfNeededRequestsConfirmation() async throws {
        let runtimeService = MockLumeRuntimeService(
            snapshot: .init(
                state: .setupRequired,
                reason: "Lume is not installed yet.",
                executablePath: nil,
                launchAgentPath: "/Users/test/Library/LaunchAgents/com.trycua.lume_daemon.plist",
                launchAgentInstalled: false,
                daemonReachable: false,
                hostProfile: makeHostProfile(),
                defaultMacOSImage: makeDefaultImageResolution(),
                defaultMacOSImageError: nil,
                infoLogPath: "/tmp/lume_daemon.log",
                errorLogPath: "/tmp/lume_daemon.error.log"
            )
        )
        let coordinator = LumeSetupCoordinator(runtimeService: runtimeService)

        let intercepted = try await coordinator.prepareIfNeeded(
            for: .createWorkspace(name: "feature-vm", guestOS: .macOS)
        ) {}

        #expect(intercepted == true)
        #expect(coordinator.confirmationRequest?.runtimeState == .setupRequired)
        #expect(coordinator.confirmationRequest?.action == .createWorkspace(name: "feature-vm", guestOS: .macOS))
    }

    @Test("Confirm and continue installs then resumes pending action")
    func confirmAndContinueInstallsAndResumes() async throws {
        let runtimeService = MockLumeRuntimeService(
            snapshot: .init(
                state: .setupRequired,
                reason: "Lume is not installed yet.",
                executablePath: nil,
                launchAgentPath: "/Users/test/Library/LaunchAgents/com.trycua.lume_daemon.plist",
                launchAgentInstalled: false,
                daemonReachable: false,
                hostProfile: makeHostProfile(),
                defaultMacOSImage: makeDefaultImageResolution(),
                defaultMacOSImageError: nil,
                infoLogPath: "/tmp/lume_daemon.log",
                errorLogPath: "/tmp/lume_daemon.error.log"
            )
        )
        let coordinator = LumeSetupCoordinator(runtimeService: runtimeService)

        let resumed = LockedFlag()
        let intercepted = try await coordinator.prepareIfNeeded(
            for: .openDesktop(workspaceName: "feature-vm")
        ) {
            await resumed.setTrue()
        }
        #expect(intercepted == true)

        coordinator.confirmAndContinue()
        try await waitUntilTrue(flag: resumed)

        #expect(await runtimeService.installIfNeededCallCount == 1)
        #expect(await runtimeService.repairInstallationCallCount == 0)
        #expect(coordinator.progressPresentation == nil)
        #expect(coordinator.errorMessage == nil)
    }

    @Test("Ready runtime does not intercept the action")
    func readyRuntimeDoesNotIntercept() async throws {
        let runtimeService = MockLumeRuntimeService(
            snapshot: .init(
                state: .ready,
                reason: nil,
                executablePath: "/Users/test/.local/bin/lume",
                launchAgentPath: "/Users/test/Library/LaunchAgents/com.trycua.lume_daemon.plist",
                launchAgentInstalled: true,
                daemonReachable: true,
                hostProfile: makeHostProfile(),
                defaultMacOSImage: makeDefaultImageResolution(),
                defaultMacOSImageError: nil,
                infoLogPath: "/tmp/lume_daemon.log",
                errorLogPath: "/tmp/lume_daemon.error.log"
            )
        )
        let coordinator = LumeSetupCoordinator(runtimeService: runtimeService)

        let intercepted = try await coordinator.prepareIfNeeded(
            for: .openTerminal(workspaceName: "feature-vm")
        ) {}

        #expect(intercepted == false)
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

    private func makeHostProfile() -> LumeHostProfile {
        LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.2",
            xcodeVersion: "26.2",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )
    }

    private func makeDefaultImageResolution() -> LumeImageResolution {
        LumeImageResolution(
            hostProfile: makeHostProfile(),
            entry: LumeRuntimeService.imageCatalog[0],
            matchKind: .exact
        )
    }
}

private actor MockLumeRuntimeService: LumeRuntimeServiceProtocol {
    private var currentSnapshot: LumeRuntimeSnapshot
    private(set) var installIfNeededCallCount = 0
    private(set) var repairInstallationCallCount = 0

    init(snapshot: LumeRuntimeSnapshot) {
        self.currentSnapshot = snapshot
    }

    func snapshot() async -> LumeRuntimeSnapshot {
        currentSnapshot
    }

    func baseVMSnapshot() async -> LumeBaseVMSnapshot? {
        currentSnapshot.baseVM
    }

    func hostProfile() async throws -> LumeHostProfile {
        guard let hostProfile = currentSnapshot.hostProfile else {
            throw LumeRuntimeError.invalidHostProfile("Missing host profile.")
        }
        return hostProfile
    }

    func defaultMacOSImageResolution() async throws -> LumeImageResolution {
        guard let defaultMacOSImage = currentSnapshot.defaultMacOSImage else {
            throw LumeRuntimeError.imageUnavailable("Missing default image.")
        }
        return defaultMacOSImage
    }

    func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        installIfNeededCallCount += 1
        await progress?(.checkingHost)
        await progress?(.installingLume)
        currentSnapshot = LumeRuntimeSnapshot(
            state: .ready,
            reason: nil,
            executablePath: "/Users/test/.local/bin/lume",
            launchAgentPath: currentSnapshot.launchAgentPath,
            launchAgentInstalled: true,
            daemonReachable: true,
            hostProfile: currentSnapshot.hostProfile,
            defaultMacOSImage: currentSnapshot.defaultMacOSImage,
            defaultMacOSImageError: nil,
            baseVM: currentSnapshot.baseVM,
            infoLogPath: currentSnapshot.infoLogPath,
            errorLogPath: currentSnapshot.errorLogPath
        )
        return currentSnapshot
    }

    func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        await progress?(.verifyingDaemon)
        return currentSnapshot
    }

    func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        repairInstallationCallCount += 1
        return currentSnapshot
    }

    func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot {
        guard let baseVM = currentSnapshot.baseVM else {
            throw LumeRuntimeError.baseVMFailed("Missing base VM snapshot.")
        }
        return baseVM
    }

    func deleteBaseVM() async throws -> LumeRuntimeSnapshot {
        currentSnapshot
    }

    func executablePath() async throws -> String {
        guard let executablePath = currentSnapshot.executablePath else {
            throw LumeRuntimeError.installationFailed("Missing executable.")
        }
        return executablePath
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

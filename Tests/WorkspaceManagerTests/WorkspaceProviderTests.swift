import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceProviders")
struct WorkspaceProviderTests {
    @Test("Registry exposes all live providers in order")
    func registryExposesLiveProviders() {
        let registry = WorkspaceProviderRegistry.live

        #expect(
            registry.providers.map { $0.descriptor.id } == [
                LocalWorkspaceProvider.identifier,
                DaytonaWorkspaceProvider.identifier,
                LumeWorkspaceProvider.identifier,
            ])
    }

    @Test("Registry resolves provider for workspace backend identifier")
    func registryResolvesProviderForWorkspace() {
        let registry = WorkspaceProviderRegistry.live
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "vm-workspace",
            path: URL(fileURLWithPath: "/tmp/workspaces/vm-workspace"),
            sourceRepo: repo,
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: "vm-123"
        )

        let provider = registry.provider(for: workspace)

        #expect(provider?.descriptor.id == LumeWorkspaceProvider.identifier)
    }

    @Test("Provider descriptors advertise expected capabilities")
    func providerDescriptorsAdvertiseExpectedCapabilities() throws {
        let registry = WorkspaceProviderRegistry.live

        let local = try #require(registry.provider(for: LocalWorkspaceProvider.identifier))
        let daytona = try #require(registry.provider(for: DaytonaWorkspaceProvider.identifier))
        let lume = try #require(registry.provider(for: LumeWorkspaceProvider.identifier))

        #expect(local.descriptor.usesHostWorkspaceFiles == true)
        #expect(local.descriptor.supportsDesktop == false)

        #expect(daytona.descriptor.supportsArchive == true)
        #expect(daytona.descriptor.requiresRemoteRepository == true)
        #expect(daytona.descriptor.supportedGuestOS == [.linux])

        #expect(lume.descriptor.supportsDesktop == true)
        #expect(lume.descriptor.usesHostWorkspaceFiles == true)
        #expect(lume.descriptor.supportedGuestOS == [.macOS, .linux])
    }

    @Test("Only the Lume provider currently exposes setup capability")
    func providerSetupCapabilityConformance() throws {
        let registry = WorkspaceProviderRegistry.live

        let local = try #require(registry.provider(for: LocalWorkspaceProvider.identifier))
        let daytona = try #require(registry.provider(for: DaytonaWorkspaceProvider.identifier))
        let lume = try #require(registry.provider(for: LumeWorkspaceProvider.identifier))

        #expect((local as? any WorkspaceProviderSetupCapable) == nil)
        #expect((daytona as? any WorkspaceProviderSetupCapable) == nil)
        #expect((lume as? any WorkspaceProviderSetupCapable) != nil)
    }

    @Test("Lume status mapping covers running, stopped, provisioning, and missing")
    func lumeStatusMapping() {
        #expect(LumeWorkspaceProvider.mapStatus("running") == .active)
        #expect(LumeWorkspaceProvider.mapStatus("stopped") == .stopped)
        #expect(LumeWorkspaceProvider.mapStatus("provisioning") == .provisioning)
        #expect(LumeWorkspaceProvider.mapStatus("provisioning (stale)") == .provisioning)
        #expect(LumeWorkspaceProvider.mapStatus("missing") == .archived)
    }

    @Test("Lume progress messaging surfaces macOS download, install, and boot phases")
    func lumeProgressMessaging() {
        let downloadMessage = LumeProgressMessageBuilder.message(
            status: .provisioning,
            guestOS: WorkspaceGuestOS.macOS.rawValue,
            provisioningOperation: "ipsw_install",
            sshAvailable: nil,
            logTail: "[2026-03-09T00:25:24Z] INFO: Downloading IPSW Progress: 99%"
        )
        #expect(downloadMessage == "Downloading macOS image... 99%")

        let installMessage = LumeProgressMessageBuilder.message(
            status: .provisioning,
            guestOS: WorkspaceGuestOS.macOS.rawValue,
            provisioningOperation: "ipsw_install",
            sshAvailable: nil,
            logTail:
                """
                [2026-03-09T00:25:27Z] INFO: Download completed and moved to: /tmp/latest.ipsw
                [2026-03-09T00:25:30Z] INFO: Starting macOS installation
                [2026-03-09T00:25:30Z] INFO: Installing macOS progress=12%
                """
        )
        #expect(installMessage == "Installing macOS... 12%")

        let bootMessage = LumeProgressMessageBuilder.message(
            status: .running,
            guestOS: WorkspaceGuestOS.macOS.rawValue,
            provisioningOperation: nil,
            sshAvailable: false,
            logTail: nil
        )
        #expect(bootMessage == "Booting macOS and waiting for SSH...")

        let linuxBootMessage = LumeProgressMessageBuilder.message(
            status: .running,
            guestOS: WorkspaceGuestOS.linux.rawValue,
            provisioningOperation: nil,
            sshAvailable: false,
            logTail: nil
        )
        #expect(linuxBootMessage == "Booting Linux VM and waiting for SSH...")
    }

    @Test("Lume VM status normalization covers known and unknown states")
    func lumeVMStatusNormalization() {
        #expect(LumeVMStatus(rawValue: "running") == .running)
        #expect(LumeVMStatus(rawValue: "stopped") == .stopped)
        #expect(LumeVMStatus(rawValue: "provisioning") == .provisioning)
        #expect(LumeVMStatus(rawValue: "provisioning (stale)") == .provisioningStale)
        #expect(LumeVMStatus(rawValue: "missing") == .missing)
        #expect(LumeVMStatus(rawValue: "mystery").workspaceStatus == .archived)
    }

    @Test("Lume error heuristics classify fallback and missing VM messages")
    func lumeErrorHeuristics() {
        #expect(
            LumeErrorHeuristics.shouldFallbackToStockImage(
                WorkspaceProviderError.unavailable("Fetch image manifest from registry failed.")
            )
        )
        #expect(
            LumeErrorHeuristics.shouldTreatAsMissingVM(
                WorkspaceProviderError.unavailable("Virtual machine does not exist.")
            )
        )
        #expect(
            !LumeErrorHeuristics.shouldTreatAsMissingVM(
                WorkspaceProviderError.unavailable("A different Lume failure")
            )
        )
    }

    @Test("Lume retries stock macOS provisioning with CLI for daemon async create failures")
    func lumeCLIProvisioningRetrySignals() {
        #expect(
            LumeWorkspaceProvider.shouldRetryMacOSProvisioningWithCLI(
                for: WorkspaceProviderError.unavailable(
                    "The restore image catalog failed to load. Installation service returned an unexpected error."
                )
            )
        )
        #expect(
            LumeWorkspaceProvider.shouldRetryMacOSProvisioningWithCLI(
                for: WorkspaceProviderError.unavailable(
                    "Virtual machine not found: ipxe-ipxe-v13-7a81cd5d"
                )
            )
        )
        #expect(
            !LumeWorkspaceProvider.shouldRetryMacOSProvisioningWithCLI(
                for: WorkspaceProviderError.unavailable("A different Lume failure")
            )
        )
    }

    @Test("Lume defaults to NAT for normal VM creation and macOS runtime boots")
    func lumeDefaultNetworks() {
        #expect(LumeWorkspaceProvider.defaultNetworkMode == "nat")
        #expect(LumeWorkspaceProvider.defaultMacOSRunNetworkMode == "nat")
    }

    @Test("Lume maps Workspaces VM storage path to configured storage name")
    func lumeWorkspaceStorageSelectorMapsWorkspaceVMPath() {
        let workspaceVMStoragePath =
            "/Users/test/Library/Application Support/WorkspaceManager/LumeStorage/workspace-vms"

        #expect(
            LumeWorkspaceProvider.lumeStorageSelector(
                for: workspaceVMStoragePath,
                workspaceVMStoragePath: workspaceVMStoragePath
            ) == "workspaces"
        )
        #expect(
            LumeWorkspaceProvider.lumeStorageSelector(
                for: "\(workspaceVMStoragePath)/",
                workspaceVMStoragePath: workspaceVMStoragePath
            ) == "workspaces"
        )
        #expect(
            LumeWorkspaceProvider.lumeStorageSelector(
                for: "workspaces",
                workspaceVMStoragePath: workspaceVMStoragePath
            ) == "workspaces"
        )
        #expect(
            LumeWorkspaceProvider.lumeStorageSelector(
                for: "/Users/test/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases",
                workspaceVMStoragePath: workspaceVMStoragePath
            ) == "/Users/test/Library/Application Support/WorkspaceManager/LumeStorage/validated-bases"
        )
        #expect(
            LumeWorkspaceProvider.lumeStorageSelector(
                for: nil,
                workspaceVMStoragePath: workspaceVMStoragePath
            ) == nil
        )
    }

    @Test("Lume CLI progress messaging surfaces macOS download, install, and setup phases")
    func lumeCLIProgressMessaging() {
        #expect(
            LumeWorkspaceProvider.cliProvisioningMessage(
                for: "[2026-03-09T03:43:41Z] INFO: Downloading IPSW Progress: 2%"
            ) == "Downloading macOS image... 2%"
        )
        #expect(
            LumeWorkspaceProvider.cliProvisioningMessage(
                for: "[2026-03-09T03:43:43Z] INFO: Installing macOS progress=12%"
            ) == "Installing macOS... 12%"
        )
        #expect(
            LumeWorkspaceProvider.cliProvisioningMessage(
                for: "[2026-03-09T03:43:43Z] INFO: Starting unattended Setup Assistant automation"
            ) == "Configuring macOS..."
        )
    }

    @Test("performSetup sees fresh state even when runtime changes after setupRequirement")
    func performSetupAlwaysTakesFreshSnapshot() async throws {
        // Start as repairRequired, then transition to ready before performSetup runs.
        let runtimeService = SpyLumeRuntimeService(state: .repairRequired)
        let provider = LumeWorkspaceProvider(
            baseURL: URL(string: "http://localhost:7777/lume/")!,
            runtimeService: runtimeService
        )

        let requirement = try await provider.setupRequirement(
            for: .createWorkspace(name: "vm", guestOS: .macOS)
        )
        #expect(requirement != nil, "repairRequired should produce a confirmation")

        // Runtime self-heals between setupRequirement and performSetup.
        await runtimeService.setState(.ready)

        // performSetup must re-probe and see .ready — not act on stale .repairRequired.
        try? await provider.performSetup(progress: nil)

        let callCount = await runtimeService.snapshotCallCount
        #expect(callCount == 2, "performSetup must take its own fresh snapshot")
    }

    @Test("Lume bridged reachability extracts interface and matching ARP IP")
    func lumeBridgedReachabilityParsing() {
        #expect(LumeBridgedVMReachability.bridgedInterface(from: "bridged:en0") == "en0")
        #expect(LumeBridgedVMReachability.bridgedInterface(from: "nat") == nil)

        let arpOutput =
            """
            ? (192.168.8.100) at e:cf:3c:8a:f7:bd on en0 ifscope [ethernet]
            ? (192.168.8.100) at ea:4:3c:6e:f5:71 on en5 ifscope [ethernet]
            ? (192.168.8.122) at 0:e:58:7f:28:2a on en0 ifscope [ethernet]
            """

        let resolvedIP = LumeBridgedVMReachability.ipAddress(
            forMACAddress: "0e:cf:3c:8a:f7:bd",
            interfaceName: "en0",
            arpOutput: arpOutput
        )

        #expect(resolvedIP == "192.168.8.100")
    }
}

// MARK: - Test helpers

/// Minimal LumeRuntimeServiceProtocol spy that counts snapshot() calls and
/// stubs install/verify/repair to return without error.
private actor SpyLumeRuntimeService: LumeRuntimeServiceProtocol {
    private(set) var snapshotCallCount = 0
    private var currentState: LumeRuntimeState

    init(state: LumeRuntimeState) {
        self.currentState = state
    }

    func setState(_ state: LumeRuntimeState) {
        currentState = state
    }

    func snapshot() async -> LumeRuntimeSnapshot {
        snapshotCallCount += 1
        return LumeRuntimeSnapshot(
            state: currentState,
            executablePath: nil,
            launchAgentPath: "/tmp/lume.plist",
            launchAgentInstalled: false,
            daemonReachable: false,
            hostProfile: nil,
            defaultMacOSImage: nil,
            defaultMacOSImageError: nil,
            infoLogPath: "/tmp/lume.log",
            errorLogPath: "/tmp/lume.error.log"
        )
    }

    func baseVMSnapshot() async -> LumeBaseVMSnapshot? { nil }

    func hostProfile() async throws -> LumeHostProfile {
        throw LumeRuntimeError.unsupportedHost("spy")
    }

    func defaultMacOSImageResolution() async throws -> LumeImageResolution {
        throw LumeRuntimeError.imageUnavailable("spy")
    }

    func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        stubbedSnapshot()
    }

    func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        stubbedSnapshot()
    }

    func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        stubbedSnapshot()
    }

    func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot {
        throw LumeRuntimeError.baseVMFailed("spy")
    }

    func deleteBaseVM() async throws -> LumeRuntimeSnapshot {
        stubbedSnapshot()
    }

    func executablePath() async throws -> String {
        throw LumeRuntimeError.unsupportedHost("spy")
    }

    /// Returns a snapshot value without incrementing the call counter.
    private func stubbedSnapshot() -> LumeRuntimeSnapshot {
        LumeRuntimeSnapshot(
            state: currentState,
            executablePath: nil,
            launchAgentPath: "/tmp/lume.plist",
            launchAgentInstalled: false,
            daemonReachable: false,
            hostProfile: nil,
            defaultMacOSImage: nil,
            defaultMacOSImageError: nil,
            infoLogPath: "/tmp/lume.log",
            errorLogPath: "/tmp/lume.error.log"
        )
    }
}

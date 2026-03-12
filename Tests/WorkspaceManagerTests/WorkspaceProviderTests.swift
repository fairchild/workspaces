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
            status: "provisioning",
            guestOS: WorkspaceGuestOS.macOS.rawValue,
            provisioningOperation: "ipsw_install",
            sshAvailable: nil,
            logTail: "[2026-03-09T00:25:24Z] INFO: Downloading IPSW Progress: 99%"
        )
        #expect(downloadMessage == "Downloading macOS image... 99%")

        let installMessage = LumeProgressMessageBuilder.message(
            status: "provisioning",
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
            status: "running",
            guestOS: WorkspaceGuestOS.macOS.rawValue,
            provisioningOperation: nil,
            sshAvailable: false,
            logTail: nil
        )
        #expect(bootMessage == "Booting macOS and waiting for SSH...")

        let linuxBootMessage = LumeProgressMessageBuilder.message(
            status: "running",
            guestOS: WorkspaceGuestOS.linux.rawValue,
            provisioningOperation: nil,
            sshAvailable: false,
            logTail: nil
        )
        #expect(linuxBootMessage == "Booting Linux VM and waiting for SSH...")
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
}

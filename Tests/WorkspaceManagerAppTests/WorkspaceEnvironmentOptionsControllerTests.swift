import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceEnvironmentOptionsController")
struct WorkspaceEnvironmentOptionsControllerTests {
    private let controller = WorkspaceEnvironmentOptionsController()
    private let currentRegistry = WorkspaceProviderRegistry(
        providers: [
            LocalWorkspaceProvider(),
            DaytonaWorkspaceProvider(),
            LumeWorkspaceProvider(),
        ]
    )

    private actor MockLumeRuntimeService: LumeRuntimeServiceProtocol {
        let snapshotDelayNanoseconds: UInt64
        let snapshotValue: LumeRuntimeSnapshot

        init(snapshotDelayNanoseconds: UInt64, snapshotValue: LumeRuntimeSnapshot) {
            self.snapshotDelayNanoseconds = snapshotDelayNanoseconds
            self.snapshotValue = snapshotValue
        }

        func snapshot() async -> LumeRuntimeSnapshot {
            try? await Task.sleep(nanoseconds: snapshotDelayNanoseconds)
            return snapshotValue
        }

        func baseVMSnapshot() async -> LumeBaseVMSnapshot? { snapshotValue.baseVM }
        func hostProfile() async throws -> LumeHostProfile {
            snapshotValue.hostProfile
                ?? LumeHostProfile(
                    architecture: "arm64",
                    macOSFamily: .tahoe,
                    macOSVersion: "26.2",
                    xcodeVersion: "26.2",
                    developerDirectory: "/Applications/Xcode.app/Contents/Developer"
                )
        }
        func defaultMacOSImageResolution() async throws -> LumeImageResolution {
            if let snapshotImage = snapshotValue.defaultMacOSImage {
                return snapshotImage
            }

            guard let macOSCatalogEntry = LumeImageCatalog.default.entries.first(where: { $0.guestOS == .macOS }) else {
                fatalError("Expected a macOS image catalog entry for tests")
            }

            return LumeImageResolution(
                hostProfile: try await hostProfile(),
                entry: macOSCatalogEntry,
                matchKind: .exact
            )
        }
        func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
            snapshotValue
        }
        func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
            snapshotValue
        }
        func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
            snapshotValue
        }
        func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot {
            guard let baseVM = snapshotValue.baseVM else {
                fatalError("Expected base VM in mock runtime service")
            }
            return baseVM
        }
        func deleteBaseVM() async throws -> LumeRuntimeSnapshot { snapshotValue }
        func executablePath() async throws -> String { snapshotValue.executablePath ?? "/tmp/lume" }
    }

    @Test("Nil snapshot keeps the default macOS base summary")
    func nilSnapshotKeepsDefaultMacOSSummary() throws {
        let option = try macOSOption(snapshot: nil)

        #expect(option.subtitle == "Matches this Mac by default")
        #expect(option.statusText == nil)
        #expect(option.availabilityReason == nil)
    }

    @Test("Setup required snapshot surfaces setup messaging for macOS and Linux VM options")
    func setupRequiredSnapshotSurfacesSetupMessaging() throws {
        let snapshot = try makeSnapshot(state: .setupRequired)

        let macOSOption = try macOSOption(snapshot: snapshot)
        #expect(macOSOption.statusText == "Setup required")
        #expect(macOSOption.description.contains("install and verify Lume automatically"))

        let linuxOption = try linuxVMOption(snapshot: snapshot)
        #expect(linuxOption.statusText == "Setup required")
        #expect(linuxOption.description.contains("install and verify Lume automatically"))
    }

    @Test("Repair required snapshot surfaces repair messaging for macOS and Linux VM options")
    func repairRequiredSnapshotSurfacesRepairMessaging() throws {
        let snapshot = try makeSnapshot(state: .repairRequired)

        let macOSOption = try macOSOption(snapshot: snapshot)
        #expect(macOSOption.statusText == "Repair required")
        #expect(macOSOption.description.contains("repair the local VM runtime automatically"))

        let linuxOption = try linuxVMOption(snapshot: snapshot)
        #expect(linuxOption.statusText == "Repair required")
        #expect(linuxOption.description.contains("repair the local VM runtime automatically"))
    }

    @Test("Ready snapshot reflects a prepared base VM")
    func readySnapshotReflectsPreparedBaseVM() throws {
        let baseSnapshot = makeBaseSnapshot(status: .ready)
        let option = try macOSOption(
            snapshot: makeSnapshot(
                state: .ready,
                baseVM: baseSnapshot
            )
        )

        #expect(option.statusText == "Fast clone ready")
        #expect(option.subtitle == "Fast clone ready: \(baseSnapshot.profile.displayName)")
        #expect(option.description.contains("faster macOS workspace start"))
    }

    @Test("Missing stock base snapshot reports one-time preparation and a non-blocking reason")
    func missingStockBaseSnapshotReportsOneTimePreparation() throws {
        let reason = "No prepared base VM exists yet."
        let baseSnapshot = makeBaseSnapshot(
            status: .missing,
            imageReference: nil,
            reason: reason
        )
        let option = try macOSOption(
            snapshot: makeSnapshot(
                state: .ready,
                baseVM: baseSnapshot
            )
        )

        #expect(option.statusText == "Prepares base on first use")
        #expect(option.subtitle == "Needs one-time base preparation")
        #expect(option.description.contains("prepare a stock macOS base VM once"))
        #if arch(arm64)
            #expect(option.availabilityReason == reason)
        #endif
    }

    @Test("Ready snapshot without a matching image falls back to stock macOS")
    func readySnapshotWithoutMatchingImageFallsBackToStockMacOS() throws {
        let option = try macOSOption(
            snapshot: makeSnapshot(
                state: .ready,
                usesDefaultMacOSImage: false,
                defaultMacOSImageError: "No host-matched image available."
            )
        )

        #expect(option.statusText == "Stock macOS")
        #expect(option.description.contains("fall back to stock macOS setup automatically"))
        #if arch(arm64)
            #expect(
                option.availabilityReason
                    == "Workspaces will use stock macOS because no host-matched golden image is available yet."
            )
        #endif
    }

    @Test("Unsupported host snapshot disables both Lume options")
    func unsupportedHostSnapshotDisablesBothLumeOptions() throws {
        let snapshot = try makeSnapshot(
            state: .unsupportedHost,
            reason: "Lume requires Apple Silicon."
        )

        let macOSOption = try macOSOption(snapshot: snapshot)
        #expect(!macOSOption.isAvailable)
        #expect(macOSOption.availabilityReason == "Lume requires Apple Silicon.")

        let linuxOption = try linuxVMOption(snapshot: snapshot)
        #expect(!linuxOption.isAvailable)
        #expect(linuxOption.availabilityReason == "Lume requires Apple Silicon.")
    }

    @Test("Environment options follow registry and guest OS order")
    func environmentOptionsFollowRegistryOrder() {
        let options = environmentOptions(snapshot: nil)

        #expect(
            options.map(\.id)
                == [
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: LocalWorkspaceProvider.identifier,
                        guestOS: nil
                    ),
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: DaytonaWorkspaceProvider.identifier,
                        guestOS: .linux
                    ),
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: LumeWorkspaceProvider.identifier,
                        guestOS: .macOS
                    ),
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: LumeWorkspaceProvider.identifier,
                        guestOS: .linux
                    ),
                ]
        )
    }

    @Test("Removing Lume from the registry removes Lume environment options")
    func removingLumeFromRegistryRemovesLumeOptions() {
        let registry = WorkspaceProviderRegistry(
            providers: [
                LocalWorkspaceProvider(),
                DaytonaWorkspaceProvider(),
            ]
        )

        let options = environmentOptions(snapshot: nil, registry: registry)

        #expect(
            options.map(\.id)
                == [
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: LocalWorkspaceProvider.identifier,
                        guestOS: nil
                    ),
                    WorkspaceEnvironmentSheetOption.selectionID(
                        providerID: DaytonaWorkspaceProvider.identifier,
                        guestOS: .linux
                    ),
                ]
        )
        #expect(options.allSatisfy { $0.providerID != LumeWorkspaceProvider.identifier })
    }

    @Test("Unknown provider registrations fall back to generic environment options")
    func unknownProviderRegistrationsFallBackToGenericOptions() throws {
        let registry = WorkspaceProviderRegistry(
            providers: [
                LocalWorkspaceProvider(),
                MockDescriptorProvider(
                    descriptor: WorkspaceProviderDescriptor(
                        id: "custom-host",
                        displayName: "Custom Host",
                        description: "Runs a custom host-backed environment.",
                        usesHostWorkspaceFiles: true
                    )
                ),
                MockDescriptorProvider(
                    descriptor: WorkspaceProviderDescriptor(
                        id: "custom-remote",
                        displayName: "Custom Remote",
                        description: "Runs custom remote guests.",
                        supportedGuestOS: [.linux, .macOS],
                        supportsDesktop: true,
                        requiresRemoteRepository: true
                    )
                ),
            ]
        )

        let options = environmentOptions(snapshot: nil, registry: registry)

        let customHost = try #require(
            options.first {
                $0.providerID == "custom-host" && $0.guestOS == nil
            }
        )
        #expect(customHost.title == "Custom Host")
        #expect(customHost.subtitle == "Runs on this Mac with host files")
        #expect(customHost.iconName == "plus.rectangle.on.folder.fill")

        let customLinux = try #require(
            options.first {
                $0.providerID == "custom-remote" && $0.guestOS == .linux
            }
        )
        #expect(customLinux.title == "Custom Remote Linux")
        #expect(customLinux.subtitle == "Runs Linux via Custom Remote")
        #expect(customLinux.iconName == "cloud.fill")

        let customMacOS = try #require(
            options.first {
                $0.providerID == "custom-remote" && $0.guestOS == .macOS
            }
        )
        #expect(customMacOS.title == "Custom Remote macOS")
        #expect(customMacOS.subtitle == "Runs macOS via Custom Remote")
        #expect(customMacOS.iconName == "desktopcomputer")
    }

    @Test("Lume snapshot refresh returns the latest snapshot before timeout")
    func lumeSnapshotRefreshReturnsLatestSnapshot() async throws {
        let expectedSnapshot = try makeSnapshot(state: .ready)
        let service = MockLumeRuntimeService(
            snapshotDelayNanoseconds: 5_000_000,
            snapshotValue: expectedSnapshot
        )

        let refreshedSnapshot = await controller.refreshLumeRuntimeSnapshot(
            runtimeService: service,
            existingSnapshot: nil,
            trigger: "test",
            timeoutNanoseconds: 100_000_000
        )

        #expect(refreshedSnapshot == expectedSnapshot)
    }

    @Test("Lume snapshot refresh keeps the previous snapshot on timeout")
    func lumeSnapshotRefreshFallsBackToExistingSnapshotOnTimeout() async throws {
        let existingSnapshot = try makeSnapshot(state: .repairRequired)
        let latestSnapshot = try makeSnapshot(state: .ready)
        let service = MockLumeRuntimeService(
            snapshotDelayNanoseconds: 100_000_000,
            snapshotValue: latestSnapshot
        )

        let refreshedSnapshot = await controller.refreshLumeRuntimeSnapshot(
            runtimeService: service,
            existingSnapshot: existingSnapshot,
            trigger: "test",
            timeoutNanoseconds: 5_000_000
        )

        #expect(refreshedSnapshot == existingSnapshot)
    }

    private func macOSOption(snapshot: LumeRuntimeSnapshot?) throws -> WorkspaceEnvironmentSheetOption {
        try option(
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .macOS,
            snapshot: snapshot
        )
    }

    private func linuxVMOption(snapshot: LumeRuntimeSnapshot?) throws -> WorkspaceEnvironmentSheetOption {
        try option(
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .linux,
            snapshot: snapshot
        )
    }

    private func option(
        providerID: String,
        guestOS: WorkspaceGuestOS?,
        snapshot: LumeRuntimeSnapshot?,
        registry: WorkspaceProviderRegistry? = nil
    ) throws -> WorkspaceEnvironmentSheetOption {
        try #require(
            environmentOptions(snapshot: snapshot, registry: registry).first {
                $0.providerID == providerID && $0.guestOS == guestOS
            }
        )
    }

    private func environmentOptions(
        snapshot: LumeRuntimeSnapshot?,
        registry: WorkspaceProviderRegistry? = nil
    ) -> [WorkspaceEnvironmentSheetOption] {
        controller.environmentOptions(
            for: Repo(
                name: "alpha",
                localPath: URL(fileURLWithPath: "/tmp/alpha"),
                remoteURL: "https://github.com/example/alpha.git"
            ),
            registry: registry ?? currentRegistry,
            providerAvailabilityByID: [:],
            isRefreshingProviderAvailability: false,
            lumeRuntimeSnapshot: snapshot
        )
    }

    private func makeSnapshot(
        state: LumeRuntimeState,
        reason: String? = nil,
        defaultMacOSImage: LumeImageResolution? = nil,
        usesDefaultMacOSImage: Bool = true,
        defaultMacOSImageError: String? = nil,
        baseVM: LumeBaseVMSnapshot? = nil
    ) throws -> LumeRuntimeSnapshot {
        let resolvedDefaultMacOSImage: LumeImageResolution? =
            if let defaultMacOSImage {
                defaultMacOSImage
            } else if usesDefaultMacOSImage {
                try makeDefaultImageResolution()
            } else {
                nil
            }

        return LumeRuntimeSnapshot(
            state: state,
            reason: reason,
            executablePath: state == .ready ? "/Users/test/.local/bin/lume" : nil,
            launchAgentPath: "/Users/test/Library/LaunchAgents/com.trycua.lume_daemon.plist",
            launchAgentInstalled: state == .ready,
            daemonReachable: state == .ready,
            hostProfile: makeHostProfile(),
            defaultMacOSImage: resolvedDefaultMacOSImage,
            defaultMacOSImageError: defaultMacOSImageError,
            baseVM: baseVM,
            infoLogPath: "/tmp/lume_daemon.log",
            errorLogPath: "/tmp/lume_daemon.error.log"
        )
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

    private func makeBaseSnapshot(
        status: LumeBaseVMStatus,
        imageReference: String? = "ghcr.io/fairchild/macos-base:tahoe",
        reason: String? = nil
    ) -> LumeBaseVMSnapshot {
        let profile = LumeBaseVMProfile(
            vmName: "base-tahoe-26-2",
            profileKey: "tahoe-26.2-xcode-26.2",
            displayName: "Tahoe 26.2 + Xcode 26.2",
            imageReference: imageReference,
            preferredSourceKind: imageReference == nil ? .stockPrepared : .pulledImage,
            storagePath: "/tmp/lume/base-tahoe-26-2"
        )

        return LumeBaseVMSnapshot(
            profile: profile,
            status: status,
            sourceKind: imageReference == nil ? .stockPrepared : .pulledImage,
            vmStatus: nil,
            reason: reason
        )
    }

    private func makeDefaultImageResolution() throws -> LumeImageResolution {
        let macOSCatalogEntry = try #require(
            LumeImageCatalog.default.entries.first { $0.guestOS == .macOS }
        )

        return LumeImageResolution(
            hostProfile: makeHostProfile(),
            entry: macOSCatalogEntry,
            matchKind: .exact
        )
    }
}

private actor MockDescriptorProvider: WorkspaceProviderProtocol {
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

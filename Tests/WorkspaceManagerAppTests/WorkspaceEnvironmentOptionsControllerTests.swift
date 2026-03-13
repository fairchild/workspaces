import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("WorkspaceEnvironmentOptionsController")
struct WorkspaceEnvironmentOptionsControllerTests {
    private let controller = WorkspaceEnvironmentOptionsController()

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

    private func macOSOption(snapshot: LumeRuntimeSnapshot?) throws -> WorkspaceEnvironmentSheetOption {
        try #require(environmentOptions(snapshot: snapshot).first { $0.kind == .macOSVM })
    }

    private func linuxVMOption(snapshot: LumeRuntimeSnapshot?) throws -> WorkspaceEnvironmentSheetOption {
        try #require(environmentOptions(snapshot: snapshot).first { $0.kind == .linuxVM })
    }

    private func environmentOptions(snapshot: LumeRuntimeSnapshot?) -> [WorkspaceEnvironmentSheetOption] {
        controller.environmentOptions(
            for: Repo(
                name: "alpha",
                localPath: URL(fileURLWithPath: "/tmp/alpha"),
                remoteURL: "https://github.com/example/alpha.git"
            ),
            registry: WorkspaceProviderRegistry(providers: []),
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
            LumeRuntimeService.imageCatalog.first { $0.guestOS == .macOS }
        )

        return LumeImageResolution(
            hostProfile: makeHostProfile(),
            entry: macOSCatalogEntry,
            matchKind: .exact
        )
    }
}

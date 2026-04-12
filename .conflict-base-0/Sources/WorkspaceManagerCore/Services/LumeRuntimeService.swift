//
//  LumeRuntimeService.swift
//  WorkspaceManagerCore
//
//  Runtime setup, verification, and host-profile detection for Lume.
//

import Foundation

public enum LumeRuntimeState: String, Sendable, Equatable {
    case unsupportedHost
    case setupRequired
    case installing
    case verifying
    case ready
    case repairRequired

    public var label: String {
        switch self {
        case .unsupportedHost:
            return "Unsupported"
        case .setupRequired:
            return "Setup Required"
        case .installing:
            return "Installing"
        case .verifying:
            return "Verifying"
        case .ready:
            return "Ready"
        case .repairRequired:
            return "Repair Required"
        }
    }
}

public enum LumeRuntimeSetupStep: String, CaseIterable, Sendable, Equatable {
    case checkingHost
    case downloadingInstaller
    case installingLume
    case startingBackgroundService
    case verifyingDaemon
    case resolvingDefaultVMImage
    case continuingRequestedAction

    public var label: String {
        switch self {
        case .checkingHost:
            return "Checking this Mac"
        case .downloadingInstaller:
            return "Downloading Lume installer"
        case .installingLume:
            return "Installing Lume"
        case .startingBackgroundService:
            return "Starting background service"
        case .verifyingDaemon:
            return "Verifying daemon"
        case .resolvingDefaultVMImage:
            return "Resolving default VM image"
        case .continuingRequestedAction:
            return "Continuing requested action"
        }
    }
}

public typealias LumeRuntimeProgressHandler = @MainActor @Sendable (LumeRuntimeSetupStep) async -> Void

public enum LumeMacOSFamily: String, Codable, Sendable, Equatable, CaseIterable {
    case tahoe
    case sequoia
    case sonoma

    public var label: String {
        switch self {
        case .tahoe:
            return "Tahoe"
        case .sequoia:
            return "Sequoia"
        case .sonoma:
            return "Sonoma"
        }
    }

    public static func fromProductVersion(_ version: String) -> LumeMacOSFamily? {
        guard let major = VersionNumber(version)?.segments.first else {
            return nil
        }

        switch major {
        case 26:
            return .tahoe
        case 15:
            return .sequoia
        case 14:
            return .sonoma
        default:
            return nil
        }
    }
}

public struct LumeHostProfile: Sendable, Equatable {
    public let architecture: String
    public let macOSFamily: LumeMacOSFamily
    public let macOSVersion: String
    public let xcodeVersion: String?
    public let developerDirectory: String?

    public init(
        architecture: String,
        macOSFamily: LumeMacOSFamily,
        macOSVersion: String,
        xcodeVersion: String?,
        developerDirectory: String?
    ) {
        self.architecture = architecture
        self.macOSFamily = macOSFamily
        self.macOSVersion = macOSVersion
        self.xcodeVersion = xcodeVersion
        self.developerDirectory = developerDirectory
    }

    public var profileKey: String {
        if let xcodeVersion, !xcodeVersion.isEmpty {
            return "\(macOSFamily.rawValue)-\(macOSVersion)-xcode-\(xcodeVersion)"
        }
        return "\(macOSFamily.rawValue)-\(macOSVersion)"
    }

    public var displayName: String {
        if let xcodeVersion, !xcodeVersion.isEmpty {
            return "\(macOSFamily.label) \(macOSVersion) + Xcode \(xcodeVersion)"
        }
        return "\(macOSFamily.label) \(macOSVersion)"
    }

    public static func parse(
        architecture: String,
        swVersOutput: String,
        xcodebuildOutput: String?,
        developerDirectoryOutput: String?
    ) throws -> LumeHostProfile {
        guard architecture == "arm64" else {
            throw LumeRuntimeError.unsupportedHost("Lume requires Apple Silicon.")
        }

        let macOSVersion = try parseProductVersion(from: swVersOutput)
        guard let macOSFamily = LumeMacOSFamily.fromProductVersion(macOSVersion) else {
            throw LumeRuntimeError.unsupportedHost(
                "This Mac is running an unsupported macOS version: \(macOSVersion)."
            )
        }

        return LumeHostProfile(
            architecture: architecture,
            macOSFamily: macOSFamily,
            macOSVersion: macOSVersion,
            xcodeVersion: parseXcodeVersion(from: xcodebuildOutput),
            developerDirectory: normalizeSingleLine(developerDirectoryOutput)
        )
    }

    private static func parseProductVersion(from output: String) throws -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        if let versionLine = lines.first(where: { $0.contains("ProductVersion") }) {
            let components = versionLine.split(separator: ":")
            if let rawVersion = components.last?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawVersion.isEmpty
            {
                return rawVersion
            }
        }

        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOutput.isEmpty {
            return trimmedOutput
        }

        throw LumeRuntimeError.invalidHostProfile("Could not detect the host macOS version.")
    }

    private static func parseXcodeVersion(from output: String?) -> String? {
        guard let output else { return nil }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return nil }

        for line in trimmedOutput.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("Xcode ") {
                return String(trimmedLine.dropFirst("Xcode ".count))
            }
        }

        return nil
    }

    private static func normalizeSingleLine(_ output: String?) -> String? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum LumeBaseVMSourceKind: String, Codable, Sendable, Equatable {
    case pulledImage
    case stockPrepared

    public var label: String {
        switch self {
        case .pulledImage:
            return "Golden image"
        case .stockPrepared:
            return "Stock macOS base"
        }
    }
}

public enum LumeBaseVMStatus: String, Sendable, Equatable {
    case missing
    case preparing
    case ready
    case repairRequired

    public var label: String {
        switch self {
        case .missing:
            return "Missing"
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .repairRequired:
            return "Repair Required"
        }
    }
}

public struct LumeBaseVMProfile: Sendable, Equatable {
    public let vmName: String
    public let profileKey: String
    public let displayName: String
    public let imageReference: String?
    public let preferredSourceKind: LumeBaseVMSourceKind
    public let storagePath: String

    public init(
        vmName: String,
        profileKey: String,
        displayName: String,
        imageReference: String?,
        preferredSourceKind: LumeBaseVMSourceKind,
        storagePath: String
    ) {
        self.vmName = vmName
        self.profileKey = profileKey
        self.displayName = displayName
        self.imageReference = imageReference
        self.preferredSourceKind = preferredSourceKind
        self.storagePath = storagePath
    }
}

public struct LumeBaseVMSnapshot: Sendable, Equatable {
    public let profile: LumeBaseVMProfile
    public let status: LumeBaseVMStatus
    public let sourceKind: LumeBaseVMSourceKind?
    public let vmStatus: String?
    public let reason: String?

    public init(
        profile: LumeBaseVMProfile,
        status: LumeBaseVMStatus,
        sourceKind: LumeBaseVMSourceKind?,
        vmStatus: String?,
        reason: String?
    ) {
        self.profile = profile
        self.status = status
        self.sourceKind = sourceKind
        self.vmStatus = vmStatus
        self.reason = reason
    }
}

public struct LumeRuntimeSnapshot: Sendable, Equatable {
    public let state: LumeRuntimeState
    public let reason: String?
    public let executablePath: String?
    public let launchAgentPath: String
    public let launchAgentInstalled: Bool
    public let daemonReachable: Bool
    public let hostProfile: LumeHostProfile?
    public let defaultMacOSImage: LumeImageResolution?
    public let defaultMacOSImageError: String?
    public let baseVM: LumeBaseVMSnapshot?
    public let infoLogPath: String
    public let errorLogPath: String

    public init(
        state: LumeRuntimeState,
        reason: String? = nil,
        executablePath: String?,
        launchAgentPath: String,
        launchAgentInstalled: Bool,
        daemonReachable: Bool,
        hostProfile: LumeHostProfile?,
        defaultMacOSImage: LumeImageResolution?,
        defaultMacOSImageError: String?,
        baseVM: LumeBaseVMSnapshot? = nil,
        infoLogPath: String,
        errorLogPath: String
    ) {
        self.state = state
        self.reason = reason
        self.executablePath = executablePath
        self.launchAgentPath = launchAgentPath
        self.launchAgentInstalled = launchAgentInstalled
        self.daemonReachable = daemonReachable
        self.hostProfile = hostProfile
        self.defaultMacOSImage = defaultMacOSImage
        self.defaultMacOSImageError = defaultMacOSImageError
        self.baseVM = baseVM
        self.infoLogPath = infoLogPath
        self.errorLogPath = errorLogPath
    }
}

public enum LumeRuntimeError: LocalizedError, Sendable {
    case unsupportedHost(String)
    case invalidHostProfile(String)
    case installationFailed(String)
    case verificationFailed(String)
    case imageUnavailable(String)
    case baseVMFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost(let message),
            .invalidHostProfile(let message),
            .installationFailed(let message),
            .verificationFailed(let message),
            .imageUnavailable(let message),
            .baseVMFailed(let message):
            return message
        }
    }
}

public protocol LumeRuntimeServiceProtocol: Sendable {
    func snapshot() async -> LumeRuntimeSnapshot
    func baseVMSnapshot() async -> LumeBaseVMSnapshot?
    func hostProfile() async throws -> LumeHostProfile
    func defaultMacOSImageResolution() async throws -> LumeImageResolution
    func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot
    func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot
    func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot
    func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot
    func deleteBaseVM() async throws -> LumeRuntimeSnapshot
    func executablePath() async throws -> String
}

public actor LumeRuntimeService: LumeRuntimeServiceProtocol {
    public static let shared = LumeRuntimeService()

    private let httpClient: LumeHTTPClient
    private let imageCatalog: LumeImageCatalog
    private let installerURL: URL
    private let urlSession: URLSession
    private let fileManager: FileManager
    private let validatedBaseService: LumeValidatedBaseService
    private var cachedExecutablePath: String?
    private var transientState: LumeRuntimeState?

    private let launchAgentName = "com.trycua.lume_daemon.plist"
    private let installDirectoryName = ".local/bin"
    private let infoLogPath = "/tmp/lume_daemon.log"
    private let errorLogPath = "/tmp/lume_daemon.error.log"
    private let daemonStartupTimeout: TimeInterval = 30
    private let daemonPollIntervalNanoseconds: UInt64 = 1_000_000_000
    private let baseProvisioningTimeout: TimeInterval = 60 * 60
    private let basePollIntervalNanoseconds: UInt64 = 2_000_000_000
    private let defaultCPUCount = 4
    private let defaultMemory = "8GB"
    private let defaultDiskSize = "50GB"
    private let defaultDisplay = "1024x768"
    private let defaultNetwork = "nat"

    public init(
        baseURL: URL = URL(string: "http://localhost:7777/lume/")!,
        installerURL: URL = URL(
            string: "https://raw.githubusercontent.com/trycua/cua/main/libs/lume/scripts/install.sh"
        )!,
        imageCatalog: LumeImageCatalog = .default,
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default,
        validatedBaseService: LumeValidatedBaseService = .shared
    ) {
        self.httpClient = LumeHTTPClient(baseURL: baseURL)
        self.imageCatalog = imageCatalog
        self.installerURL = installerURL
        self.urlSession = urlSession
        self.fileManager = fileManager
        self.validatedBaseService = validatedBaseService
    }

    public func snapshot() async -> LumeRuntimeSnapshot {
        let snapshotStartedAt = Date()
        let launchAgentPath = launchAgentURL.path
        let executablePath = await executablePathIfInstalled()
        let launchAgentInstalled = fileManager.fileExists(atPath: launchAgentPath)
        let daemonReachable = await daemonIsReachable()

        let hostProfile: LumeHostProfile?
        let hostProfileError: Error?
        do {
            hostProfile = try await self.hostProfile()
            hostProfileError = nil
        } catch {
            hostProfile = nil
            hostProfileError = error
        }

        var defaultMacOSImage: LumeImageResolution?
        var defaultMacOSImageError: String?
        if let hostProfile {
            do {
                defaultMacOSImage = try imageCatalog.resolveDefaultMacOSImage(for: hostProfile)
            } catch {
                defaultMacOSImageError = error.localizedDescription
            }
        } else if let hostProfileError {
            defaultMacOSImageError = hostProfileError.localizedDescription
        }

        let state: LumeRuntimeState
        let reason: String?
        if let transientState {
            state = transientState
            reason = nil
        } else if ProcessInfo.processInfo.machineArchitecture != "arm64" {
            state = .unsupportedHost
            reason = "Lume requires Apple Silicon."
        } else if executablePath == nil {
            state = .setupRequired
            reason = "Lume is not installed yet."
        } else if !daemonReachable {
            state = .repairRequired
            reason = "The Lume daemon is not reachable on localhost:7777."
        } else if !launchAgentInstalled {
            state = .ready
            reason = "The Lume daemon is reachable, but the LaunchAgent is missing."
        } else {
            state = .ready
            reason = nil
        }

        let baseVM: LumeBaseVMSnapshot?
        if let hostProfile {
            let profile = await validatedBaseService.resolveBaseVMProfile(
                hostProfile: hostProfile,
                imageResolution: defaultMacOSImage
            )
            let manifest = await validatedBaseService.loadManifest(named: profile.vmName)
            if executablePath == nil {
                baseVM = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .missing,
                    sourceKind: manifest?.sourceKind,
                    vmStatus: nil,
                    reason: "Set up Lume to prepare the local base macOS VM."
                )
            } else if !daemonReachable {
                baseVM = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .repairRequired,
                    sourceKind: manifest?.sourceKind,
                    vmStatus: nil,
                    reason: "The Lume daemon must be reachable to inspect or prepare the local base macOS VM."
                )
            } else {
                baseVM = await inspectBaseVM(profile: profile, manifest: manifest)
            }
        } else {
            baseVM = nil
        }

        let snapshot = LumeRuntimeSnapshot(
            state: state,
            reason: reason,
            executablePath: executablePath,
            launchAgentPath: launchAgentPath,
            launchAgentInstalled: launchAgentInstalled,
            daemonReachable: daemonReachable,
            hostProfile: hostProfile,
            defaultMacOSImage: defaultMacOSImage,
            defaultMacOSImageError: defaultMacOSImageError,
            baseVM: baseVM,
            infoLogPath: infoLogPath,
            errorLogPath: errorLogPath
        )

        NSLog(
            "[Perf] metric=lume_runtime_snapshot duration_ms=%.2f state=%@ daemon_reachable=%@ base_vm_status=%@",
            Date().timeIntervalSince(snapshotStartedAt) * 1000,
            snapshot.state.rawValue,
            daemonReachable ? "true" : "false",
            snapshot.baseVM?.status.rawValue ?? "none"
        )

        return snapshot
    }

    public func baseVMSnapshot() async -> LumeBaseVMSnapshot? {
        await snapshot().baseVM
    }

    public func hostProfile() async throws -> LumeHostProfile {
        let hostProfileStartedAt = Date()
        do {
            let profile = try LumeHostProfile.parse(
                architecture: ProcessInfo.processInfo.machineArchitecture,
                swVersOutput: try await commandOutput(
                    executable: "/usr/bin/sw_vers",
                    arguments: ["-productVersion"]
                ),
                xcodebuildOutput: try? await commandOutput(
                    executable: "/usr/bin/xcodebuild",
                    arguments: ["-version"]
                ),
                developerDirectoryOutput: try? await commandOutput(
                    executable: "/usr/bin/xcode-select",
                    arguments: ["-p"]
                )
            )

            NSLog(
                "[Perf] metric=lume_runtime_host_profile duration_ms=%.2f outcome=success macos_family=%@ xcode=%@",
                Date().timeIntervalSince(hostProfileStartedAt) * 1000,
                profile.macOSFamily.rawValue,
                profile.xcodeVersion == nil ? "absent" : "present"
            )
            return profile
        } catch {
            NSLog(
                "[Perf] metric=lume_runtime_host_profile duration_ms=%.2f outcome=failure",
                Date().timeIntervalSince(hostProfileStartedAt) * 1000
            )
            throw error
        }
    }

    public func defaultMacOSImageResolution() async throws -> LumeImageResolution {
        let hostProfile = try await hostProfile()
        return try imageCatalog.resolveDefaultMacOSImage(for: hostProfile)
    }

    public func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        let currentSnapshot = await snapshot()
        switch currentSnapshot.state {
        case .ready:
            return currentSnapshot
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost(
                currentSnapshot.reason ?? "Lume is unsupported on this Mac."
            )
        case .setupRequired:
            return try await runInstaller(progress: progress)
        case .repairRequired:
            return try await repairInstallation(progress: progress)
        case .installing, .verifying:
            return await snapshot()
        }
    }

    public func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        transientState = .verifying
        defer { transientState = nil }

        await progress?(.checkingHost)
        _ = try await hostProfile()

        await progress?(.verifyingDaemon)
        _ = try await executablePath()
        guard fileManager.fileExists(atPath: launchAgentURL.path) else {
            throw LumeRuntimeError.verificationFailed("The Lume LaunchAgent is missing.")
        }
        try await waitForDaemon()

        await progress?(.resolvingDefaultVMImage)
        _ = try await defaultMacOSImageResolution()

        let verifiedSnapshot = await snapshot()
        guard verifiedSnapshot.state == .ready else {
            throw LumeRuntimeError.verificationFailed(
                verifiedSnapshot.reason ?? "Lume verification did not complete successfully."
            )
        }

        return verifiedSnapshot
    }

    public func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        try await runInstaller(progress: progress)
    }

    public func ensureBaseVMReady(
        progress: WorkspaceProviderProgressHandler?
    ) async throws -> LumeBaseVMSnapshot {
        let currentSnapshot = await snapshot()
        switch currentSnapshot.state {
        case .ready:
            break
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost(
                currentSnapshot.reason ?? "Lume is unsupported on this Mac."
            )
        case .setupRequired:
            throw LumeRuntimeError.installationFailed(
                currentSnapshot.reason ?? "Lume must be installed before preparing a base VM."
            )
        case .repairRequired:
            throw LumeRuntimeError.verificationFailed(
                currentSnapshot.reason ?? "Repair the Lume runtime before preparing a base VM."
            )
        case .installing, .verifying:
            throw LumeRuntimeError.verificationFailed("Wait for the current Lume runtime action to finish.")
        }

        let hostProfile = try await hostProfile()
        let imageResolution = try? await defaultMacOSImageResolution()
        let profile = await validatedBaseService.resolveBaseVMProfile(
            hostProfile: hostProfile,
            imageResolution: imageResolution
        )

        let existingManifest = await validatedBaseService.loadManifest(named: profile.vmName)
        let inspectedBaseVM = await inspectBaseVM(
            profile: profile,
            manifest: existingManifest
        )
        guard var existingSnapshot = inspectedBaseVM else {
            throw LumeRuntimeError.baseVMFailed(
                "No validated base macOS VM exists yet. Run the standalone Lume validation gate first."
            )
        }

        switch existingSnapshot.status {
        case .ready:
            if existingSnapshot.normalizedVMStatus == .running {
                await progress?("Stopping validated base macOS VM...")
                try await stopVM(named: profile.vmName)
                existingSnapshot = try await waitForBaseVMReady(
                    profile: profile,
                    progress: progress,
                    preferredSourceKind: existingSnapshot.sourceKind ?? profile.preferredSourceKind
                )
            }
            await persistBaseManifest(
                profile: profile,
                sourceKind: existingSnapshot.sourceKind ?? profile.preferredSourceKind
            )
            return existingSnapshot

        case .preparing:
            throw LumeRuntimeError.baseVMFailed(
                existingSnapshot.reason
                    ?? "The validated base macOS VM is still being prepared. Finish standalone validation first."
            )

        case .repairRequired:
            throw LumeRuntimeError.baseVMFailed(
                existingSnapshot.reason
                    ?? "The validated base macOS VM needs repair. Run the standalone Lume validation gate again."
            )

        case .missing:
            throw LumeRuntimeError.baseVMFailed(
                existingSnapshot.reason
                    ?? "No validated base macOS VM exists yet. Run the standalone Lume validation gate first."
            )
        }
    }

    public func deleteBaseVM() async throws -> LumeRuntimeSnapshot {
        guard let currentBase = await baseVMSnapshot() else {
            return await snapshot()
        }

        try await deleteBaseVMIfPresent(profile: currentBase.profile, currentSnapshot: currentBase)

        return await snapshot()
    }

    public func executablePath() async throws -> String {
        if let executablePath = await executablePathIfInstalled() {
            return executablePath
        }

        throw LumeRuntimeError.installationFailed("Could not find the `lume` executable.")
    }

    private func runInstaller(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        transientState = .installing
        defer { transientState = nil }

        await progress?(.checkingHost)
        _ = try await hostProfile()

        await progress?(.downloadingInstaller)
        let installerScriptURL = try await downloadInstallerScript()
        defer { try? fileManager.removeItem(at: installerScriptURL) }

        await progress?(.installingLume)
        try await runInstallerScript(at: installerScriptURL)

        await progress?(.startingBackgroundService)
        guard fileManager.fileExists(atPath: launchAgentURL.path) else {
            throw LumeRuntimeError.installationFailed("The Lume installer did not create the LaunchAgent.")
        }

        return try await verifyInstallation(progress: progress)
    }

    private func inspectBaseVM(
        profile: LumeBaseVMProfile,
        manifest: LumeValidatedBaseManifest?
    ) async -> LumeBaseVMSnapshot? {
        let inspectionStartedAt = Date()
        var snapshot: LumeBaseVMSnapshot?
        defer {
            NSLog(
                "[Perf] metric=lume_runtime_base_vm_inspection duration_ms=%.2f vm_name=%@ status=%@",
                Date().timeIntervalSince(inspectionStartedAt) * 1000,
                profile.vmName,
                snapshot?.status.rawValue ?? "none"
            )
        }

        do {
            let details = try await getVM(named: profile.vmName, storagePath: profile.storagePath)
            let sourceKind = manifest?.sourceKind ?? profile.preferredSourceKind
            let validationReason =
                await validatedBaseService.validationReason(
                    for: manifest,
                    expectedProfileKey: profile.profileKey
                )
            switch details.normalizedStatus {
            case .running:
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: validationReason == nil ? .ready : .repairRequired,
                    sourceKind: sourceKind,
                    vmStatus: details.status,
                    reason: validationReason
                        ?? "The validated base macOS VM is running. Workspaces will stop it before cloning."
                )
            case .stopped:
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: validationReason == nil ? .ready : .repairRequired,
                    sourceKind: sourceKind,
                    vmStatus: details.status,
                    reason: validationReason
                        ?? "Fast macOS VM clones are ready."
                )
            case .provisioning, .provisioningStale:
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .preparing,
                    sourceKind: sourceKind,
                    vmStatus: details.status,
                    reason: "The prepared base macOS VM is still being provisioned."
                )
            default:
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .repairRequired,
                    sourceKind: sourceKind,
                    vmStatus: details.status,
                    reason: "The prepared base macOS VM is in an unexpected state: \(details.status)."
                )
            }
        } catch {
            guard LumeErrorHeuristics.shouldTreatAsMissingVM(error) else {
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .repairRequired,
                    sourceKind: manifest?.sourceKind ?? profile.preferredSourceKind,
                    vmStatus: nil,
                    reason: error.localizedDescription
                )
                return snapshot
            }

            if await validatedBaseService.vmDirectoryExists(
                vmName: profile.vmName,
                storagePath: profile.storagePath
            ) {
                snapshot = LumeBaseVMSnapshot(
                    profile: profile,
                    status: .repairRequired,
                    sourceKind: manifest?.sourceKind ?? profile.preferredSourceKind,
                    vmStatus: nil,
                    reason: "A stale validated base macOS VM directory exists on disk, but Lume cannot resolve it."
                )
                return snapshot
            }

            snapshot = LumeBaseVMSnapshot(
                profile: profile,
                status: .missing,
                sourceKind: manifest?.sourceKind,
                vmStatus: nil,
                reason: profile.imageReference == nil
                    ? "No prepared stock macOS base VM exists yet."
                    : "No local base macOS VM exists yet for \(profile.displayName)."
            )
        }

        return snapshot
    }

    private func waitForBaseVMReady(
        profile: LumeBaseVMProfile,
        progress: WorkspaceProviderProgressHandler?,
        preferredSourceKind: LumeBaseVMSourceKind
    ) async throws -> LumeBaseVMSnapshot {
        let deadline = Date().addingTimeInterval(baseProvisioningTimeout)
        var lastSnapshot: LumeBaseVMSnapshot?

        while Date() < deadline {
            let manifest = await validatedBaseService.loadManifest(named: profile.vmName)
            let snapshot = await inspectBaseVM(
                profile: profile,
                manifest: manifest
            )
            if let snapshot {
                lastSnapshot = snapshot
                switch snapshot.status {
                case .ready:
                    if snapshot.normalizedVMStatus == .running {
                        await progress?("Stopping prepared base macOS VM...")
                        try await stopVM(named: profile.vmName, storagePath: profile.storagePath)
                    } else {
                        await persistBaseManifest(
                            profile: profile,
                            sourceKind: snapshot.sourceKind ?? preferredSourceKind
                        )
                        return snapshot
                    }
                case .preparing:
                    await progress?("Preparing base macOS VM...")
                case .repairRequired:
                    throw LumeRuntimeError.baseVMFailed(
                        snapshot.reason
                            ?? "The prepared base macOS VM entered an unexpected state."
                    )
                case .missing:
                    break
                }
            }

            try await Task.sleep(nanoseconds: basePollIntervalNanoseconds)
        }

        let details = lastSnapshot?.vmStatus ?? "missing"
        throw LumeRuntimeError.baseVMFailed(
            "Timed out waiting for the prepared base macOS VM to become ready (last status: \(details))."
        )
    }

    private func pullBaseVM(
        profile: LumeBaseVMProfile,
        imageResolution: LumeImageResolution
    ) async throws {
        let request = LumeRuntimePullImageRequest(
            image: imageResolution.entry.imageReference,
            name: profile.vmName,
            registry: imageResolution.entry.registry,
            organization: imageResolution.entry.organization,
            storage: nil
        )
        let _: LumeRuntimePullImageResponse = try await sendRequest(
            method: "POST",
            path: "/pull",
            body: request
        )
    }

    private func createBaseMacOSVMWithCLI(
        profile: LumeBaseVMProfile,
        hostProfile: LumeHostProfile,
        progress: WorkspaceProviderProgressHandler?
    ) async throws {
        let result = try await lumeRunner().runStreaming(arguments: [
            "create",
            profile.vmName,
            "--os", WorkspaceGuestOS.macOS.rawValue,
            "--cpu", String(defaultCPUCount),
            "--memory", defaultMemory,
            "--disk-size", defaultDiskSize,
            "--display", defaultDisplay,
            "--ipsw", "latest",
            "--unattended", hostProfile.macOSFamily.rawValue,
            "--network", defaultNetwork,
            "--no-display",
        ]) { line in
            if let message = LumeWorkspaceProvider.cliProvisioningMessage(for: line) {
                await progress?(message)
            }
        }
        guard result.exitCode == 0 else {
            throw LumeRuntimeError.baseVMFailed(
                LumeWorkspaceProvider.cliProvisioningFailureMessage(
                    from: result.transcript,
                    vmName: profile.vmName
                )
            )
        }
    }

    private func deleteBaseVMIfPresent(
        profile: LumeBaseVMProfile,
        currentSnapshot: LumeBaseVMSnapshot
    ) async throws {
        if currentSnapshot.normalizedVMStatus == .running {
            try await stopVM(named: profile.vmName, storagePath: profile.storagePath)
        }

        if currentSnapshot.status != .missing {
            try await deleteVM(named: profile.vmName, storagePath: profile.storagePath)
        }

        await validatedBaseService.deleteManifest(named: profile.vmName)
    }

    private func getVM(named vmName: String, storagePath: String? = nil) async throws -> LumeRuntimeVMDetails {
        do {
            return try await sendRequest(
                method: "GET",
                path: "/vms/\(vmName)",
                queryItems: storagePath.map { [URLQueryItem(name: "storage", value: $0)] } ?? [],
                body: Optional<LumeRuntimeEmptyBody>.none
            )
        } catch {
            guard let storagePath else {
                throw error
            }
            return try await getVMViaCLI(named: vmName, storagePath: storagePath)
        }
    }

    private func getVMViaCLI(named vmName: String, storagePath: String) async throws -> LumeRuntimeVMDetails {
        let result = try await lumeRunner().run(
            arguments: ["get", vmName, "--storage", storagePath, "-f", "json"]
        )

        guard result.success else {
            let message =
                [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? "lume get exited with status \(result.exitCode)"
            throw LumeRuntimeError.baseVMFailed(message)
        }

        let data = Data(result.stdout.utf8)
        let details = try JSONDecoder().decode([LumeRuntimeVMDetails].self, from: data)
        guard let first = details.first else {
            throw LumeRuntimeError.baseVMFailed("Lume returned an empty VM list.")
        }
        return first
    }

    private func stopVM(named vmName: String, storagePath: String? = nil) async throws {
        let _: LumeRuntimeMessageResponse = try await sendRequest(
            method: "POST",
            path: "/vms/\(vmName)/stop",
            body: storagePath.map(LumeRuntimeStorageBody.init(storage:))
        )
    }

    private func deleteVM(named vmName: String, storagePath: String? = nil) async throws {
        let _: LumeRuntimeEmptyResponse = try await sendRequest(
            method: "DELETE",
            path: "/vms/\(vmName)",
            queryItems: storagePath.map { [URLQueryItem(name: "storage", value: $0)] } ?? [],
            body: Optional<LumeRuntimeEmptyBody>.none
        )
    }

    private func sendRequest<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body?
    ) async throws -> Response {
        do {
            return try await httpClient.request(
                method: method,
                path: path,
                queryItems: queryItems,
                body: body
            )
        } catch {
            throw LumeRuntimeError.baseVMFailed(error.localizedDescription)
        }
    }

    private func persistBaseManifest(
        profile: LumeBaseVMProfile,
        sourceKind: LumeBaseVMSourceKind
    ) async {
        let existingManifest = await validatedBaseService.loadManifest(named: profile.vmName)
        let manifest = LumeValidatedBaseManifest(
            vmName: profile.vmName,
            hostProfileKey: profile.profileKey,
            storagePath: profile.storagePath,
            sourceKind: sourceKind,
            imageReference: profile.imageReference,
            unattendedConfig: existingManifest?.unattendedConfig,
            state: existingManifest?.state ?? .invalid,
            validatedAt: existingManifest?.validatedAt,
            failureStage: existingManifest?.failureStage,
            failureMessage: existingManifest?.failureMessage,
            validationSource: existingManifest?.validationSource ?? "workspacemanager-runtime"
        )

        do {
            try await validatedBaseService.saveManifest(manifest)
        } catch {
            // Validation manifests are diagnostics-only from the runtime's perspective.
        }
    }

    private func downloadInstallerScript() async throws -> URL {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(from: installerURL)
        } catch {
            throw LumeRuntimeError.installationFailed(
                "Could not download the official Lume installer from \(installerURL.absoluteString): \(error.localizedDescription)"
            )
        }
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw LumeRuntimeError.installationFailed("Failed to download the official Lume installer.")
        }

        let temporaryDirectory = fileManager.temporaryDirectory
        let scriptURL = temporaryDirectory.appendingPathComponent("lume-install-\(UUID().uuidString).sh")
        try data.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func runInstallerScript(at scriptURL: URL) async throws {
        let installDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(installDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            environment["TERM"] = "xterm-256color"
        }

        let result = try await ProcessRunner.run(
            executable: "/bin/bash",
            arguments: [
                scriptURL.path,
                "--install-dir", installDirectory.path,
                "--port", "7777",
                "--no-auto-updater",
            ],
            environment: environment
        )

        guard result.success else {
            let installerOutput =
                [result.stdout, result.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            throw LumeRuntimeError.installationFailed(
                installerOutput.isEmpty
                    ? "The official Lume installer exited with code \(result.exitCode)."
                    : installerOutput
            )
        }

        cachedExecutablePath = nil
    }

    private func waitForDaemon() async throws {
        let deadline = Date().addingTimeInterval(daemonStartupTimeout)
        while Date() < deadline {
            if await daemonIsReachable() {
                return
            }
            try await Task.sleep(nanoseconds: daemonPollIntervalNanoseconds)
        }

        throw LumeRuntimeError.verificationFailed(
            "Timed out waiting for the Lume daemon to become reachable."
        )
    }

    private func daemonIsReachable() async -> Bool {
        let reachabilityStartedAt = Date()
        let reachable: Bool
        if await requestSucceeds(path: "/host/status") {
            reachable = true
        } else {
            // `requestSucceeds` uses a 10-second request timeout, so the two-probe fallback here
            // can legitimately take up to about 20 seconds when the daemon is down or filtered.
            reachable = await requestSucceeds(path: "/vms")
        }

        NSLog(
            "[Perf] metric=lume_runtime_daemon_reachability duration_ms=%.2f outcome=%@",
            Date().timeIntervalSince(reachabilityStartedAt) * 1000,
            reachable ? "reachable" : "unreachable"
        )

        return reachable
    }

    private func requestSucceeds(path: String) async -> Bool {
        await httpClient.requestSucceeds(path: path, urlSession: urlSession)
    }

    private func executablePathIfInstalled() async -> String? {
        if let cachedExecutablePath {
            if fileManager.isExecutableFile(atPath: cachedExecutablePath) {
                return cachedExecutablePath
            }
            self.cachedExecutablePath = nil
        }

        if let whichResult = try? await ProcessRunner.run(
            executable: "/usr/bin/which",
            arguments: ["lume"]
        ) {
            let resolvedPath = whichResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if whichResult.success, !resolvedPath.isEmpty {
                cachedExecutablePath = resolvedPath
                return resolvedPath
            }
        }

        let searchPaths = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("lume")
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                cachedExecutablePath = candidate
                return candidate
            }
        }

        return nil
    }

    private func commandOutput(executable: String, arguments: [String]) async throws -> String {
        let commandStartedAt = Date()
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments)
        guard result.success else {
            NSLog(
                "[Perf] metric=lume_runtime_host_command duration_ms=%.2f executable=%@ outcome=failure exit_code=%ld",
                Date().timeIntervalSince(commandStartedAt) * 1000,
                URL(fileURLWithPath: executable).lastPathComponent,
                Int(result.exitCode)
            )
            throw LumeRuntimeError.invalidHostProfile(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        NSLog(
            "[Perf] metric=lume_runtime_host_command duration_ms=%.2f executable=%@ outcome=success exit_code=%ld",
            Date().timeIntervalSince(commandStartedAt) * 1000,
            URL(fileURLWithPath: executable).lastPathComponent,
            Int(result.exitCode)
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lumeRunner() async throws -> LumeCLIRunner {
        LumeCLIRunner(
            executablePath: try await executablePath(),
            currentDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }

    private var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(launchAgentName, isDirectory: false)
    }
}

private struct LumeRuntimePullImageRequest: Encodable {
    let image: String
    let name: String
    let registry: String
    let organization: String
    let storage: String?
}

private struct LumeRuntimeStorageBody: Encodable {
    let storage: String
}

private struct LumeRuntimeVMDetails: Decodable, Sendable {
    let name: String
    let status: String
    let provisioningOperation: String?
    let ipAddress: String?
    let sshAvailable: Bool?

    var normalizedStatus: LumeVMStatus {
        LumeVMStatus(rawValue: status)
    }
}

private struct LumeRuntimePullImageResponse: Decodable {
    let message: String
    let image: String
    let name: String
}

private struct LumeRuntimeMessageResponse: Decodable {
    let message: String
}

private struct LumeRuntimeEmptyResponse: LumeHTTPEmptyResponse {}
private struct LumeRuntimeEmptyBody: Encodable {}

extension ProcessInfo {
    fileprivate var machineArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "unknown"
        #endif
    }
}

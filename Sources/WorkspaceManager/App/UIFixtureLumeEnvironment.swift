//
//  UIFixtureLumeEnvironment.swift
//  WorkspaceManager
//
//  Deterministic Lume runtime and provider fixtures for visual UI evidence.
//

import Foundation
@preconcurrency import WorkspaceManagerCore

enum UIFixtureLumeEnvironment {
    static let environmentKey = "WORKSPACES_UI_FIXTURE_LUME_E2E"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    static func initialProviderAvailabilityByID() -> [String: WorkspaceProviderAvailability] {
        guard isEnabled() else { return [:] }

        return [
            LocalWorkspaceProvider.identifier: WorkspaceProviderAvailability.available,
            DaytonaWorkspaceProvider.identifier: WorkspaceProviderAvailability.available,
            LumeWorkspaceProvider.identifier: WorkspaceProviderAvailability.available,
        ]
    }

    static func initialRuntimeSnapshot() -> LumeRuntimeSnapshot? {
        guard isEnabled() else { return nil }

        let hostProfile = LumeHostProfile(
            architecture: "arm64",
            macOSFamily: .tahoe,
            macOSVersion: "26.2",
            xcodeVersion: "26.2",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )
        let imageResolution = try? LumeRuntimeService.resolveDefaultMacOSImage(for: hostProfile)
        let baseProfile = LumeRuntimeService.resolveBaseVMProfile(
            hostProfile: hostProfile,
            imageResolution: imageResolution
        )

        return LumeRuntimeSnapshot(
            state: .setupRequired,
            reason: "Lume is not installed yet.",
            executablePath: nil,
            launchAgentPath: "/tmp/workspacemanager-ui-fixture-lume/com.trycua.lume_daemon.plist",
            launchAgentInstalled: false,
            daemonReachable: false,
            hostProfile: hostProfile,
            defaultMacOSImage: imageResolution,
            defaultMacOSImageError: nil,
            baseVM: LumeBaseVMSnapshot(
                profile: baseProfile,
                status: .missing,
                sourceKind: nil,
                vmStatus: nil,
                reason: "No prepared base macOS VM exists yet."
            ),
            infoLogPath: "/tmp/workspacemanager-ui-fixture-lume/lume_daemon.log",
            errorLogPath: "/tmp/workspacemanager-ui-fixture-lume/lume_daemon.error.log"
        )
    }
}

actor UIFixtureLumeRuntimeService: LumeRuntimeServiceProtocol {
    private let fileManager: FileManager
    private let artifactsRoot: URL
    private let executableURL: URL
    private let launchAgentURL: URL
    private let infoLogURL: URL
    private let errorLogURL: URL
    private let hostProfile: LumeHostProfile
    private let imageResolution: LumeImageResolution
    private let stepDelayNanoseconds: UInt64

    private var state: LumeRuntimeState = .setupRequired
    private var baseStatus: LumeBaseVMStatus = .missing
    private var baseSourceKind: LumeBaseVMSourceKind?

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("workspacemanager-ui-fixture-lume", isDirectory: true)
        self.artifactsRoot = root
        self.executableURL = root.appendingPathComponent("bin/lume", isDirectory: false)
        self.launchAgentURL = root.appendingPathComponent("com.trycua.lume_daemon.plist", isDirectory: false)
        self.infoLogURL = root.appendingPathComponent("lume_daemon.log", isDirectory: false)
        self.errorLogURL = root.appendingPathComponent("lume_daemon.error.log", isDirectory: false)
        self.stepDelayNanoseconds = Self.stepDelay(environment: environment)

        let hostProfile = try! LumeHostProfile.parse(
            architecture: "arm64",
            swVersOutput: "26.2",
            xcodebuildOutput: "Xcode 26.2\nBuild version 17C40",
            developerDirectoryOutput: "/Applications/Xcode.app/Contents/Developer"
        )
        self.hostProfile = hostProfile
        self.imageResolution = try! LumeRuntimeService.resolveDefaultMacOSImage(for: hostProfile)

        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        Self.seedArtifactFiles(
            fileManager: fileManager,
            artifactsRoot: root,
            executableURL: executableURL,
            launchAgentURL: launchAgentURL,
            infoLogURL: infoLogURL,
            errorLogURL: errorLogURL,
            isInstalled: false
        )
    }

    func snapshot() async -> LumeRuntimeSnapshot {
        let isInstalled = state == .ready || state == .verifying || state == .installing
        let isDaemonReachable = state == .ready || state == .verifying
        let baseProfile = LumeRuntimeService.resolveBaseVMProfile(
            hostProfile: hostProfile,
            imageResolution: imageResolution
        )

        return LumeRuntimeSnapshot(
            state: state,
            reason: reason(for: state),
            executablePath: isInstalled ? executableURL.path : nil,
            launchAgentPath: launchAgentURL.path,
            launchAgentInstalled: isInstalled,
            daemonReachable: isDaemonReachable,
            hostProfile: hostProfile,
            defaultMacOSImage: imageResolution,
            defaultMacOSImageError: nil,
            baseVM: LumeBaseVMSnapshot(
                profile: baseProfile,
                status: isInstalled ? baseStatus : .missing,
                sourceKind: baseSourceKind,
                vmStatus: baseStatus == .ready ? "stopped" : nil,
                reason: baseStatus == .ready
                    ? "Fast macOS VM clones are ready."
                    : "No prepared base macOS VM exists yet."
            ),
            infoLogPath: infoLogURL.path,
            errorLogPath: errorLogURL.path
        )
    }

    func baseVMSnapshot() async -> LumeBaseVMSnapshot? {
        await snapshot().baseVM
    }

    func hostProfile() async throws -> LumeHostProfile {
        hostProfile
    }

    func defaultMacOSImageResolution() async throws -> LumeImageResolution {
        imageResolution
    }

    func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        switch state {
        case .ready:
            return await snapshot()
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost("Lume requires Apple Silicon.")
        case .repairRequired, .setupRequired, .installing, .verifying:
            break
        }

        state = .installing
        try await runProgress(
            progress,
            steps: [
                .checkingHost,
                .downloadingInstaller,
                .installingLume,
                .startingBackgroundService,
                .verifyingDaemon,
                .resolvingDefaultVMImage,
            ]
        )
        state = .ready
        Self.seedArtifactFiles(
            fileManager: fileManager,
            artifactsRoot: artifactsRoot,
            executableURL: executableURL,
            launchAgentURL: launchAgentURL,
            infoLogURL: infoLogURL,
            errorLogURL: errorLogURL,
            isInstalled: true
        )
        return await snapshot()
    }

    func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        guard state != .setupRequired else {
            throw LumeRuntimeError.verificationFailed("Lume is not installed yet.")
        }

        state = .verifying
        try await runProgress(
            progress,
            steps: [.checkingHost, .verifyingDaemon, .resolvingDefaultVMImage]
        )
        state = .ready
        Self.seedArtifactFiles(
            fileManager: fileManager,
            artifactsRoot: artifactsRoot,
            executableURL: executableURL,
            launchAgentURL: launchAgentURL,
            infoLogURL: infoLogURL,
            errorLogURL: errorLogURL,
            isInstalled: true
        )
        return await snapshot()
    }

    func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        state = .repairRequired
        return try await installIfNeeded(progress: progress)
    }

    func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot {
        if baseStatus != .ready {
            await progress?("Preparing base macOS VM...")
            try await Task.sleep(nanoseconds: stepDelayNanoseconds)
            baseStatus = .ready
            baseSourceKind = .pulledImage
        }
        guard let snapshot = await snapshot().baseVM else {
            throw LumeRuntimeError.baseVMFailed("Missing fixture base VM snapshot.")
        }
        return snapshot
    }

    func deleteBaseVM() async throws -> LumeRuntimeSnapshot {
        baseStatus = .missing
        baseSourceKind = nil
        return await snapshot()
    }

    func executablePath() async throws -> String {
        guard state != .setupRequired else {
            throw LumeRuntimeError.installationFailed("Could not find the `lume` executable.")
        }
        return executableURL.path
    }

    private func runProgress(
        _ progress: LumeRuntimeProgressHandler?,
        steps: [LumeRuntimeSetupStep]
    ) async throws {
        for step in steps {
            await progress?(step)
            try await Task.sleep(nanoseconds: stepDelayNanoseconds)
        }
    }

    private func reason(for state: LumeRuntimeState) -> String? {
        switch state {
        case .setupRequired:
            return "Lume is not installed yet."
        case .repairRequired:
            return "The Lume LaunchAgent is missing."
        case .unsupportedHost:
            return "Lume requires Apple Silicon."
        case .installing, .verifying, .ready:
            return nil
        }
    }

    private nonisolated static func seedArtifactFiles(
        fileManager: FileManager,
        artifactsRoot: URL,
        executableURL: URL,
        launchAgentURL: URL,
        infoLogURL: URL,
        errorLogURL: URL,
        isInstalled: Bool
    ) {
        try? fileManager.createDirectory(
            at: artifactsRoot.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        if isInstalled {
            if let executableData = "#!/bin/sh\nexit 0\n".data(using: .utf8) {
                try? executableData.write(to: executableURL, options: .atomic)
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
            if let launchAgentData = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict><key>Label</key><string>com.trycua.lume_daemon</string></dict></plist>
                """.data(using: .utf8)
            {
                try? launchAgentData.write(to: launchAgentURL, options: .atomic)
            }
        } else {
            try? fileManager.removeItem(at: executableURL)
            try? fileManager.removeItem(at: launchAgentURL)
        }

        if let infoLogData = "fixture daemon log\n".data(using: .utf8) {
            try? infoLogData.write(to: infoLogURL, options: .atomic)
        }
        if let errorLogData = "".data(using: .utf8) {
            try? errorLogData.write(to: errorLogURL, options: .atomic)
        }
    }

    private static func stepDelay(environment: [String: String]) -> UInt64 {
        guard let rawValue = environment["WORKSPACES_UI_FIXTURE_LUME_STEP_DELAY_MS"],
            let milliseconds = UInt64(rawValue),
            milliseconds > 0
        else {
            return 500_000_000
        }

        return milliseconds * 1_000_000
    }
}

actor UIFixtureLumeWorkspaceProvider: WorkspaceProviderProtocol {
    private let runtimeService: any LumeRuntimeServiceProtocol
    private let fileManager: FileManager
    private let workspacesRoot: URL
    private let stepDelayNanoseconds: UInt64 = 450_000_000
    private var statusesByRemoteID: [String: WorkspaceStatus] = [:]

    nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: LumeWorkspaceProvider.identifier,
        displayName: "Lume VM",
        description: "Create a local VM-backed workspace with host-shared files.",
        supportedGuestOS: [.macOS, .linux],
        supportsDesktop: true,
        usesHostWorkspaceFiles: true
    )

    init(
        runtimeService: any LumeRuntimeServiceProtocol,
        fileManager: FileManager = .default
    ) {
        self.runtimeService = runtimeService
        self.fileManager = fileManager
        self.workspacesRoot = fileManager.temporaryDirectory
            .appendingPathComponent("workspacemanager-ui-fixture-workspaces", isDirectory: true)
        try? fileManager.createDirectory(at: workspacesRoot, withIntermediateDirectories: true)
    }

    func availability() async -> WorkspaceProviderAvailability {
        let snapshot = await runtimeService.snapshot()
        if snapshot.state == .unsupportedHost {
            return .unavailable(snapshot.reason ?? "Lume requires Apple Silicon.")
        }
        return .available
    }

    nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(
            providerID: LumeWorkspaceProvider.identifier,
            instanceID: workspace.terminalSessionIdentifier
        )
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        let snapshot = await runtimeService.snapshot()
        guard snapshot.state == .ready else {
            throw WorkspaceProviderError.unavailable("Lume is not ready yet.")
        }

        let guestOS = request.guestOS ?? .macOS
        let workspaceDirectory = workspacesRoot.appendingPathComponent(
            sanitizedComponent(request.workspaceName),
            isDirectory: true
        )
        try fileManager.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        try """
        # \(request.workspaceName)

        UI fixture workspace for \(guestOS.label).
        """.data(using: .utf8)?.write(
            to: workspaceDirectory.appendingPathComponent("README.md"),
            options: .atomic
        )

        let remoteID = "fixture-\(sanitizedComponent(request.workspaceName))"
        let metadata = try await metadata(
            for: remoteID,
            guestOS: guestOS,
            workspaceDirectory: workspaceDirectory
        )

        let provisionalResult = WorkspaceProviderCreationResult(
            name: request.workspaceName,
            path: workspaceDirectory,
            gitBranch: "workspace/\(sanitizedComponent(request.workspaceName))",
            status: .provisioning,
            backendIdentifier: descriptor.id,
            remoteId: remoteID,
            backendMetadataRaw: encodeMetadata(metadata)
        )
        statusesByRemoteID[remoteID] = .provisioning
        try await persist?(provisionalResult)

        await progress?(guestOS == .macOS ? "Fetching macOS image..." : "Creating Linux VM...")
        try await Task.sleep(nanoseconds: stepDelayNanoseconds)
        await progress?("Starting VM...")
        try await Task.sleep(nanoseconds: stepDelayNanoseconds)
        await progress?("Waiting for SSH...")
        try await Task.sleep(nanoseconds: stepDelayNanoseconds)

        statusesByRemoteID[remoteID] = .active
        return WorkspaceProviderCreationResult(
            name: request.workspaceName,
            path: workspaceDirectory,
            gitBranch: "workspace/\(sanitizedComponent(request.workspaceName))",
            status: .active,
            backendIdentifier: descriptor.id,
            remoteId: remoteID,
            backendMetadataRaw: encodeMetadata(metadata)
        )
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        let metadata = try metadata(for: workspace)
        statusesByRemoteID[workspace.remoteId ?? metadata.vmName] = .active
        return TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: URL(fileURLWithPath: metadata.sharedHostPath)
        )
    }

    func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        let metadata = try metadata(for: workspace)
        statusesByRemoteID[workspace.remoteId ?? metadata.vmName] = .active
        guard let vncURL = URL(string: "vnc://127.0.0.1:5900/\(metadata.vmName)") else {
            throw WorkspaceProviderError.unavailable("Could not build VNC URL.")
        }
        return DesktopLaunchSpec(vncURL: vncURL, statusAfterLaunch: .active)
    }

    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        statusesByRemoteID[workspace.remoteId ?? workspace.id.uuidString] = .active
    }

    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        statusesByRemoteID[workspace.remoteId ?? workspace.id.uuidString] = .stopped
    }

    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let remoteID = workspace.remoteId ?? workspace.id.uuidString
        statusesByRemoteID.removeValue(forKey: remoteID)
        if let metadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self) {
            try? fileManager.removeItem(atPath: metadata.sharedHostPath)
        }
    }

    func syncStatuses(for workspaces: [WorkspaceProviderTarget]) async throws -> [WorkspaceProviderStatusSnapshot] {
        workspaces.compactMap { workspace in
            guard let remoteID = workspace.remoteId,
                let status = statusesByRemoteID[remoteID]
            else {
                return nil
            }

            return WorkspaceProviderStatusSnapshot(remoteId: remoteID, status: status)
        }
    }

    private func metadata(
        for remoteID: String,
        guestOS: WorkspaceGuestOS,
        workspaceDirectory: URL
    ) async throws -> LumeWorkspaceMetadata {
        if guestOS == .macOS {
            let imageResolution = try await runtimeService.defaultMacOSImageResolution()
            return LumeWorkspaceMetadata(
                vmName: remoteID,
                guestOS: guestOS,
                sharedHostPath: workspaceDirectory.path,
                profileKey: imageResolution.profileKey,
                profileDisplayName: imageResolution.profileDisplayName,
                imageReference: imageResolution.entry.imageReference
            )
        }

        return LumeWorkspaceMetadata(
            vmName: remoteID,
            guestOS: guestOS,
            sharedHostPath: workspaceDirectory.path
        )
    }

    private func metadata(for workspace: WorkspaceProviderTarget) throws -> LumeWorkspaceMetadata {
        guard let metadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self) else {
            throw WorkspaceProviderError.invalidWorkspace(
                "Lume workspace '\(workspace.name)' is missing VM metadata."
            )
        }
        return metadata
    }

    private func encodeMetadata(_ metadata: LumeWorkspaceMetadata) -> String {
        guard let data = try? JSONEncoder().encode(metadata),
            let rawValue = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return rawValue
    }

    private func sanitizedComponent(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowercased = rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "workspace" : collapsed
    }
}

struct UIFixtureDaytonaWorkspaceProvider: WorkspaceProviderProtocol {
    let descriptor = WorkspaceProviderDescriptor(
        id: DaytonaWorkspaceProvider.identifier,
        displayName: "Daytona",
        description: "Create a cloud Linux workspace and connect over SSH.",
        supportedGuestOS: [.linux],
        supportsArchive: true,
        requiresRemoteRepository: true
    )

    func availability() async -> WorkspaceProviderAvailability {
        .available
    }

    func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(
            providerID: DaytonaWorkspaceProvider.identifier,
            instanceID: workspace.terminalSessionIdentifier
        )
    }

    func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        throw WorkspaceProviderError.unavailable("Daytona fixture workspaces are not enabled in this UI capture mode.")
    }

    func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        throw WorkspaceProviderError.unavailable("Daytona fixture workspaces are not enabled in this UI capture mode.")
    }

    func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        throw WorkspaceProviderError.unavailable("Desktop is not available in the Daytona fixture provider.")
    }

    func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unavailable("Daytona fixture workspaces are not enabled in this UI capture mode.")
    }

    func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unavailable("Daytona fixture workspaces are not enabled in this UI capture mode.")
    }

    func archiveWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        throw WorkspaceProviderError.unavailable("Daytona fixture workspaces are not enabled in this UI capture mode.")
    }

    func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {}

    func syncStatuses(for workspaces: [WorkspaceProviderTarget]) async throws -> [WorkspaceProviderStatusSnapshot] {
        []
    }
}

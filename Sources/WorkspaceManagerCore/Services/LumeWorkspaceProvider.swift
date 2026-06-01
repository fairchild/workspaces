//
//  LumeWorkspaceProvider.swift
//  WorkspaceManagerCore
//
//  Provider for host-shared workspaces backed by local Lume VMs.
//

import Foundation

public struct LumeWorkspaceMetadata: Codable, Sendable, Equatable {
    public let vmName: String
    public let storagePath: String?
    public let guestOS: WorkspaceGuestOS
    public let sharedHostPath: String
    public let desktopSupported: Bool
    public let profileKey: String?
    public let profileDisplayName: String?
    public let imageReference: String?
    public let baseVMName: String?
    public let baseSourceKind: LumeBaseVMSourceKind?
    public let launchLogPath: String?

    public init(
        vmName: String,
        storagePath: String? = nil,
        guestOS: WorkspaceGuestOS,
        sharedHostPath: String,
        desktopSupported: Bool = true,
        profileKey: String? = nil,
        profileDisplayName: String? = nil,
        imageReference: String? = nil,
        baseVMName: String? = nil,
        baseSourceKind: LumeBaseVMSourceKind? = nil,
        launchLogPath: String? = nil
    ) {
        self.vmName = vmName
        self.storagePath = storagePath
        self.guestOS = guestOS
        self.sharedHostPath = sharedHostPath
        self.desktopSupported = desktopSupported
        self.profileKey = profileKey
        self.profileDisplayName = profileDisplayName
        self.imageReference = imageReference
        self.baseVMName = baseVMName
        self.baseSourceKind = baseSourceKind
        self.launchLogPath = launchLogPath
    }
}

public actor LumeWorkspaceProvider: WorkspaceProviderProtocol {
    public static let identifier = "lume"
    public static let providerDescriptor = WorkspaceProviderDescriptor(
        id: LumeWorkspaceProvider.identifier,
        displayName: "Lume VM",
        description: "Create a local VM-backed workspace with host-shared files.",
        sheetStatusPolicy: .deferred,
        supportedGuestOS: [.macOS, .linux],
        supportsDesktop: true,
        usesHostWorkspaceFiles: true
    )
    static let defaultNetworkMode = "nat"
    static let defaultMacOSRunNetworkMode = defaultNetworkMode

    public nonisolated let descriptor = LumeWorkspaceProvider.providerDescriptor

    private let httpClient: LumeHTTPClient
    private let runtimeService: any LumeRuntimeServiceProtocol
    private let validatedBaseService: LumeValidatedBaseService
    private let bridgedReachability = LumeBridgedVMReachability()
    private let fileManager = FileManager.default

    private let provisioningTimeout: TimeInterval = 60 * 30
    private let startupTimeout: TimeInterval = 60 * 10
    private let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private let defaultCPUCount = 4
    private let defaultMemory = "8GB"
    private let defaultDiskSize = "50GB"
    private let defaultDisplay = "1024x768"
    private let defaultNetwork = LumeWorkspaceProvider.defaultNetworkMode
    private let defaultMacOSRunNetwork = LumeWorkspaceProvider.defaultMacOSRunNetworkMode
    private let daemonInfoLogPath = "/tmp/lume_daemon.log"
    private let daemonErrorLogPath = "/tmp/lume_daemon.error.log"

    public init(
        // Safe: constant URL string, always parses successfully
        baseURL: URL = URL(string: "http://localhost:7777/lume/")!,
        urlSession: URLSession = .shared,
        runtimeService: any LumeRuntimeServiceProtocol = LumeRuntimeService.shared,
        validatedBaseService: LumeValidatedBaseService = .shared
    ) {
        self.httpClient = LumeHTTPClient(baseURL: baseURL)
        _ = urlSession
        self.runtimeService = runtimeService
        self.validatedBaseService = validatedBaseService
    }

    public func availability() async -> WorkspaceProviderAvailability {
        #if arch(arm64)
            return .available
        #else
            return .unavailable("Lume requires Apple Silicon.")
        #endif
    }

    public nonisolated func sessionKey(for workspace: WorkspaceProviderTarget) -> HostTerminalSessionKey {
        .backendSession(providerID: Self.identifier, instanceID: workspace.terminalSessionIdentifier)
    }

    public func createWorkspace(
        request: WorkspaceProviderCreationRequest,
        workspaceService: any WorkspaceServiceProtocol,
        progress: WorkspaceProviderProgressHandler?,
        persist: WorkspaceProviderPersistenceHandler?
    ) async throws -> WorkspaceProviderCreationResult {
        let guestOS = request.guestOS ?? .macOS
        var localInfo: NewWorkspaceInfo?
        var vmName: String?
        var metadata: LumeWorkspaceMetadata?
        var vmStoragePath: String?

        do {
            let workspaceVMStoragePath = await validatedBaseService.workspaceVMStorageDirectoryURL.path
            vmStoragePath = workspaceVMStoragePath
            let info = try await workspaceService.createWorkspace(
                repoName: request.repoName,
                repoLocalURL: request.repoLocalURL,
                name: request.workspaceName,
                progress: { phase in
                    await progress?(LocalWorkspaceProvider.progressMessage(for: phase))
                }
            )
            localInfo = info

            let generatedVMName = makeVMName(
                repoName: request.repoName,
                workspaceName: request.workspaceName
            )
            vmName = generatedVMName

            if guestOS == .macOS {
                await progress?("Resolving prepared base macOS VM...")
                let currentBaseSnapshot = await runtimeService.baseVMSnapshot()
                metadata = macOSMetadata(
                    vmName: generatedVMName,
                    storagePath: currentBaseSnapshot?.profile.storagePath ?? workspaceVMStoragePath,
                    sharedHostPath: info.path.path,
                    baseSnapshot: currentBaseSnapshot
                )
            } else {
                metadata = LumeWorkspaceMetadata(
                    vmName: generatedVMName,
                    storagePath: workspaceVMStoragePath,
                    guestOS: guestOS,
                    sharedHostPath: info.path.path
                )
            }

            guard let resolvedMetadata = metadata else {
                throw WorkspaceProviderError.unavailable("Failed to prepare Lume workspace metadata.")
            }
            var activeMetadata = metadataWithDetachedLaunchLogPath(resolvedMetadata)
            let provisionalResult = WorkspaceProviderCreationResult(
                name: info.name,
                path: info.path,
                gitBranch: info.gitBranch,
                status: .provisioning,
                backendIdentifier: descriptor.id,
                remoteId: generatedVMName,
                backendMetadataRaw: encodeMetadata(activeMetadata)
            )

            try await persist?(provisionalResult)

            if guestOS == .macOS {
                let preparedBase = try await runtimeService.ensureBaseVMReady(progress: progress)
                let preparedMetadata = macOSMetadata(
                    vmName: generatedVMName,
                    storagePath: preparedBase.profile.storagePath,
                    sharedHostPath: info.path.path,
                    baseSnapshot: preparedBase
                )
                activeMetadata = metadataWithDetachedLaunchLogPath(preparedMetadata)
                // Keep macOS clones in the validated-base storage for now.
                // Same-storage clone+boot is the known-good fast path on this host,
                // and the recreate runbook documents the current limitation.
                vmStoragePath = preparedBase.profile.storagePath

                try await persist?(
                    WorkspaceProviderCreationResult(
                        name: info.name,
                        path: info.path,
                        gitBranch: info.gitBranch,
                        status: .provisioning,
                        backendIdentifier: descriptor.id,
                        remoteId: generatedVMName,
                        backendMetadataRaw: encodeMetadata(activeMetadata)
                    )
                )

                await progress?("Cloning base macOS VM...")
                try await cloneVM(
                    from: preparedBase.profile.vmName,
                    sourceStoragePath: preparedBase.profile.storagePath,
                    to: generatedVMName,
                    destinationStoragePath: preparedBase.profile.storagePath
                )
            } else {
                await progress?("Creating \(guestOS.label) VM...")
                try await createLinuxVM(
                    named: generatedVMName,
                    storagePath: workspaceVMStoragePath
                )

                await progress?("Provisioning VM...")
                _ = try await waitForVM(
                    named: generatedVMName,
                    storagePath: workspaceVMStoragePath,
                    timeout: provisioningTimeout,
                    progressMessage: progress,
                    condition: { details in
                        !details.normalizedStatus.isProvisioning
                    }
                )
            }

            await progress?("Starting VM...")
            try await ensureVMIsRunning(
                named: generatedVMName,
                storagePath: vmStoragePath,
                sharedHostPath: info.path.path,
                guestOS: guestOS
            )

            await progress?("Waiting for SSH...")
            _ = try await waitForVM(
                named: generatedVMName,
                storagePath: vmStoragePath,
                timeout: startupTimeout,
                progressMessage: progress,
                condition: { details in
                    details.normalizedStatus.isRunning && details.sshAvailable == true
                }
            )

            let finalResult = WorkspaceProviderCreationResult(
                name: info.name,
                path: info.path,
                gitBranch: info.gitBranch,
                status: .active,
                backendIdentifier: descriptor.id,
                remoteId: generatedVMName,
                backendMetadataRaw: encodeMetadata(activeMetadata)
            )
            try await persist?(finalResult)
            return finalResult
        } catch {
            if let vmName {
                try? await deleteVM(
                    named: vmName,
                    storagePath: vmStoragePath,
                    guestOS: guestOS
                )
            }
            if let localInfo {
                try? await WorkspaceDirectoryRemover.remove(at: localInfo.path)
            }
            throw error
        }
    }

    public func terminalLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> TerminalLaunchSpec {
        let metadata = try metadata(for: workspace)
        try await ensureVMIsRunning(for: metadata)
        _ = try await waitForVM(
            named: metadata.vmName,
            storagePath: metadata.storagePath,
            timeout: startupTimeout,
            progressMessage: nil,
            condition: { details in
                details.normalizedStatus.isRunning && details.sshAvailable == true
            }
        )

        let executablePath = try await runtimeService.executablePath()
        let storageArgument = metadata.storagePath.map { " --storage '\($0)'" } ?? ""

        return TerminalLaunchSpec(
            sessionKey: sessionKey(for: workspace),
            workingDirectory: URL(fileURLWithPath: metadata.sharedHostPath),
            customCommand: "\(executablePath) ssh \(metadata.vmName)\(storageArgument)",
            statusAfterLaunch: .active
        )
    }

    public func desktopLaunchSpec(for workspace: WorkspaceProviderTarget) async throws -> DesktopLaunchSpec {
        let metadata = try metadata(for: workspace)
        try await ensureVMIsRunning(for: metadata)
        let details = try await waitForVM(
            named: metadata.vmName,
            storagePath: metadata.storagePath,
            timeout: startupTimeout,
            progressMessage: nil,
            condition: { details in
                details.normalizedStatus.isRunning && details.vncURL != nil
            }
        )

        guard let vncURL = details.vncURL else {
            throw WorkspaceProviderError.unavailable("Lume did not return a VNC URL for \(metadata.vmName).")
        }

        return DesktopLaunchSpec(vncURL: vncURL, statusAfterLaunch: .active)
    }

    public func startWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let metadata = try metadata(for: workspace)
        try await ensureVMIsRunning(for: metadata)
    }

    public func stopWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        let metadata = try metadata(for: workspace)
        try await stopVM(named: metadata.vmName, storagePath: metadata.storagePath, guestOS: metadata.guestOS)
    }

    public func deleteWorkspace(_ workspace: WorkspaceProviderTarget) async throws {
        guard let metadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self) else {
            if let remoteId = workspace.remoteId {
                try await deleteVMWithCLI(named: remoteId, storagePath: nil)
            }
            return
        }

        try await deleteVM(named: metadata.vmName, storagePath: metadata.storagePath, guestOS: metadata.guestOS)
    }

    public func syncStatuses(
        for workspaces: [WorkspaceProviderTarget]
    ) async throws -> [WorkspaceProviderStatusSnapshot] {
        var snapshots: [WorkspaceProviderStatusSnapshot] = []
        snapshots.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            guard let remoteId = workspace.remoteId else { continue }

            do {
                let metadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self)
                let details = try await getVM(named: remoteId, storagePath: metadata?.storagePath)
                snapshots.append(
                    WorkspaceProviderStatusSnapshot(
                        remoteId: remoteId,
                        status: details.normalizedStatus.workspaceStatus
                    )
                )
            } catch {
                if LumeErrorHeuristics.shouldTreatAsMissingVM(error) {
                    snapshots.append(
                        WorkspaceProviderStatusSnapshot(
                            remoteId: remoteId,
                            status: .archived
                        )
                    )
                    continue
                }

                throw error
            }
        }

        return snapshots
    }

    private func metadata(for workspace: WorkspaceProviderTarget) throws -> LumeWorkspaceMetadata {
        guard let metadata = workspace.decodeBackendMetadata(LumeWorkspaceMetadata.self) else {
            throw WorkspaceProviderError.invalidWorkspace(
                "Lume workspace '\(workspace.name)' is missing VM metadata."
            )
        }

        return metadata
    }

    private func ensureVMIsRunning(for metadata: LumeWorkspaceMetadata) async throws {
        try await ensureVMIsRunning(
            named: metadata.vmName,
            storagePath: metadata.storagePath,
            sharedHostPath: metadata.sharedHostPath,
            guestOS: metadata.guestOS
        )
    }

    private func ensureVMIsRunning(
        named vmName: String,
        storagePath: String?,
        sharedHostPath: String,
        guestOS: WorkspaceGuestOS
    ) async throws {
        let details = try await getVM(named: vmName, storagePath: storagePath)
        guard !details.normalizedStatus.isProvisioning else {
            _ = try await waitForVM(
                named: vmName,
                storagePath: storagePath,
                timeout: provisioningTimeout,
                progressMessage: nil,
                condition: { details in
                    !details.normalizedStatus.isProvisioning
                }
            )
            return try await ensureVMIsRunning(
                named: vmName,
                storagePath: storagePath,
                sharedHostPath: sharedHostPath,
                guestOS: guestOS
            )
        }

        if !details.normalizedStatus.isRunning {
            if guestOS == .macOS {
                try await runMacOSVMWithCLI(
                    named: vmName,
                    storagePath: storagePath,
                    sharedHostPath: sharedHostPath
                )
            } else {
                try await runVM(named: vmName, storagePath: storagePath, sharedHostPath: sharedHostPath)
            }
        }
    }

    private func createLinuxVM(named vmName: String, storagePath: String) async throws {
        let request = LumeCreateVMRequest(
            name: vmName,
            os: WorkspaceGuestOS.linux.rawValue,
            cpu: defaultCPUCount,
            memory: defaultMemory,
            diskSize: defaultDiskSize,
            display: defaultDisplay,
            ipsw: nil,
            unattended: nil,
            network: defaultNetwork,
            storage: storagePath
        )
        let _: LumeAcceptedResponse = try await sendRequest(
            method: "POST",
            path: "/vms",
            body: request
        )
    }

    private func cloneVM(
        from sourceVMName: String,
        sourceStoragePath: String,
        to vmName: String,
        destinationStoragePath: String
    ) async throws {
        let result = try await lumeRunner().run(
            arguments: [
                "clone",
                sourceVMName,
                vmName,
                "--source-storage", sourceStoragePath,
                "--dest-storage", destinationStoragePath,
            ]
        )

        guard result.success else {
            throw WorkspaceProviderError.unavailable("Failed to clone prepared base macOS VM '\(sourceVMName)'.")
        }
    }

    private func createMacOSVM(
        named vmName: String,
        hostProfile: LumeHostProfile,
        storagePath: String
    ) async throws {
        let request = LumeCreateVMRequest(
            name: vmName,
            os: WorkspaceGuestOS.macOS.rawValue,
            cpu: defaultCPUCount,
            memory: defaultMemory,
            diskSize: defaultDiskSize,
            display: defaultDisplay,
            ipsw: "latest",
            unattended: hostProfile.macOSFamily.rawValue,
            network: defaultNetwork,
            storage: storagePath
        )
        let _: LumeAcceptedResponse = try await sendRequest(
            method: "POST",
            path: "/vms",
            body: request
        )
    }

    private func provisionMacOSVM(
        named vmName: String,
        hostProfile: LumeHostProfile,
        storagePath: String,
        progressMessage: WorkspaceProviderProgressHandler?
    ) async throws {
        do {
            try await createMacOSVM(
                named: vmName,
                hostProfile: hostProfile,
                storagePath: storagePath
            )

            _ = try await waitForVM(
                named: vmName,
                storagePath: storagePath,
                timeout: provisioningTimeout,
                progressMessage: progressMessage,
                condition: { details in
                    !details.normalizedStatus.isProvisioning
                }
            )
        } catch {
            guard Self.shouldRetryMacOSProvisioningWithCLI(for: error) else {
                throw error
            }

            await progressMessage?(
                "Lume's background service could not provision macOS directly. Retrying with the Lume CLI..."
            )
            try? await deleteVMWithCLI(named: vmName, storagePath: storagePath)
            try await createMacOSVMWithCLI(
                named: vmName,
                hostProfile: hostProfile,
                storagePath: storagePath,
                progressMessage: progressMessage
            )
        }
    }

    private func createMacOSVMWithCLI(
        named vmName: String,
        hostProfile: LumeHostProfile,
        storagePath: String,
        progressMessage: WorkspaceProviderProgressHandler?
    ) async throws {
        let result = try await lumeRunner().runStreaming(arguments: [
            "create",
            vmName,
            "--os", WorkspaceGuestOS.macOS.rawValue,
            "--cpu", String(defaultCPUCount),
            "--memory", defaultMemory,
            "--disk-size", defaultDiskSize,
            "--display", defaultDisplay,
            "--ipsw", "latest",
            "--unattended", hostProfile.macOSFamily.rawValue,
            "--storage", storagePath,
            "--network", defaultNetwork,
            "--no-display",
        ]) { line in
            if let message = Self.cliProvisioningMessage(for: line) {
                await progressMessage?(message)
            }
        }
        guard result.exitCode == 0 else {
            throw WorkspaceProviderError.unavailable(
                Self.cliProvisioningFailureMessage(
                    from: result.transcript,
                    vmName: vmName
                )
            )
        }
    }

    private func pullMacOSImage(
        named vmName: String,
        imageReference: String,
        registry: String,
        organization: String,
        storagePath: String
    ) async throws {
        let request = LumePullImageRequest(
            image: imageReference,
            name: vmName,
            registry: registry,
            organization: organization,
            storage: storagePath
        )
        let _: LumePullImageResponse = try await sendRequest(
            method: "POST",
            path: "/pull",
            body: request
        )
    }

    private func runVM(named vmName: String, storagePath: String?, sharedHostPath: String) async throws {
        let request = LumeRunVMRequest(
            noDisplay: true,
            storage: storagePath,
            sharedDirectories: [
                LumeSharedDirectoryRequest(hostPath: sharedHostPath, readOnly: false)
            ]
        )
        let _: LumeAcceptedResponse = try await sendRequest(
            method: "POST",
            path: "/vms/\(vmName)/run",
            body: request
        )
    }

    private func runMacOSVMWithCLI(
        named vmName: String,
        storagePath: String?,
        sharedHostPath: String
    ) async throws {
        var arguments = [
            "run",
            vmName,
            "--network", defaultMacOSRunNetwork,
            "--shared-dir", sharedHostPath,
            "--no-display",
        ]
        if let storagePath {
            arguments.insert(contentsOf: ["--storage", storagePath], at: 2)
        }

        let logURL = detachedLaunchLogURL(for: vmName)
        do {
            try await lumeRunner().launchDetached(arguments: arguments, logURL: logURL)
            NSLog(
                "[LumeCLIRunner] action=launch_detached vm=%@ log=%@",
                vmName,
                logURL.path
            )
        } catch {
            throw WorkspaceProviderError.unavailable("Failed to launch detached macOS VM '\(vmName)'.")
        }
    }

    private func stopVM(
        named vmName: String,
        storagePath: String? = nil,
        guestOS: WorkspaceGuestOS
    ) async throws {
        if guestOS == .macOS {
            return try await stopVMWithCLI(named: vmName, storagePath: storagePath)
        }

        let _: LumeMessageResponse = try await sendRequest(
            method: "POST",
            path: "/vms/\(vmName)/stop",
            body: storagePath.map(LumeStorageBody.init(storage:))
        )
    }

    private func deleteVM(
        named vmName: String,
        storagePath: String? = nil,
        guestOS: WorkspaceGuestOS
    ) async throws {
        if guestOS == .macOS {
            return try await deleteVMWithCLI(named: vmName, storagePath: storagePath)
        }

        let _: LumeEmptyResponse = try await sendRequest(
            method: "DELETE",
            path: "/vms/\(vmName)",
            queryItems: storagePath.map { [URLQueryItem(name: "storage", value: $0)] } ?? [],
            body: Optional<LumeEmptyBody>.none
        )
    }

    private func stopVMWithCLI(named vmName: String, storagePath: String?) async throws {
        var arguments = ["stop", vmName]
        if let storagePath {
            arguments.append(contentsOf: ["--storage", storagePath])
        }
        let result = try await lumeRunner().run(arguments: arguments)

        guard result.success else {
            throw WorkspaceProviderError.unavailable("Failed to stop macOS VM '\(vmName)'.")
        }
    }

    private func deleteVMWithCLI(named vmName: String, storagePath: String?) async throws {
        var arguments = ["delete", vmName, "--force"]
        if let storagePath {
            arguments.append(contentsOf: ["--storage", storagePath])
        }
        let result = try await lumeRunner().run(arguments: arguments)

        guard result.success else {
            throw WorkspaceProviderError.unavailable("Failed to delete macOS VM '\(vmName)'.")
        }
    }

    private func listVMs(storagePath: String? = nil) async throws -> [LumeVMDetails] {
        try await sendRequest(
            method: "GET",
            path: "/vms",
            queryItems: storagePath.map { [URLQueryItem(name: "storage", value: $0)] } ?? [],
            body: Optional<LumeEmptyBody>.none
        )
    }

    private func getVM(named vmName: String, storagePath: String? = nil) async throws -> LumeVMDetails {
        do {
            return try await sendRequest(
                method: "GET",
                path: "/vms/\(vmName)",
                queryItems: storagePath.map { [URLQueryItem(name: "storage", value: $0)] } ?? [],
                body: Optional<LumeEmptyBody>.none
            )
        } catch {
            guard let storagePath else {
                throw error
            }
            return try await getVMViaCLI(named: vmName, storagePath: storagePath)
        }
    }

    private func getVMViaCLI(named vmName: String, storagePath: String) async throws -> LumeVMDetails {
        let result = try await lumeRunner().run(
            arguments: ["get", vmName, "--storage", storagePath, "-f", "json"]
        )

        guard result.success else {
            let messages = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let message =
                messages.first(where: { !$0.isEmpty })
                ?? "lume get exited with status \(result.exitCode)"
            throw WorkspaceProviderError.unavailable(message)
        }

        let data = Data(result.stdout.utf8)
        let details = try JSONDecoder().decode([LumeVMDetails].self, from: data)
        guard let first = details.first else {
            throw WorkspaceProviderError.unavailable("Lume returned an empty VM list.")
        }
        return first
    }

    private func waitForVM(
        named vmName: String,
        storagePath: String?,
        timeout: TimeInterval,
        progressMessage: WorkspaceProviderProgressHandler?,
        condition: @escaping @Sendable (LumeVMDetails) -> Bool
    ) async throws -> LumeVMDetails {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDetails: LumeVMDetails?
        var lastReachabilityRefreshAt: Date?

        while Date() < deadline {
            let details: LumeVMDetails
            do {
                var resolvedDetails = try await getVM(named: vmName, storagePath: storagePath)
                if let storagePath,
                    shouldRefreshBridgedReachability(for: resolvedDetails),
                    shouldAttemptReachabilityRefresh(lastAttemptAt: lastReachabilityRefreshAt)
                {
                    if let snapshot = await bridgedReachability.resolve(
                        vmName: vmName,
                        storagePath: storagePath,
                        networkMode: resolvedDetails.networkMode,
                        existingIPAddress: resolvedDetails.ipAddress,
                        existingSSHAvailable: resolvedDetails.sshAvailable
                    ) {
                        resolvedDetails = resolvedDetails.applying(snapshot: snapshot)
                    }
                    lastReachabilityRefreshAt = Date()
                }
                details = resolvedDetails
            } catch {
                if let asyncCreationFailureMessage = asyncCreationFailureMessage(for: vmName) {
                    throw WorkspaceProviderError.unavailable(asyncCreationFailureMessage)
                }

                if LumeErrorHeuristics.shouldTreatAsMissingVM(error), lastDetails == nil {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                throw error
            }
            lastDetails = details
            if condition(details) {
                return details
            }

            if let statusMessage = statusMessage(for: details) {
                await progressMessage?(statusMessage)
            }

            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        let status = lastDetails?.normalizedStatus.rawValue ?? "unknown"
        throw WorkspaceProviderError.unavailable(
            "Timed out waiting for Lume VM '\(vmName)' to become ready (last status: \(status))."
        )
    }

    private func shouldRefreshBridgedReachability(for details: LumeVMDetails) -> Bool {
        details.normalizedStatus.isRunning
            && LumeBridgedVMReachability.bridgedInterface(from: details.networkMode) != nil
            && (details.ipAddress == nil || details.sshAvailable != true)
    }

    private func shouldAttemptReachabilityRefresh(lastAttemptAt: Date?) -> Bool {
        guard let lastAttemptAt else { return true }
        return Date().timeIntervalSince(lastAttemptAt) >= 5
    }

    private func statusMessage(for details: LumeVMDetails) -> String? {
        let logTail: String?
        if details.normalizedStatus.isProvisioning {
            logTail = readDaemonLogTail()
        } else {
            logTail = nil
        }

        return LumeProgressMessageBuilder.message(
            status: details.normalizedStatus,
            guestOS: details.os,
            provisioningOperation: details.provisioningOperation,
            sshAvailable: details.sshAvailable,
            logTail: logTail
        )
    }

    private func readDaemonLogTail(maxBytes: Int = 16_384) -> String? {
        guard fileManager.fileExists(atPath: daemonInfoLogPath) else { return nil }

        let logURL = URL(fileURLWithPath: daemonInfoLogPath)
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func asyncCreationFailureMessage(for vmName: String) -> String? {
        let candidatePaths = [daemonInfoLogPath, daemonErrorLogPath]

        for path in candidatePaths {
            guard let logTail = readLogTail(atPath: path) else { continue }
            let lines =
                logTail
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .reversed()

            for line in lines {
                guard line.contains("Async VM creation failed"), line.contains(vmName) else { continue }
                if let extracted = extractAsyncCreationFailure(from: line) {
                    return "\(extracted) Open Settings > VM Runtime to inspect or repair the local VM runtime."
                }
                return """
                    Lume failed to create macOS VM '\(vmName)'. Open Settings > VM Runtime to inspect or repair the local VM runtime.
                    """
            }
        }

        return nil
    }

    private func readLogTail(atPath path: String, maxBytes: Int = 16_384) -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }

        let logURL = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func extractAsyncCreationFailure(from line: String) -> String? {
        guard let errorRange = line.range(of: "error=") else { return nil }

        let suffix = line[errorRange.upperBound...]
        let endIndex = suffix.range(of: " name=")?.lowerBound ?? suffix.endIndex
        let message = suffix[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
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
            throw WorkspaceProviderError.unavailable(error.localizedDescription)
        }
    }

    private func encodeMetadata(_ metadata: LumeWorkspaceMetadata) -> String {
        guard let data = try? JSONEncoder().encode(metadata),
            let rawValue = String(data: data, encoding: .utf8)
        else {
            return ""
        }

        return rawValue
    }

    private func makeVMName(repoName: String, workspaceName: String) -> String {
        let sanitizedRepo = sanitizeVMComponent(repoName)
        let sanitizedWorkspace = sanitizeVMComponent(workspaceName)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(sanitizedRepo)-\(sanitizedWorkspace)-\(suffix)"
    }

    private func sanitizeVMComponent(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let lowercased = rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let sanitizedScalars = lowercased.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        let collapsed = String(sanitizedScalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "workspace" : collapsed
    }

    private func isRecoverableMacOSImageResolutionError(_ error: Error) -> Bool {
        guard let runtimeError = error as? LumeRuntimeError else {
            return false
        }

        switch runtimeError {
        case .imageUnavailable:
            return true
        case .unsupportedHost, .invalidHostProfile, .installationFailed, .verificationFailed, .baseVMFailed:
            return false
        }
    }

    private func fallbackMacOSMetadata(
        vmName: String,
        storagePath: String,
        sharedHostPath: String,
        hostProfile: LumeHostProfile
    ) -> LumeWorkspaceMetadata {
        LumeWorkspaceMetadata(
            vmName: vmName,
            storagePath: storagePath,
            guestOS: .macOS,
            sharedHostPath: sharedHostPath,
            profileKey: hostProfile.profileKey,
            profileDisplayName:
                "\(hostProfile.macOSFamily.label) \(hostProfile.macOSVersion) (stock macOS fallback)",
            imageReference: nil
        )
    }

    private func macOSMetadata(
        vmName: String,
        storagePath: String,
        sharedHostPath: String,
        baseSnapshot: LumeBaseVMSnapshot?
    ) -> LumeWorkspaceMetadata {
        LumeWorkspaceMetadata(
            vmName: vmName,
            storagePath: storagePath,
            guestOS: .macOS,
            sharedHostPath: sharedHostPath,
            profileKey: baseSnapshot?.profile.profileKey,
            profileDisplayName: baseSnapshot?.profile.displayName,
            imageReference: baseSnapshot?.profile.imageReference,
            baseVMName: baseSnapshot?.profile.vmName,
            baseSourceKind: baseSnapshot?.sourceKind ?? baseSnapshot?.profile.preferredSourceKind
        )
    }

    private func metadataWithDetachedLaunchLogPath(
        _ metadata: LumeWorkspaceMetadata
    ) -> LumeWorkspaceMetadata {
        guard metadata.guestOS == .macOS else {
            return metadata
        }

        return LumeWorkspaceMetadata(
            vmName: metadata.vmName,
            storagePath: metadata.storagePath,
            guestOS: metadata.guestOS,
            sharedHostPath: metadata.sharedHostPath,
            desktopSupported: metadata.desktopSupported,
            profileKey: metadata.profileKey,
            profileDisplayName: metadata.profileDisplayName,
            imageReference: metadata.imageReference,
            baseVMName: metadata.baseVMName,
            baseSourceKind: metadata.baseSourceKind,
            launchLogPath: detachedLaunchLogURL(for: metadata.vmName).path
        )
    }

    private func detachedLaunchLogURL(for vmName: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("workspaces-lume-run-\(vmName).log", isDirectory: false)
    }

    private func lumeRunner() async throws -> LumeCLIRunner {
        LumeCLIRunner(
            executablePath: try await runtimeService.executablePath(),
            currentDirectory: fileManager.homeDirectoryForCurrentUser
        )
    }

    static func mapStatus(_ rawValue: String) -> WorkspaceStatus {
        LumeVMStatus(rawValue: rawValue).workspaceStatus
    }

    static func shouldRetryMacOSProvisioningWithCLI(for error: Error) -> Bool {
        LumeErrorHeuristics.shouldRetryMacOSProvisioningWithCLI(error)
    }

    static func cliProvisioningMessage(for line: String) -> String? {
        if let installProgress = LumeProgressMessageBuilder.lastMatch(
            pattern: #"Installing macOS.*progress[=:](\d+)%"#,
            in: line
        ) {
            return "Installing macOS... \(installProgress)%"
        }

        if line.contains("Starting unattended Setup Assistant automation") {
            return "Configuring macOS..."
        }

        if line.contains("Unattended setup completed") {
            return "Finishing macOS setup..."
        }

        if line.contains("Download completed and moved to:") {
            return "Preparing macOS installer..."
        }

        if let downloadProgress = LumeProgressMessageBuilder.lastMatch(
            pattern: #"Downloading IPSW Progress: (\d+)%"#,
            in: line
        ) {
            return "Downloading macOS image... \(downloadProgress)%"
        }

        if line.contains("Downloading latest supported Image") {
            return "Downloading macOS image..."
        }

        return nil
    }

    static func cliProvisioningFailureMessage(from transcript: String, vmName: String) -> String {
        let lines =
            transcript
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()

        if let errorLine = lines.first(where: { $0.contains("ERROR:") }) {
            let trimmed =
                errorLine
                .replacingOccurrences(
                    of: #"^\[[^\]]+\]\s+ERROR:\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed) Open Settings > VM Runtime to inspect or repair the local VM runtime."
            }
        }

        return """
            Lume failed to create macOS VM '\(vmName)'. Open Settings > VM Runtime to inspect or repair the local VM runtime.
            """
    }
}

private struct LumeCreateVMRequest: Encodable {
    let name: String
    let os: String
    let cpu: Int
    let memory: String
    let diskSize: String
    let display: String
    let ipsw: String?
    let unattended: String?
    let network: String
    let storage: String?
}

private struct LumePullImageRequest: Encodable {
    let image: String
    let name: String
    let registry: String
    let organization: String
    let storage: String?
}

private struct LumeRunVMRequest: Encodable {
    let noDisplay: Bool
    let storage: String?
    let sharedDirectories: [LumeSharedDirectoryRequest]
}

private struct LumeStorageBody: Encodable {
    let storage: String
}

private struct LumeSharedDirectoryRequest: Encodable {
    let hostPath: String
    let readOnly: Bool
}

private struct LumeVMDetails: Decodable, Sendable {
    let name: String
    let status: String
    let os: String?
    let networkMode: String?
    let provisioningOperation: String?
    let ipAddress: String?
    let sshAvailable: Bool?
    let vncURL: URL?

    var normalizedStatus: LumeVMStatus {
        LumeVMStatus(rawValue: status)
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case os
        case networkMode
        case provisioningOperation
        case ipAddress
        case sshAvailable
        case vncURL = "vncUrl"
    }

    func applying(snapshot: LumeBridgedReachabilitySnapshot) -> LumeVMDetails {
        LumeVMDetails(
            name: name,
            status: status,
            os: os,
            networkMode: networkMode,
            provisioningOperation: provisioningOperation,
            ipAddress: snapshot.ipAddress ?? ipAddress,
            sshAvailable: snapshot.sshAvailable ?? sshAvailable,
            vncURL: vncURL
        )
    }
}

private struct LumeAcceptedResponse: Decodable {
    let message: String
    let name: String?
    let status: String?
}

private struct LumePullImageResponse: Decodable {
    let message: String
    let image: String
    let name: String
}

private struct LumeMessageResponse: Decodable {
    let message: String
}

struct LumeProgressMessageBuilder {
    static func message(
        status: LumeVMStatus,
        guestOS: String?,
        provisioningOperation: String?,
        sshAvailable: Bool?,
        logTail: String?
    ) -> String? {
        switch status {
        case .provisioning, .provisioningStale:
            if let detailedMessage = provisioningMessage(
                guestOS: guestOS,
                provisioningOperation: provisioningOperation,
                logTail: logTail
            ) {
                return detailedMessage
            }

            if guestOS == WorkspaceGuestOS.macOS.rawValue {
                return "Provisioning macOS VM..."
            }
            if guestOS == WorkspaceGuestOS.linux.rawValue {
                return "Provisioning Linux VM..."
            }
            return "Provisioning VM..."

        case .running:
            guard sshAvailable != true else { return nil }
            if guestOS == WorkspaceGuestOS.macOS.rawValue {
                return "Booting macOS and waiting for SSH..."
            }
            if guestOS == WorkspaceGuestOS.linux.rawValue {
                return "Booting Linux VM and waiting for SSH..."
            }
            return "Waiting for SSH..."

        default:
            return nil
        }
    }

    static func provisioningMessage(
        guestOS: String?,
        provisioningOperation: String?,
        logTail: String?
    ) -> String? {
        guard guestOS == WorkspaceGuestOS.macOS.rawValue || provisioningOperation == "ipsw_install" else {
            return nil
        }

        guard let logTail else {
            return "Preparing macOS installer..."
        }

        if let installProgress = lastMatch(
            pattern: #"Installing macOS progress=(\d+)%"#,
            in: logTail
        ) {
            return "Installing macOS... \(installProgress)%"
        }

        if logTail.contains("Starting macOS installation") {
            return "Installing macOS..."
        }

        if logTail.contains("Download completed and moved to:") {
            return "Preparing macOS installer..."
        }

        if let downloadProgress = lastMatch(
            pattern: #"Downloading IPSW Progress: (\d+)%"#,
            in: logTail
        ) {
            return "Downloading macOS image... \(downloadProgress)%"
        }

        return "Preparing macOS installer..."
    }

    static func lastMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        guard
            let match = matches.last,
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[valueRange])
    }
}

extension LumeWorkspaceProvider: WorkspaceProviderSetupCapable {
    public func setupRequirement(
        for action: WorkspaceProviderSetupAction
    ) async throws -> WorkspaceProviderSetupRequirement? {
        let snapshot = await runtimeService.snapshot()

        switch snapshot.state {
        case .ready:
            return nil
        case .setupRequired, .repairRequired:
            let title =
                if snapshot.state == .repairRequired {
                    "Repair macOS VM Support"
                } else {
                    "Set Up macOS VM Support"
                }
            let primaryButtonTitle =
                if snapshot.state == .repairRequired {
                    "Repair Lume and Continue"
                } else {
                    "Install Lume and Continue"
                }

            return .confirmation(
                WorkspaceProviderSetupConfirmation(
                    providerID: descriptor.id,
                    providerDisplayName: descriptor.displayName,
                    state: snapshot.state.rawValue,
                    title: title,
                    primaryButtonTitle: primaryButtonTitle,
                    introductoryText: [
                        "Lume is an MIT open-source VM runtime that uses Apple's native Virtualization Framework to run macOS and Linux VMs at near-native speed on Apple Silicon.",
                        "WorkSpaces needs it so it can create VM-backed workspaces, open an in-app terminal with `lume ssh`, and launch full desktop access via VNC.",
                    ],
                    learnMoreLabel: "Learn more about Lume",
                    learnMoreURL: URL(
                        string: "https://cua.ai/docs/lume/guide/getting-started/introduction"
                    ),
                    explanatoryStepsTitle: "What WorkSpaces will do",
                    explanatorySteps: [
                        "Install the official Lume CLI in ~/.local/bin",
                        "Install and load the user LaunchAgent on localhost:7777",
                        "Verify the daemon is healthy",
                        "Continue: \(action.summary)",
                    ],
                    supplementaryText: snapshot.defaultMacOSImage.map {
                        "Default macOS VM: \($0.profileDisplayName)"
                    }
                        ?? snapshot.hostProfile.map {
                            "Default macOS VM: \($0.displayName)"
                        },
                    footerText:
                        "This is a one-time setup on this Mac. No admin access is required. After setup finishes, WorkSpaces will continue automatically.",
                    progressTitle: "Preparing macOS VM Support",
                    progressBody:
                        "WorkSpaces is setting up the local Lume runtime and will continue automatically when it is ready.",
                    initialProgress: WorkspaceProviderSetupProgress(
                        id: LumeRuntimeSetupStep.checkingHost.rawValue,
                        label: LumeRuntimeSetupStep.checkingHost.label
                    )
                )
            )
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost(
                snapshot.reason ?? "Lume is unsupported on this Mac."
            )
        case .installing, .verifying:
            return .alreadyInProgress
        }
    }

    public func performSetup(progress: WorkspaceProviderSetupProgressHandler?) async throws {
        let setupSnapshot = await runtimeService.snapshot()
        let progressHandler: LumeRuntimeProgressHandler = { step in
            await progress?(
                WorkspaceProviderSetupProgress(
                    id: step.rawValue,
                    label: step.label
                )
            )
        }

        switch setupSnapshot.state {
        case .setupRequired:
            _ = try await runtimeService.installIfNeeded(progress: progressHandler)
        case .repairRequired:
            _ = try await runtimeService.repairInstallation(progress: progressHandler)
        case .ready:
            _ = try await runtimeService.verifyInstallation(progress: progressHandler)
        case .unsupportedHost:
            throw LumeRuntimeError.unsupportedHost(
                setupSnapshot.reason ?? "Lume is unsupported on this Mac."
            )
        case .installing, .verifying:
            break
        }
    }
}

private struct LumeEmptyBody: Encodable {}
private struct LumeEmptyResponse: LumeHTTPEmptyResponse {}

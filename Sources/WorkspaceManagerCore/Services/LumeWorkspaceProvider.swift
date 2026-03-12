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
        baseSourceKind: LumeBaseVMSourceKind? = nil
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
    }
}

public actor LumeWorkspaceProvider: WorkspaceProviderProtocol {
    public static let identifier = "lume"

    public nonisolated let descriptor = WorkspaceProviderDescriptor(
        id: LumeWorkspaceProvider.identifier,
        displayName: "Lume VM",
        description: "Create a local VM-backed workspace with host-shared files.",
        supportedGuestOS: [.macOS, .linux],
        supportsDesktop: true,
        usesHostWorkspaceFiles: true
    )

    private let baseURL: URL
    private let urlSession: URLSession
    private let runtimeService: any LumeRuntimeServiceProtocol
    private let validatedBaseService: LumeValidatedBaseService
    private let fileManager = FileManager.default

    private let provisioningTimeout: TimeInterval = 60 * 30
    private let startupTimeout: TimeInterval = 60 * 10
    private let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private let defaultCPUCount = 4
    private let defaultMemory = "8GB"
    private let defaultDiskSize = "50GB"
    private let defaultDisplay = "1024x768"
    private let defaultNetwork = "nat"
    private let defaultMacOSRunNetwork = "bridged:en0"
    private let daemonInfoLogPath = "/tmp/lume_daemon.log"
    private let daemonErrorLogPath = "/tmp/lume_daemon.error.log"

    public init(
        baseURL: URL = URL(string: "http://localhost:7777/lume/")!,
        urlSession: URLSession = .shared,
        runtimeService: any LumeRuntimeServiceProtocol = LumeRuntimeService.shared,
        validatedBaseService: LumeValidatedBaseService = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
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
        .backendSession(providerID: Self.identifier, instanceID: workspace.remoteId ?? workspace.id.uuidString)
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
            var activeMetadata = resolvedMetadata
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
                activeMetadata = preparedMetadata
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
                        switch details.status {
                        case "provisioning", "provisioning (stale)":
                            return false
                        default:
                            return true
                        }
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
                    details.status == "running" && details.sshAvailable == true
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
                cleanupWorkspaceDirectory(localInfo.path)
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
                details.status == "running" && details.sshAvailable == true
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
                details.status == "running" && details.vncURL != nil
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
                        status: Self.mapStatus(details.status)
                    )
                )
            } catch {
                if shouldTreatAsMissingVM(error) {
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
        guard details.status != "provisioning", details.status != "provisioning (stale)" else {
            _ = try await waitForVM(
                named: vmName,
                storagePath: storagePath,
                timeout: provisioningTimeout,
                progressMessage: nil,
                condition: { details in
                    details.status != "provisioning" && details.status != "provisioning (stale)"
                }
            )
            return try await ensureVMIsRunning(
                named: vmName,
                storagePath: storagePath,
                sharedHostPath: sharedHostPath,
                guestOS: guestOS
            )
        }

        if details.status != "running" {
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
        let request = LumeCloneVMRequest(
            name: sourceVMName,
            newName: vmName,
            sourceLocation: sourceStoragePath,
            destLocation: destinationStoragePath
        )
        let _: LumeCloneVMResponse = try await sendRequest(
            method: "POST",
            path: "/vms/clone",
            body: request
        )
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
                    switch details.status {
                    case "provisioning", "provisioning (stale)":
                        return false
                    default:
                        return true
                    }
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
        let executablePath = try await runtimeService.executablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
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
        ]
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser

        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"]?.isEmpty != false {
            environment["TERM"] = "xterm-256color"
        }
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let outputHandle = outputPipe.fileHandleForReading
        var transcriptLines: [String] = []

        try process.run()
        defer {
            try? outputHandle.close()
        }

        for try await line in outputHandle.bytes.lines {
            transcriptLines.append(line)
            if let message = Self.cliProvisioningMessage(for: line) {
                await progressMessage?(message)
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let transcript = transcriptLines.joined(separator: "\n")
            throw WorkspaceProviderError.unavailable(
                Self.cliProvisioningFailureMessage(
                    from: transcript,
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
        let executablePath = try await runtimeService.executablePath()
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

        let logURL = fileManager.temporaryDirectory
            .appendingPathComponent("workspaces-lume-run-\(vmName).log", isDirectory: false)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        launcher.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        launcher.arguments =
            [
                "-c",
                """
                import pathlib, subprocess, sys
                log_path = pathlib.Path(sys.argv[1])
                log_path.parent.mkdir(parents=True, exist_ok=True)
                with log_path.open("ab") as stream:
                    subprocess.Popen(
                        sys.argv[2:],
                        stdin=subprocess.DEVNULL,
                        stdout=stream,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                """,
                logURL.path,
                executablePath,
            ] + arguments
        launcher.standardInput = nil

        try launcher.run()
        launcher.waitUntilExit()

        guard launcher.terminationStatus == 0 else {
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
        let executablePath = try await runtimeService.executablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = ["stop", vmName]
        if let storagePath {
            arguments.append(contentsOf: ["--storage", storagePath])
        }
        process.arguments = arguments
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WorkspaceProviderError.unavailable("Failed to stop macOS VM '\(vmName)'.")
        }
    }

    private func deleteVMWithCLI(named vmName: String, storagePath: String?) async throws {
        let executablePath = try await runtimeService.executablePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments = ["delete", vmName, "--force"]
        if let storagePath {
            arguments.append(contentsOf: ["--storage", storagePath])
        }
        process.arguments = arguments
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
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
        let executablePath = try await runtimeService.executablePath()
        let result = try await ProcessRunner.run(
            executable: executablePath,
            arguments: ["get", vmName, "--storage", storagePath, "-f", "json"],
            currentDirectory: fileManager.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
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

        while Date() < deadline {
            let details: LumeVMDetails
            do {
                details = try await getVM(named: vmName, storagePath: storagePath)
            } catch {
                if let asyncCreationFailureMessage = asyncCreationFailureMessage(for: vmName) {
                    throw WorkspaceProviderError.unavailable(asyncCreationFailureMessage)
                }

                if shouldTreatAsMissingVM(error), lastDetails == nil {
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

        let status = lastDetails?.status ?? "unknown"
        throw WorkspaceProviderError.unavailable(
            "Timed out waiting for Lume VM '\(vmName)' to become ready (last status: \(status))."
        )
    }

    private func statusMessage(for details: LumeVMDetails) -> String? {
        let logTail: String?
        if details.status == "provisioning" || details.status == "provisioning (stale)" {
            logTail = readDaemonLogTail()
        } else {
            logTail = nil
        }

        return LumeProgressMessageBuilder.message(
            status: details.status,
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
        guard let url = endpointURL(for: path, queryItems: queryItems) else {
            throw WorkspaceProviderError.unavailable("Invalid Lume endpoint path: \(path)")
        }
        let encodedBody = try body.map { try JSONEncoder().encode($0) }
        let (data, statusCode) = try await sendCurlRequest(
            method: method,
            url: url,
            body: encodedBody
        )

        guard (200...299).contains(statusCode) else {
            if let apiError = try? JSONDecoder().decode(LumeAPIError.self, from: data) {
                throw WorkspaceProviderError.unavailable(apiError.message)
            }

            let message = String(data: data, encoding: .utf8) ?? "HTTP \(statusCode)"
            throw WorkspaceProviderError.unavailable(message)
        }

        if Response.self == LumeEmptyResponse.self {
            return LumeEmptyResponse() as! Response
        }

        if data.isEmpty {
            throw WorkspaceProviderError.unavailable("Lume returned an empty response.")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func sendCurlRequest(
        method: String,
        url: URL,
        body: Data?
    ) async throws -> (Data, Int) {
        let statusMarker = "__LUME_HTTP_STATUS__:"
        var arguments = [
            "--silent",
            "--show-error",
            "--request", method,
            "--url", url.absoluteString,
            "--max-time", "30",
            "--header", "Connection: close",
            "--write-out", "\n\(statusMarker)%{http_code}",
        ]

        var temporaryBodyURL: URL?
        if let body {
            let bodyURL = fileManager.temporaryDirectory
                .appendingPathComponent("lume-request-\(UUID().uuidString).json")
            try body.write(to: bodyURL, options: .atomic)
            temporaryBodyURL = bodyURL
            arguments += [
                "--header", "Content-Type: application/json",
                "--data-binary", "@\(bodyURL.path)",
            ]
        }

        defer {
            if let temporaryBodyURL {
                try? fileManager.removeItem(at: temporaryBodyURL)
            }
        }

        let result = try await ProcessRunner.run(
            executable: "/usr/bin/curl",
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment
        )

        guard result.success else {
            let message =
                [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? "curl exited with status \(result.exitCode)"
            throw WorkspaceProviderError.unavailable(message)
        }

        let output = result.stdout
        guard let markerRange = output.range(of: statusMarker, options: .backwards) else {
            throw WorkspaceProviderError.unavailable("Lume curl response did not include an HTTP status.")
        }

        let bodyString = String(output[..<markerRange.lowerBound])
        let statusString = output[markerRange.upperBound...].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let statusCode = Int(statusString) else {
            throw WorkspaceProviderError.unavailable("Lume curl response returned an invalid HTTP status.")
        }

        return (Data(bodyString.utf8), statusCode)
    }

    private func endpointURL(for path: String, queryItems: [URLQueryItem] = []) -> URL? {
        let components =
            path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !components.isEmpty else {
            if queryItems.isEmpty {
                return baseURL
            }
            guard var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            baseComponents.queryItems = queryItems
            return baseComponents.url
        }

        let url = components.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: false)
        }
        guard !queryItems.isEmpty else {
            return url
        }
        guard var resolvedComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        resolvedComponents.queryItems = queryItems
        return resolvedComponents.url
    }

    private func cleanupWorkspaceDirectory(_ workspaceURL: URL) {
        try? fileManager.removeItem(at: workspaceURL)

        let parentDirectory = workspaceURL.deletingLastPathComponent()
        if let contents = try? fileManager.contentsOfDirectory(atPath: parentDirectory.path),
            contents.isEmpty
        {
            try? fileManager.removeItem(at: parentDirectory)
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

    private func shouldFallbackToStockMacOSProvisioning(for error: Error) -> Bool {
        guard case .unavailable(let message)? = error as? WorkspaceProviderError else {
            return false
        }

        let normalized = message.lowercased()
        return normalized.contains("fetch image manifest from registry")
            || normalized.contains("fetch authentication token from registry")
            || normalized.contains("denied")
            || normalized.contains("not found")
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

    private func shouldTreatAsMissingVM(_ error: Error) -> Bool {
        guard case .unavailable(let message)? = error as? WorkspaceProviderError else {
            return false
        }

        let normalized = message.lowercased()
        return normalized.contains("not found")
            || normalized.contains("no vm")
            || normalized.contains("does not exist")
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

    static func mapStatus(_ rawValue: String) -> WorkspaceStatus {
        switch rawValue {
        case "running":
            return .active
        case "stopped":
            return .stopped
        case "provisioning", "provisioning (stale)":
            return .provisioning
        default:
            return .archived
        }
    }

    static func shouldRetryMacOSProvisioningWithCLI(for error: Error) -> Bool {
        guard case .unavailable(let message)? = error as? WorkspaceProviderError else {
            return false
        }

        let normalized = message.lowercased()
        return normalized.contains("restore image catalog failed to load")
            || normalized.contains("installation service returned an unexpected error")
            || normalized.contains("virtual machine not found")
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

private struct LumeCloneVMRequest: Encodable {
    let name: String
    let newName: String
    let sourceLocation: String?
    let destLocation: String?
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
    let provisioningOperation: String?
    let ipAddress: String?
    let sshAvailable: Bool?
    let vncURL: URL?

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case os
        case provisioningOperation
        case ipAddress
        case sshAvailable
        case vncURL = "vncUrl"
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

private struct LumeCloneVMResponse: Decodable {
    let message: String
    let source: String
    let destination: String
}

private struct LumeMessageResponse: Decodable {
    let message: String
}

private struct LumeAPIError: Decodable {
    let message: String
}

struct LumeProgressMessageBuilder {
    static func message(
        status: String,
        guestOS: String?,
        provisioningOperation: String?,
        sshAvailable: Bool?,
        logTail: String?
    ) -> String? {
        switch status {
        case "provisioning", "provisioning (stale)":
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

        case "running":
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

private struct LumeEmptyBody: Encodable {}
private struct LumeEmptyResponse: Decodable {}

import Foundation
import WorkspaceManagerCore

struct WorkspaceEnvironmentFixtureState {
    let providerAvailabilityByID: [String: WorkspaceProviderAvailability]
    let lumeRuntimeSnapshot: LumeRuntimeSnapshot?
}

struct WorkspaceEnvironmentOptionsController {
    private static let probeTimeoutNanoseconds: UInt64 = 5_000_000_000

    private struct SnapshotRefreshResult {
        let snapshot: LumeRuntimeSnapshot?
        let timedOut: Bool
    }

    func providerAvailabilityIsPending(
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        registry: WorkspaceProviderRegistry
    ) -> Bool {
        registry.providers.contains { provider in
            providerAvailabilityByID[provider.descriptor.id] == nil
        }
    }

    func providerAvailabilityRefreshSignature(
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        registry: WorkspaceProviderRegistry
    ) -> String {
        registry.providers
            .map(\.descriptor.id)
            .sorted()
            .map { providerID in
                guard let availability = providerAvailabilityByID[providerID] else {
                    return "\(providerID):pending"
                }
                return "\(providerID):\(availability.isAvailable):\(availability.reason ?? "")"
            }
            .joined(separator: "|")
    }

    func lumeRuntimeRefreshSignature(snapshot: LumeRuntimeSnapshot?) -> String {
        guard let snapshot else {
            return "snapshot:pending"
        }

        return [
            snapshot.state.rawValue,
            snapshot.reason ?? "",
            snapshot.defaultMacOSImage?.entry.imageReference ?? "",
            snapshot.defaultMacOSImageError ?? "",
        ]
        .joined(separator: "|")
    }

    func newWorkspaceSheetRefreshID(
        for repo: Repo,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        registry: WorkspaceProviderRegistry,
        lumeRuntimeSnapshot: LumeRuntimeSnapshot?,
        isCreating: Bool
    ) -> String {
        [
            repo.id.uuidString,
            providerAvailabilityRefreshSignature(
                providerAvailabilityByID: providerAvailabilityByID,
                registry: registry
            ),
            lumeRuntimeRefreshSignature(snapshot: lumeRuntimeSnapshot),
            isCreating ? "creating" : "idle",
        ]
        .joined(separator: "::")
    }

    func seedFixtureStateIfNeeded(
        runtimeService: any LumeRuntimeServiceProtocol
    ) async -> WorkspaceEnvironmentFixtureState? {
        guard UIFixtureLumeEnvironment.isEnabled() else { return nil }

        return WorkspaceEnvironmentFixtureState(
            providerAvailabilityByID: UIFixtureLumeEnvironment.initialProviderAvailabilityByID(),
            // Fixture mode keeps the full snapshot path so CI automation fails
            // deterministically instead of degrading to a timed-out placeholder.
            lumeRuntimeSnapshot: await runtimeService.snapshot()
        )
    }

    func refreshProviderAvailability(
        registry: WorkspaceProviderRegistry,
        existingAvailabilityByID: [String: WorkspaceProviderAvailability],
        trigger: String,
        timeoutNanoseconds: UInt64 = probeTimeoutNanoseconds
    ) async -> [String: WorkspaceProviderAvailability] {
        let refreshStartedAt = Date()
        var resolvedAvailability = existingAvailabilityByID
        if resolvedAvailability[LocalWorkspaceProvider.identifier] == nil {
            resolvedAvailability[LocalWorkspaceProvider.identifier] = .available
        }

        await withTaskGroup(of: (String, WorkspaceProviderAvailability).self) { group in
            for provider in registry.providers {
                group.addTask {
                    (
                        provider.descriptor.id,
                        await availabilityWithTimeout(
                            for: provider,
                            displayName: provider.descriptor.displayName,
                            timeoutNanoseconds: timeoutNanoseconds
                        )
                    )
                }
            }

            for await (providerID, availability) in group {
                resolvedAvailability[providerID] = availability
            }
        }

        let unavailableCount = resolvedAvailability.values.filter { !$0.isAvailable }.count
        NSLog(
            "[Perf] metric=workspace_provider_availability_refresh duration_ms=%.2f trigger=%@ providers=%ld unavailable_count=%ld",
            Date().timeIntervalSince(refreshStartedAt) * 1000,
            trigger,
            registry.providers.count,
            unavailableCount
        )

        return resolvedAvailability
    }

    func refreshLumeRuntimeSnapshot(
        runtimeService: any LumeRuntimeServiceProtocol,
        existingSnapshot: LumeRuntimeSnapshot?,
        trigger: String,
        timeoutNanoseconds: UInt64 = probeTimeoutNanoseconds
    ) async -> LumeRuntimeSnapshot? {
        let refreshStartedAt = Date()
        let refreshResult = await snapshotWithTimeout(
            runtimeService: runtimeService,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let snapshot = refreshResult.snapshot ?? existingSnapshot
        let outcome =
            if refreshResult.timedOut {
                existingSnapshot == nil ? "timeout" : "timeout_fallback"
            } else {
                "success"
            }
        NSLog(
            "[Perf] metric=lume_runtime_snapshot_refresh duration_ms=%.2f trigger=%@ outcome=%@ state=%@ base_vm_status=%@",
            Date().timeIntervalSince(refreshStartedAt) * 1000,
            trigger,
            outcome,
            snapshot?.state.rawValue ?? "pending",
            snapshot?.baseVM?.status.rawValue ?? "none"
        )
        return snapshot
    }

    func environmentOptions(
        for repo: Repo,
        registry: WorkspaceProviderRegistry,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        isRefreshingProviderAvailability: Bool,
        lumeRuntimeSnapshot: LumeRuntimeSnapshot?
    ) -> [WorkspaceEnvironmentSheetOption] {
        registry.providers.flatMap { provider in
            let descriptor = provider.descriptor
            let guestOSOptions =
                descriptor.supportedGuestOS.isEmpty
                ? [WorkspaceGuestOS?.none]
                : descriptor.supportedGuestOS.map(Optional.some)

            return guestOSOptions.compactMap { guestOS in
                environmentOption(
                    for: descriptor,
                    guestOS: guestOS,
                    repo: repo,
                    providerAvailabilityByID: providerAvailabilityByID,
                    isRefreshingProviderAvailability: isRefreshingProviderAvailability,
                    lumeRuntimeSnapshot: lumeRuntimeSnapshot
                )
            }
        }
    }

    private func environmentOption(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?,
        repo: Repo,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        isRefreshingProviderAvailability: Bool,
        lumeRuntimeSnapshot: LumeRuntimeSnapshot?
    ) -> WorkspaceEnvironmentSheetOption? {
        switch (descriptor.id, guestOS) {
        case (LocalWorkspaceProvider.identifier, nil):
            localEnvironmentOption(
                for: repo,
                descriptor: descriptor,
                providerAvailabilityByID: providerAvailabilityByID,
                isRefreshingProviderAvailability: isRefreshingProviderAvailability
            )
        case (DaytonaWorkspaceProvider.identifier, .linux):
            cloudLinuxEnvironmentOption(
                for: repo,
                descriptor: descriptor,
                providerAvailabilityByID: providerAvailabilityByID,
                isRefreshingProviderAvailability: isRefreshingProviderAvailability
            )
        case (LumeWorkspaceProvider.identifier, .macOS):
            macOSEnvironmentOption(
                lumeRuntimeSnapshot: lumeRuntimeSnapshot
            )
        case (LumeWorkspaceProvider.identifier, .linux):
            linuxVMEnvironmentOption(
                lumeRuntimeSnapshot: lumeRuntimeSnapshot
            )
        default:
            nil
        }
    }

    private func landingAvailability(
        for descriptor: WorkspaceProviderDescriptor,
        repo: Repo,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        isRefreshingProviderAvailability: Bool
    ) -> WorkspaceProviderAvailability {
        let baseAvailability: WorkspaceProviderAvailability
        if let resolvedAvailability = providerAvailabilityByID[descriptor.id] {
            baseAvailability = resolvedAvailability
        } else if descriptor.id == LocalWorkspaceProvider.identifier {
            baseAvailability = .available
        } else if isRefreshingProviderAvailability {
            baseAvailability = .unavailable("Checking provider availability...")
        } else {
            baseAvailability = .unavailable("Timed out checking provider availability.")
        }

        guard baseAvailability.isAvailable else { return baseAvailability }

        if descriptor.requiresRemoteRepository,
            repo.remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        {
            return .unavailable("This repository needs a remote origin URL for \(descriptor.displayName).")
        }

        return baseAvailability
    }

    private func localEnvironmentOption(
        for repo: Repo,
        descriptor: WorkspaceProviderDescriptor,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        isRefreshingProviderAvailability: Bool
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = landingAvailability(
            for: descriptor,
            repo: repo,
            providerAvailabilityByID: providerAvailabilityByID,
            isRefreshingProviderAvailability: isRefreshingProviderAvailability
        )

        return WorkspaceEnvironmentSheetOption(
            title: "Local",
            subtitle: "Create a local workspace copy on this Mac",
            description: descriptor.description,
            iconName: "plus.rectangle.on.folder.fill",
            providerID: LocalWorkspaceProvider.identifier,
            guestOS: nil,
            isAvailable: availability.isAvailable,
            statusText: nil,
            statusSeverity: nil,
            availabilityReason: availability.reason
        )
    }

    private func cloudLinuxEnvironmentOption(
        for repo: Repo,
        descriptor: WorkspaceProviderDescriptor,
        providerAvailabilityByID: [String: WorkspaceProviderAvailability],
        isRefreshingProviderAvailability: Bool
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = landingAvailability(
            for: descriptor,
            repo: repo,
            providerAvailabilityByID: providerAvailabilityByID,
            isRefreshingProviderAvailability: isRefreshingProviderAvailability
        )

        return WorkspaceEnvironmentSheetOption(
            title: "Cloud Linux",
            subtitle: "Runs in Daytona cloud infrastructure",
            description: descriptor.description,
            iconName: "cloud.fill",
            providerID: DaytonaWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            statusText: nil,
            statusSeverity: nil,
            availabilityReason: availability.reason
        )
    }

    private func macOSEnvironmentOption(
        lumeRuntimeSnapshot: LumeRuntimeSnapshot?
    ) -> WorkspaceEnvironmentSheetOption {
        let baseAvailability = lumeEnvironmentAvailability(snapshot: lumeRuntimeSnapshot)

        let isAvailable: Bool
        let availabilityReason: String?
        if !baseAvailability.isAvailable {
            isAvailable = false
            availabilityReason = baseAvailability.reason
        } else if let snapshot = lumeRuntimeSnapshot,
            snapshot.state == .unsupportedHost
        {
            isAvailable = false
            availabilityReason = snapshot.reason
        } else {
            isAvailable = true
            availabilityReason = nonBlockingMacOSAvailabilityReason(snapshot: lumeRuntimeSnapshot)
        }

        return WorkspaceEnvironmentSheetOption(
            title: "macOS VM",
            subtitle: macOSBaseSummary(snapshot: lumeRuntimeSnapshot),
            description: macOSEnvironmentDescription(snapshot: lumeRuntimeSnapshot),
            iconName: "desktopcomputer",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .macOS,
            isAvailable: isAvailable,
            statusText: macOSRuntimeStatusText(snapshot: lumeRuntimeSnapshot),
            statusSeverity: macOSRuntimeStatusSeverity(snapshot: lumeRuntimeSnapshot),
            availabilityReason: availabilityReason
        )
    }

    private func linuxVMEnvironmentOption(
        lumeRuntimeSnapshot: LumeRuntimeSnapshot?
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = lumeEnvironmentAvailability(snapshot: lumeRuntimeSnapshot)

        return WorkspaceEnvironmentSheetOption(
            title: "Linux VM",
            subtitle: "Runs in a local Linux VM on this Mac",
            description: linuxVMEnvironmentDescription(snapshot: lumeRuntimeSnapshot),
            iconName: "server.rack",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            statusText: lumeRuntimeStatusText(snapshot: lumeRuntimeSnapshot),
            statusSeverity: lumeRuntimeStatusSeverity(snapshot: lumeRuntimeSnapshot),
            availabilityReason: availability.reason
        )
    }

    private func lumeEnvironmentAvailability(
        snapshot: LumeRuntimeSnapshot?
    ) -> WorkspaceProviderAvailability {
        if let snapshot, snapshot.state == .unsupportedHost {
            return .unavailable(snapshot.reason ?? "Lume requires Apple Silicon.")
        }

        #if arch(arm64)
            return .available
        #else
            return .unavailable("Lume requires Apple Silicon.")
        #endif
    }

    private func lumeRuntimeStatusText(snapshot: LumeRuntimeSnapshot?) -> String? {
        guard let snapshot else { return nil }
        switch snapshot.state {
        case .setupRequired:
            return "Setup required"
        case .repairRequired:
            return "Repair required"
        case .ready:
            return "Ready"
        case .installing:
            return "Installing"
        case .verifying:
            return "Verifying"
        case .unsupportedHost:
            return nil
        }
    }

    private func lumeRuntimeStatusSeverity(snapshot: LumeRuntimeSnapshot?) -> EnvironmentStatusSeverity? {
        guard let snapshot else { return nil }
        switch snapshot.state {
        case .setupRequired:
            return .warning
        case .repairRequired:
            return .error
        case .ready:
            return .neutral
        case .installing, .verifying:
            return .neutral
        case .unsupportedHost:
            return nil
        }
    }

    private func macOSRuntimeStatusText(snapshot: LumeRuntimeSnapshot?) -> String? {
        if let snapshot, snapshot.state != .ready {
            return lumeRuntimeStatusText(snapshot: snapshot)
        }

        if let baseSnapshot = snapshot?.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "Fast clone ready"
            case .preparing:
                return "Preparing base"
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return "Downloads base on first use"
                }
                return "Prepares base on first use"
            case .repairRequired:
                return "Repair base VM"
            }
        }

        if let snapshot,
            snapshot.state == .ready,
            snapshot.defaultMacOSImage == nil,
            snapshot.defaultMacOSImageError != nil
        {
            return "Stock macOS"
        }

        return lumeRuntimeStatusText(snapshot: snapshot)
    }

    private func macOSRuntimeStatusSeverity(snapshot: LumeRuntimeSnapshot?) -> EnvironmentStatusSeverity? {
        if let snapshot, snapshot.state != .ready {
            return lumeRuntimeStatusSeverity(snapshot: snapshot)
        }

        if let baseSnapshot = snapshot?.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return .good
            case .preparing:
                return .neutral
            case .missing:
                return .neutral
            case .repairRequired:
                return .warning
            }
        }

        if let snapshot,
            snapshot.state == .ready,
            snapshot.defaultMacOSImage == nil,
            snapshot.defaultMacOSImageError != nil
        {
            return .neutral
        }

        return lumeRuntimeStatusSeverity(snapshot: snapshot)
    }

    private func macOSEnvironmentDescription(snapshot: LumeRuntimeSnapshot?) -> String {
        let base =
            "Runs in a local macOS VM. Files stay on the host, the terminal opens in-app with `lume ssh`, and desktop opens in an external VNC client."

        guard let snapshot else {
            return base
        }

        switch snapshot.state {
        case .setupRequired:
            return "\(base) Workspaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) Workspaces will repair the local VM runtime automatically before continuing."
        case .ready, .installing, .verifying, .unsupportedHost:
            break
        }

        if let baseSnapshot = snapshot.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "\(base) Workspaces will clone the prepared base VM for a faster macOS workspace start."
            case .preparing:
                return "\(base) A prepared base VM is already being created. Workspaces will clone it once it is ready."
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return """
                        \(base) Workspaces will download the matching base VM once, then clone it for faster future macOS workspaces.
                        """
                }
                return """
                    \(base) No host-matched golden image is available yet, so Workspaces will prepare a stock macOS base VM once and clone it for faster future workspaces.
                    """
            case .repairRequired:
                return "\(base) Workspaces will repair or recreate the prepared base VM before continuing."
            }
        }

        if snapshot.defaultMacOSImage == nil, snapshot.defaultMacOSImageError != nil {
            return """
                \(base) No host-matched golden image is available yet, so Workspaces will fall back to stock macOS setup automatically.
                """
        }

        return base
    }

    private func linuxVMEnvironmentDescription(snapshot: LumeRuntimeSnapshot?) -> String {
        let base =
            "Uses the same host-shared file model as macOS VM workspaces. Terminal opens in-app, and desktop opens externally when available."

        guard let snapshot else {
            return base
        }

        switch snapshot.state {
        case .setupRequired:
            return "\(base) Workspaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) Workspaces will repair the local VM runtime automatically before continuing."
        case .ready, .installing, .verifying, .unsupportedHost:
            return base
        }
    }

    private func nonBlockingMacOSAvailabilityReason(snapshot: LumeRuntimeSnapshot?) -> String? {
        guard let snapshot else { return nil }

        if let baseSnapshot = snapshot.baseVM, let reason = baseSnapshot.reason {
            return reason
        }

        if snapshot.defaultMacOSImage == nil, snapshot.defaultMacOSImageError != nil {
            return "Workspaces will use stock macOS because no host-matched golden image is available yet."
        }

        return nil
    }

    private func macOSBaseSummary(snapshot: LumeRuntimeSnapshot?) -> String {
        guard let snapshot else {
            return "Matches this Mac by default"
        }

        if let baseSnapshot = snapshot.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "Fast clone ready: \(baseSnapshot.profile.displayName)"
            case .preparing:
                return "Preparing base: \(baseSnapshot.profile.displayName)"
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return "Will download base once: \(baseSnapshot.profile.displayName)"
                }
                return "Needs one-time base preparation"
            case .repairRequired:
                return "Needs base VM repair: \(baseSnapshot.profile.displayName)"
            }
        }

        return snapshot.defaultMacOSImage?.profileDisplayName
            ?? snapshot.hostProfile?.displayName
            ?? "Matches this Mac by default"
    }

    private func availabilityWithTimeout(
        for provider: any WorkspaceProviderProtocol,
        displayName: String,
        timeoutNanoseconds: UInt64
    ) async -> WorkspaceProviderAvailability {
        await withTaskGroup(of: WorkspaceProviderAvailability?.self) { group in
            group.addTask {
                await provider.availability()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()

            if let availability = firstResult {
                return availability
            }

            return .unavailable("Timed out checking \(displayName) availability.")
        }
    }

    // Note: snapshot() has no per-step internal timeouts. If a subprocess
    // (e.g. xcodebuild -version) hangs at the OS level, this outer timeout
    // fires but the underlying task stays alive until cancellation propagates.
    // See #107 for follow-up.
    private func snapshotWithTimeout(
        runtimeService: any LumeRuntimeServiceProtocol,
        timeoutNanoseconds: UInt64
    ) async -> SnapshotRefreshResult {
        await withTaskGroup(of: SnapshotRefreshResult.self) { group in
            group.addTask {
                SnapshotRefreshResult(
                    snapshot: await runtimeService.snapshot(),
                    timedOut: false
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return SnapshotRefreshResult(snapshot: nil, timedOut: true)
            }

            let firstResult =
                await group.next()
                ?? SnapshotRefreshResult(
                    snapshot: nil,
                    timedOut: true
                )
            group.cancelAll()
            return firstResult
        }
    }
}

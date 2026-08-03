import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "WorkspaceEnvironmentOptionsController")

struct WorkspaceProviderSheetState: Sendable, Equatable {
    let providerID: String
    let statusPolicy: WorkspaceProviderSheetStatusPolicy
    let availability: WorkspaceProviderAvailability?
    let isRefreshing: Bool
    let detail: WorkspaceProviderSheetDetail

    static func initial(for descriptor: WorkspaceProviderDescriptor) -> Self {
        WorkspaceProviderSheetState(
            providerID: descriptor.id,
            statusPolicy: descriptor.sheetStatusPolicy,
            availability: descriptor.sheetStatusPolicy == .immediate ? .available : nil,
            isRefreshing: false,
            detail: descriptor.id == LumeWorkspaceProvider.identifier ? .lume(snapshot: nil) : .none
        )
    }

    func replacing(
        availability: WorkspaceProviderAvailability? = nil,
        isRefreshing: Bool? = nil,
        detail: WorkspaceProviderSheetDetail? = nil
    ) -> Self {
        WorkspaceProviderSheetState(
            providerID: providerID,
            statusPolicy: statusPolicy,
            availability: availability ?? self.availability,
            isRefreshing: isRefreshing ?? self.isRefreshing,
            detail: detail ?? self.detail
        )
    }
}

enum WorkspaceProviderSheetDetail: Sendable, Equatable {
    case none
    case lume(snapshot: LumeRuntimeSnapshot?)

    var lumeRuntimeSnapshot: LumeRuntimeSnapshot? {
        switch self {
        case .none:
            return nil
        case .lume(let snapshot):
            return snapshot
        }
    }
}

struct WorkspaceEnvironmentSheetState: Sendable, Equatable {
    let providerStatesByID: [String: WorkspaceProviderSheetState]

    static let empty = WorkspaceEnvironmentSheetState(providerStatesByID: [:])

    func providerState(for descriptor: WorkspaceProviderDescriptor) -> WorkspaceProviderSheetState {
        providerStatesByID[descriptor.id] ?? WorkspaceProviderSheetState.initial(for: descriptor)
    }

    func updating(_ state: WorkspaceProviderSheetState) -> Self {
        var providerStatesByID = self.providerStatesByID
        providerStatesByID[state.providerID] = state
        return WorkspaceEnvironmentSheetState(providerStatesByID: providerStatesByID)
    }

    var providerAvailabilityByID: [String: WorkspaceProviderAvailability] {
        providerStatesByID.reduce(into: [:]) { partialResult, entry in
            if let availability = entry.value.availability {
                partialResult[entry.key] = availability
            }
        }
    }

    var lumeRuntimeSnapshot: LumeRuntimeSnapshot? {
        providerStatesByID[LumeWorkspaceProvider.identifier]?.detail.lumeRuntimeSnapshot
    }
}

struct WorkspaceEnvironmentOptionsController {
    private static let probeTimeoutNanoseconds: UInt64 = 5_000_000_000

    private struct SnapshotRefreshResult {
        let snapshot: LumeRuntimeSnapshot?
        let timedOut: Bool
    }

    func prepareSheetStateForPresentation(
        existingState: WorkspaceEnvironmentSheetState,
        registry: WorkspaceProviderRegistry
    ) -> WorkspaceEnvironmentSheetState {
        var resolvedState = mergedSheetState(existingState: existingState, registry: registry)

        for provider in registry.providers {
            let descriptor = provider.descriptor
            var providerState = resolvedState.providerState(for: descriptor)

            switch descriptor.sheetStatusPolicy {
            case .immediate:
                providerState = providerState.replacing(
                    availability: providerState.availability ?? .available,
                    isRefreshing: false
                )
            case .deferred:
                if providerState.availability == nil {
                    providerState = providerState.replacing(isRefreshing: true)
                }
            }

            resolvedState = resolvedState.updating(providerState)
        }

        return resolvedState
    }

    func seedFixtureStateIfNeeded(
        registry: WorkspaceProviderRegistry,
        runtimeService: any LumeRuntimeServiceProtocol
    ) async -> WorkspaceEnvironmentSheetState? {
        guard UIFixtureLumeEnvironment.isEnabled() else { return nil }

        let snapshot = await runtimeService.snapshot()
        var resolvedState = prepareSheetStateForPresentation(
            existingState: .empty,
            registry: registry
        )

        for provider in registry.providers {
            var providerState = resolvedState.providerState(for: provider.descriptor).replacing(
                availability: .available,
                isRefreshing: false
            )

            if provider.descriptor.id == LumeWorkspaceProvider.identifier {
                providerState = providerState.replacing(detail: .lume(snapshot: snapshot))
            }

            resolvedState = resolvedState.updating(providerState)
        }

        return resolvedState
    }

    func refreshSheetState(
        registry: WorkspaceProviderRegistry,
        runtimeService: any LumeRuntimeServiceProtocol,
        existingState: WorkspaceEnvironmentSheetState,
        trigger: String,
        timeoutNanoseconds: UInt64 = probeTimeoutNanoseconds
    ) async -> WorkspaceEnvironmentSheetState {
        var resolvedState = prepareSheetStateForPresentation(
            existingState: existingState,
            registry: registry
        )

        let deferredProviders = registry.providers.filter {
            $0.descriptor.sheetStatusPolicy == .deferred
        }
        let deferredRegistry = WorkspaceProviderRegistry(providers: deferredProviders)
        let needsLumeSnapshot =
            registry.provider(for: LumeWorkspaceProvider.identifier) != nil
        let capturedExistingAvailability = resolvedState.providerAvailabilityByID
        let capturedExistingSnapshot = resolvedState.lumeRuntimeSnapshot

        // Run provider availability and Lume snapshot refresh in parallel
        // instead of sequentially — avoids stacking two 5s timeout windows.
        async let availabilityResult = refreshProviderAvailability(
            registry: deferredRegistry,
            existingAvailabilityByID: capturedExistingAvailability,
            trigger: trigger,
            timeoutNanoseconds: timeoutNanoseconds
        )
        async let snapshotResult: LumeRuntimeSnapshot? =
            needsLumeSnapshot
            ? refreshLumeRuntimeSnapshot(
                runtimeService: runtimeService,
                existingSnapshot: capturedExistingSnapshot,
                trigger: trigger,
                timeoutNanoseconds: timeoutNanoseconds
            )
            : nil

        let deferredAvailabilityByID = await availabilityResult
        let lumeSnapshot = await snapshotResult

        for provider in registry.providers {
            let descriptor = provider.descriptor
            var providerState = resolvedState.providerState(for: descriptor)

            switch descriptor.sheetStatusPolicy {
            case .immediate:
                providerState = providerState.replacing(
                    availability: providerState.availability ?? .available,
                    isRefreshing: false
                )
            case .deferred:
                providerState = providerState.replacing(
                    availability: deferredAvailabilityByID[descriptor.id],
                    isRefreshing: false
                )
            }

            resolvedState = resolvedState.updating(providerState)
        }

        if needsLumeSnapshot {
            let descriptor = LumeWorkspaceProvider.providerDescriptor
            let providerState = resolvedState.providerState(for: descriptor).replacing(
                isRefreshing: false,
                detail: .lume(snapshot: lumeSnapshot)
            )
            resolvedState = resolvedState.updating(providerState)
        }

        return resolvedState
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
        let durationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
        log.info(
            "[Perf] metric=workspace_provider_availability_refresh duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) trigger=\(trigger, privacy: .public) providers=\(registry.providers.count, privacy: .public) unavailable_count=\(unavailableCount, privacy: .public)"
        )
        await StartupDiagnosticsStore.shared.record(
            metric: "workspace_provider_availability_refresh",
            durationMs: durationMs,
            labels: [
                "trigger": trigger,
                "providers": "\(registry.providers.count)",
                "unavailable_count": "\(unavailableCount)",
            ]
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
        let durationMs = Date().timeIntervalSince(refreshStartedAt) * 1000
        log.info(
            "[Perf] metric=lume_runtime_snapshot_refresh duration_ms=\(String(format: "%.2f", durationMs), privacy: .public) trigger=\(trigger, privacy: .public) outcome=\(outcome, privacy: .public) state=\(snapshot?.state.rawValue ?? "pending", privacy: .public) base_vm_status=\(snapshot?.baseVM?.status.rawValue ?? "none", privacy: .public)"
        )
        await StartupDiagnosticsStore.shared.record(
            metric: "lume_runtime_snapshot_refresh",
            durationMs: durationMs,
            labels: [
                "trigger": trigger,
                "outcome": outcome,
                "state": snapshot?.state.rawValue ?? "pending",
                "base_vm_status": snapshot?.baseVM?.status.rawValue ?? "none",
            ]
        )
        return snapshot
    }

    func environmentOptions(
        for repo: Repo,
        registry: WorkspaceProviderRegistry,
        sheetState: WorkspaceEnvironmentSheetState
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
                    sheetState: sheetState
                )
            }
        }
    }

    private func mergedSheetState(
        existingState: WorkspaceEnvironmentSheetState,
        registry: WorkspaceProviderRegistry
    ) -> WorkspaceEnvironmentSheetState {
        registry.providers.reduce(into: WorkspaceEnvironmentSheetState.empty) { partialResult, provider in
            let descriptor = provider.descriptor
            let existingProviderState = existingState.providerStatesByID[descriptor.id]
            partialResult = partialResult.updating(existingProviderState ?? .initial(for: descriptor))
        }
    }

    private func environmentOption(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?,
        repo: Repo,
        sheetState: WorkspaceEnvironmentSheetState
    ) -> WorkspaceEnvironmentSheetOption? {
        switch (descriptor.id, guestOS) {
        case (LocalWorkspaceProvider.identifier, nil):
            localEnvironmentOption(
                for: repo,
                descriptor: descriptor,
                sheetState: sheetState
            )
        case (DaytonaWorkspaceProvider.identifier, .linux):
            cloudLinuxEnvironmentOption(
                for: repo,
                descriptor: descriptor,
                sheetState: sheetState
            )
        case (LumeWorkspaceProvider.identifier, .macOS):
            macOSEnvironmentOption(
                providerState: sheetState.providerState(for: descriptor)
            )
        case (LumeWorkspaceProvider.identifier, .linux):
            linuxVMEnvironmentOption(
                providerState: sheetState.providerState(for: descriptor)
            )
        default:
            genericEnvironmentOption(
                for: descriptor,
                guestOS: guestOS,
                repo: repo,
                sheetState: sheetState
            )
        }
    }

    private func landingAvailability(
        for descriptor: WorkspaceProviderDescriptor,
        repo: Repo,
        sheetState: WorkspaceEnvironmentSheetState
    ) -> WorkspaceProviderAvailability {
        let providerState = sheetState.providerState(for: descriptor)

        let baseAvailability: WorkspaceProviderAvailability
        if let resolvedAvailability = providerState.availability {
            baseAvailability = resolvedAvailability
        } else if descriptor.sheetStatusPolicy == .immediate {
            baseAvailability = .available
        } else if providerState.isRefreshing {
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
        sheetState: WorkspaceEnvironmentSheetState
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = landingAvailability(
            for: descriptor,
            repo: repo,
            sheetState: sheetState
        )

        return WorkspaceEnvironmentSheetOption(
            title: "Local",
            subtitle: "Create a git worktree workspace on this Mac",
            description: descriptor.description,
            iconName: "plus.rectangle.on.folder.fill",
            providerID: LocalWorkspaceProvider.identifier,
            guestOS: nil,
            isAvailable: availability.isAvailable,
            isLoading: false,
            statusText: nil,
            statusSeverity: nil,
            availabilityReason: availability.reason
        )
    }

    private func cloudLinuxEnvironmentOption(
        for repo: Repo,
        descriptor: WorkspaceProviderDescriptor,
        sheetState: WorkspaceEnvironmentSheetState
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = landingAvailability(
            for: descriptor,
            repo: repo,
            sheetState: sheetState
        )
        let providerState = sheetState.providerState(for: descriptor)

        return WorkspaceEnvironmentSheetOption(
            title: "Cloud Linux",
            subtitle: "Runs in Daytona cloud infrastructure",
            description: descriptor.description,
            iconName: "cloud.fill",
            providerID: DaytonaWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            isLoading: providerState.isRefreshing,
            statusText: providerState.isRefreshing && providerState.availability == nil
                ? "Checking cloud runtime" : nil,
            statusSeverity: nil,
            availabilityReason: availability.reason
        )
    }

    private func macOSEnvironmentOption(
        providerState: WorkspaceProviderSheetState
    ) -> WorkspaceEnvironmentSheetOption {
        let snapshot = providerState.detail.lumeRuntimeSnapshot
        let baseAvailability = lumeEnvironmentAvailability(providerState: providerState)

        let isAvailable: Bool
        let availabilityReason: String?
        if !baseAvailability.isAvailable {
            isAvailable = false
            availabilityReason = baseAvailability.reason
        } else if let snapshot, snapshot.state == .unsupportedHost {
            isAvailable = false
            availabilityReason = snapshot.reason
        } else {
            isAvailable = true
            availabilityReason = nonBlockingMacOSAvailabilityReason(snapshot: snapshot)
        }

        return WorkspaceEnvironmentSheetOption(
            title: "macOS VM",
            subtitle: macOSBaseSummary(snapshot: snapshot),
            description: macOSEnvironmentDescription(snapshot: snapshot),
            iconName: "desktopcomputer",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .macOS,
            isAvailable: isAvailable,
            isLoading: providerState.isRefreshing,
            statusText: macOSRuntimeStatusText(providerState: providerState),
            statusSeverity: macOSRuntimeStatusSeverity(snapshot: snapshot),
            availabilityReason: availabilityReason
        )
    }

    private func linuxVMEnvironmentOption(
        providerState: WorkspaceProviderSheetState
    ) -> WorkspaceEnvironmentSheetOption {
        let snapshot = providerState.detail.lumeRuntimeSnapshot
        let availability = lumeEnvironmentAvailability(providerState: providerState)

        return WorkspaceEnvironmentSheetOption(
            title: "Linux VM",
            subtitle: "Runs in a local Linux VM on this Mac",
            description: linuxVMEnvironmentDescription(snapshot: snapshot),
            iconName: "server.rack",
            providerID: LumeWorkspaceProvider.identifier,
            guestOS: .linux,
            isAvailable: availability.isAvailable,
            isLoading: providerState.isRefreshing,
            statusText: lumeRuntimeStatusText(providerState: providerState),
            statusSeverity: lumeRuntimeStatusSeverity(snapshot: snapshot),
            availabilityReason: availability.reason
        )
    }

    private func genericEnvironmentOption(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?,
        repo: Repo,
        sheetState: WorkspaceEnvironmentSheetState
    ) -> WorkspaceEnvironmentSheetOption {
        let availability = landingAvailability(
            for: descriptor,
            repo: repo,
            sheetState: sheetState
        )
        let providerState = sheetState.providerState(for: descriptor)

        return WorkspaceEnvironmentSheetOption(
            title: genericEnvironmentTitle(for: descriptor, guestOS: guestOS),
            subtitle: genericEnvironmentSubtitle(for: descriptor, guestOS: guestOS),
            description: descriptor.description,
            iconName: genericEnvironmentIcon(for: descriptor, guestOS: guestOS),
            providerID: descriptor.id,
            guestOS: guestOS,
            isAvailable: availability.isAvailable,
            isLoading: providerState.isRefreshing,
            statusText: nil,
            statusSeverity: nil,
            availabilityReason: availability.reason
        )
    }

    private func genericEnvironmentTitle(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?
    ) -> String {
        guard let guestOS else {
            return descriptor.displayName
        }

        return "\(descriptor.displayName) \(guestOS.label)"
    }

    private func genericEnvironmentSubtitle(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?
    ) -> String {
        guard let guestOS else {
            if descriptor.usesHostWorkspaceFiles {
                return "Runs on this Mac with host files"
            }
            if descriptor.requiresRemoteRepository {
                return "Requires a repository with a remote origin"
            }
            return "Available through \(descriptor.displayName)"
        }

        if descriptor.requiresRemoteRepository {
            return "Runs \(guestOS.label) via \(descriptor.displayName)"
        }
        if descriptor.usesHostWorkspaceFiles {
            return "Runs \(guestOS.label) on this Mac"
        }
        return "\(guestOS.label) environment via \(descriptor.displayName)"
    }

    private func genericEnvironmentIcon(
        for descriptor: WorkspaceProviderDescriptor,
        guestOS: WorkspaceGuestOS?
    ) -> String {
        switch guestOS {
        case .macOS:
            return "desktopcomputer"
        case .linux:
            return descriptor.requiresRemoteRepository ? "cloud.fill" : "server.rack"
        case nil:
            return descriptor.usesHostWorkspaceFiles
                ? "plus.rectangle.on.folder.fill"
                : "square.stack.3d.up.fill"
        }
    }

    private func lumeEnvironmentAvailability(
        providerState: WorkspaceProviderSheetState
    ) -> WorkspaceProviderAvailability {
        if let availability = providerState.availability, !availability.isAvailable {
            return availability
        }

        let snapshot = providerState.detail.lumeRuntimeSnapshot
        if let snapshot, snapshot.state == .unsupportedHost {
            return .unavailable(snapshot.reason ?? "Lume requires Apple Silicon.")
        }

        if providerState.isRefreshing && snapshot == nil {
            return .unavailable("Checking VM runtime...")
        }

        guard snapshot != nil else {
            return .unavailable("Timed out checking VM runtime.")
        }

        #if arch(arm64)
            return .available
        #else
            return .unavailable("Lume requires Apple Silicon.")
        #endif
    }

    private func lumeRuntimeStatusText(providerState: WorkspaceProviderSheetState) -> String? {
        let snapshot = providerState.detail.lumeRuntimeSnapshot

        if providerState.isRefreshing && snapshot == nil {
            return "Checking runtime"
        }

        guard let snapshot else {
            return "Runtime check timed out"
        }

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

    private func macOSRuntimeStatusText(providerState: WorkspaceProviderSheetState) -> String? {
        let snapshot = providerState.detail.lumeRuntimeSnapshot

        if providerState.isRefreshing && snapshot == nil {
            return "Checking runtime"
        }
        if let snapshot, snapshot.state != .ready {
            return lumeRuntimeStatusText(providerState: providerState)
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

        return lumeRuntimeStatusText(providerState: providerState)
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
            return "\(base) WorkSpaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) WorkSpaces will repair the local VM runtime automatically before continuing."
        case .ready, .installing, .verifying, .unsupportedHost:
            break
        }

        if let baseSnapshot = snapshot.baseVM {
            switch baseSnapshot.status {
            case .ready:
                return "\(base) WorkSpaces will clone the prepared base VM for a faster macOS workspace start."
            case .preparing:
                return "\(base) A prepared base VM is already being created. WorkSpaces will clone it once it is ready."
            case .missing:
                if baseSnapshot.profile.imageReference != nil {
                    return """
                        \(base) WorkSpaces will download the matching base VM once, then clone it for faster future macOS workspaces.
                        """
                }
                return """
                    \(base) No host-matched golden image is available yet, so WorkSpaces will prepare a stock macOS base VM once and clone it for faster future workspaces.
                    """
            case .repairRequired:
                return "\(base) WorkSpaces will repair or recreate the prepared base VM before continuing."
            }
        }

        if snapshot.defaultMacOSImage == nil, snapshot.defaultMacOSImageError != nil {
            return """
                \(base) No host-matched golden image is available yet, so WorkSpaces will fall back to stock macOS setup automatically.
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
            return "\(base) WorkSpaces will install and verify Lume automatically the first time you use this."
        case .repairRequired:
            return "\(base) WorkSpaces will repair the local VM runtime automatically before continuing."
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
            return "WorkSpaces will use stock macOS because no host-matched golden image is available yet."
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

import Foundation
import WorkspaceManagerCore

actor DeferredLumeRuntimeService: LumeRuntimeServiceProtocol {
    private let makeService: @Sendable () -> any LumeRuntimeServiceProtocol
    private var cachedService: (any LumeRuntimeServiceProtocol)?

    init(makeService: @escaping @Sendable () -> any LumeRuntimeServiceProtocol) {
        self.makeService = makeService
    }

    func snapshot() async -> LumeRuntimeSnapshot {
        await resolvedService().snapshot()
    }

    func baseVMSnapshot() async -> LumeBaseVMSnapshot? {
        await resolvedService().baseVMSnapshot()
    }

    func hostProfile() async throws -> LumeHostProfile {
        try await resolvedService().hostProfile()
    }

    func defaultMacOSImageResolution() async throws -> LumeImageResolution {
        try await resolvedService().defaultMacOSImageResolution()
    }

    func installIfNeeded(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        try await resolvedService().installIfNeeded(progress: progress)
    }

    func verifyInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        try await resolvedService().verifyInstallation(progress: progress)
    }

    func repairInstallation(progress: LumeRuntimeProgressHandler?) async throws -> LumeRuntimeSnapshot {
        try await resolvedService().repairInstallation(progress: progress)
    }

    func ensureBaseVMReady(progress: WorkspaceProviderProgressHandler?) async throws -> LumeBaseVMSnapshot {
        try await resolvedService().ensureBaseVMReady(progress: progress)
    }

    func deleteBaseVM() async throws -> LumeRuntimeSnapshot {
        try await resolvedService().deleteBaseVM()
    }

    func executablePath() async throws -> String {
        try await resolvedService().executablePath()
    }

    private func resolvedService() -> any LumeRuntimeServiceProtocol {
        if let cachedService {
            return cachedService
        }

        let service = makeService()
        cachedService = service
        return service
    }
}

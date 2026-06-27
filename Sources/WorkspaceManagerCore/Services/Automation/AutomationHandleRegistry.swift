import Foundation

@MainActor
public final class AutomationHandleRegistry {
    public struct Entry: Sendable, Equatable {
        public let handle: String
        public let hostSessionID: UUID
        public let tileID: TileID?
        public let surfaceKind: AutomationSurfaceKind
        public let windowScopeID: String
        public let appScopeID: String
        public let capabilities: [AutomationCapability]

        public init(
            handle: String,
            hostSessionID: UUID,
            tileID: TileID?,
            surfaceKind: AutomationSurfaceKind,
            windowScopeID: String,
            appScopeID: String,
            capabilities: [AutomationCapability] = AutomationAPI.v1Capabilities
        ) {
            self.handle = handle
            self.hostSessionID = hostSessionID
            self.tileID = tileID
            self.surfaceKind = surfaceKind
            self.windowScopeID = windowScopeID
            self.appScopeID = appScopeID
            self.capabilities = capabilities
        }
    }

    private var handleByHostSessionID: [UUID: String] = [:]
    private var entriesByHandle: [String: Entry] = [:]
    private let makeHandle: () -> String

    public init(makeHandle: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.makeHandle = makeHandle
    }

    @discardableResult
    public func upsert(
        hostSessionID: UUID,
        tileID: TileID?,
        surfaceKind: AutomationSurfaceKind,
        windowScopeID: String,
        appScopeID: String,
        capabilities: [AutomationCapability] = AutomationAPI.v1Capabilities
    ) -> Entry {
        let handle = handleByHostSessionID[hostSessionID] ?? makeUniqueHandle()
        handleByHostSessionID[hostSessionID] = handle

        let entry = Entry(
            handle: handle,
            hostSessionID: hostSessionID,
            tileID: tileID,
            surfaceKind: surfaceKind,
            windowScopeID: windowScopeID,
            appScopeID: appScopeID,
            capabilities: capabilities
        )
        entriesByHandle[handle] = entry
        return entry
    }

    public func resolve(_ handle: String) -> Entry? {
        entriesByHandle[handle]
    }

    public func handle(for hostSessionID: UUID) -> String? {
        handleByHostSessionID[hostSessionID]
    }

    public func remove(hostSessionID: UUID) {
        guard let handle = handleByHostSessionID.removeValue(forKey: hostSessionID) else { return }
        entriesByHandle.removeValue(forKey: handle)
    }

    public func removeAll() {
        handleByHostSessionID.removeAll()
        entriesByHandle.removeAll()
    }

    private func makeUniqueHandle() -> String {
        var handle = makeHandle()
        while entriesByHandle[handle] != nil {
            handle = makeHandle()
        }
        return handle
    }
}

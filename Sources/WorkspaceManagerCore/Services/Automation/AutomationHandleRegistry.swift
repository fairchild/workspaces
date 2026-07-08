import Foundation

@MainActor
public final class AutomationHandleRegistry {
    /// The synthetic window scope carried by operator entries. Operator scope is not window-bound
    /// (it lists every app window), so this is a marker, not a live SwiftUI window identity.
    public static let operatorWindowScopeID = "operator"

    public struct Entry: Sendable, Equatable {
        public let handle: String
        public let hostSessionID: UUID
        public let tileID: TileID?
        public let surfaceKind: AutomationSurfaceKind
        public let windowScopeID: String
        public let appScopeID: String
        public let capabilities: [AutomationCapability]
        /// True for an opt-in operator handle (trusted caller outside any tile). Operator entries do
        /// not resolve to a terminal tile, so callers must skip tile-liveness checks for them.
        public let isOperator: Bool

        public init(
            handle: String,
            hostSessionID: UUID,
            tileID: TileID?,
            surfaceKind: AutomationSurfaceKind,
            windowScopeID: String,
            appScopeID: String,
            capabilities: [AutomationCapability] = AutomationAPI.v1Capabilities,
            isOperator: Bool = false
        ) {
            self.handle = handle
            self.hostSessionID = hostSessionID
            self.tileID = tileID
            self.surfaceKind = surfaceKind
            self.windowScopeID = windowScopeID
            self.appScopeID = appScopeID
            self.capabilities = capabilities
            self.isOperator = isOperator
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

    /// Registers a per-launch operator handle carrying capture-only capabilities. Unlike `upsert`,
    /// this is not keyed by a live terminal session — the entry stands alone under a synthetic host
    /// session id so `remove(hostSessionID:)`/`removeAll` still evict it when the launch ends. Each
    /// call mints a fresh handle; a launch mints exactly one.
    @discardableResult
    public func registerOperator(
        appScopeID: String,
        capabilities: [AutomationCapability] = AutomationAPI.operatorCapabilities,
        hostSessionID: UUID = UUID()
    ) -> Entry {
        let handle = makeUniqueHandle()
        handleByHostSessionID[hostSessionID] = handle
        let entry = Entry(
            handle: handle,
            hostSessionID: hostSessionID,
            tileID: nil,
            surfaceKind: .terminal,
            windowScopeID: Self.operatorWindowScopeID,
            appScopeID: appScopeID,
            capabilities: capabilities,
            isOperator: true
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

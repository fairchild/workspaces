//
//  KnownSessionStore.swift
//  WorkspaceManagerCore
//
//  Sidecar persistence for Channel 4 cold-start state recovery.
//
//  When the hook listener sees a `SessionStart` (or any subsequent event with
//  `transcript_path`), it records the binding here. On the next launch — when
//  the previous run's hook listener is no longer reachable — `ColdStartRunner`
//  reads the sidecar and replays each transcript's tail through
//  `AgentSessionRegistry.ingestBatch` to rebuild state.
//
//  The store is intentionally a flat JSON file under Application Support; not
//  SwiftData. The schema is small, additive, and read-once on launch. Writes
//  are debounced through a serial actor so the hook hot-path stays cheap.
//

import Foundation

public struct KnownSession: Codable, Equatable, Sendable {
    public let hostSessionID: UUID
    public let agentSessionID: String?
    public let cwd: String
    public let transcriptPath: String
    public let kindRaw: String
    public let lastSeenAt: Date

    public init(
        hostSessionID: UUID,
        agentSessionID: String?,
        cwd: String,
        transcriptPath: String,
        kindRaw: String,
        lastSeenAt: Date
    ) {
        self.hostSessionID = hostSessionID
        self.agentSessionID = agentSessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.kindRaw = kindRaw
        self.lastSeenAt = lastSeenAt
    }

    public var kind: AgentKind {
        AgentKind(rawValue: kindRaw) ?? .unknown
    }
}

public actor KnownSessionStore {
    private let url: URL
    private var cache: [UUID: KnownSession] = [:]
    private var loaded = false

    public init(storageURL: URL) {
        self.url = storageURL
    }

    /// Default location: `~/Library/Application Support/<bundle-id>/known-sessions.json`.
    public static func defaultURL(bundleID: String) -> URL {
        let support =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return
            support
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("known-sessions.json")
    }

    public func record(_ session: KnownSession) async {
        await ensureLoaded()
        cache[session.hostSessionID] = session
        await persist()
    }

    public func remove(hostSessionID: UUID) async {
        await ensureLoaded()
        if cache.removeValue(forKey: hostSessionID) != nil {
            await persist()
        }
    }

    public func all() async -> [KnownSession] {
        await ensureLoaded()
        return Array(cache.values)
    }

    public func clear() async {
        cache.removeAll()
        try? FileManager.default.removeItem(at: url)
        loaded = true
    }

    // MARK: - Internal

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            cache = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([KnownSession].self, from: data) else {
            cache = [:]
            return
        }
        cache = Dictionary(uniqueKeysWithValues: decoded.map { ($0.hostSessionID, $0) })
    }

    private func persist() async {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Array(cache.values)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Cold-start launcher: reads `KnownSessionStore`, registers each known session
/// with the live registry (so cwd/kind survive replay), then drives transcript
/// replay through `TranscriptColdStartRecovery` with the perf-audit-mandated
/// 500 ev/s throttle.
public struct ColdStartRunner: Sendable {
    private let store: KnownSessionStore
    private let registry: any AgentSessionRegistryProtocol
    private let configuration: TranscriptColdStartRecovery.Configuration

    public init(
        store: KnownSessionStore,
        registry: any AgentSessionRegistryProtocol,
        configuration: TranscriptColdStartRecovery.Configuration = .default
    ) {
        self.store = store
        self.registry = registry
        self.configuration = configuration
    }

    @discardableResult
    public func run() async -> [TranscriptColdStartRecovery.Outcome] {
        let known = await store.all()
        var outcomes: [TranscriptColdStartRecovery.Outcome] = []
        for session in known {
            let path = URL(fileURLWithPath: session.transcriptPath)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }

            await MainActor.run { [registry] in
                registry.register(
                    hostSessionID: session.hostSessionID,
                    cwd: session.cwd,
                    kind: session.kind
                )
            }

            let recovery = TranscriptColdStartRecovery(
                registry: registry,
                configuration: configuration
            )
            let outcome = await recovery.replay(
                transcriptPath: path,
                for: session.hostSessionID,
                agentSessionID: session.agentSessionID,
                kind: session.kind
            )
            outcomes.append(outcome)
        }
        return outcomes
    }
}

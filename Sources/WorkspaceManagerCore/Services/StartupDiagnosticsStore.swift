//
//  StartupDiagnosticsStore.swift
//  WorkspaceManager
//
//  In-memory accumulator for startup diagnostic events. Events are recorded
//  during launch and provider-availability checks, then exported on demand
//  as a self-contained JSON bundle. Optional local-state persistence is
//  fire-and-forget so no disk I/O happens on the hot path.
//

import Foundation

public actor StartupDiagnosticsStore {
    public static let shared = StartupDiagnosticsStore()

    public struct DiagnosticEvent: Codable, Sendable, Equatable {
        public let timestamp: Date
        public let metric: String
        public let durationMs: Double
        public let labels: [String: String]

        public init(timestamp: Date, metric: String, durationMs: Double, labels: [String: String]) {
            self.timestamp = timestamp
            self.metric = metric
            self.durationMs = durationMs
            self.labels = labels
        }
    }

    public struct DiagnosticsBundle: Codable, Sendable, Equatable {
        public let schemaVersion: Int
        public let appVersion: String
        public let buildNumber: String
        public let osVersion: String
        public let architecture: String
        public let capturedAt: Date
        public let events: [DiagnosticEvent]

        public init(
            schemaVersion: Int = 1,
            appVersion: String,
            buildNumber: String,
            osVersion: String,
            architecture: String,
            capturedAt: Date,
            events: [DiagnosticEvent]
        ) {
            self.schemaVersion = schemaVersion
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.osVersion = osVersion
            self.architecture = architecture
            self.capturedAt = capturedAt
            self.events = events
        }
    }

    private var events: [DiagnosticEvent] = []
    private let maxEvents: Int
    private var localStateStore: LocalStateStore?
    private var persistedEventCount = 0

    public init(maxEvents: Int = 200) {
        self.maxEvents = maxEvents
    }

    public func attach(localStateStore: LocalStateStore?) {
        self.localStateStore = localStateStore
        guard let localStateStore else {
            persistedEventCount = 0
            return
        }

        let firstUnpersistedIndex = min(persistedEventCount, events.count)
        let pendingEvents = Array(events.dropFirst(firstUnpersistedIndex))
        persistedEventCount = events.count
        Self.enqueuePersistence(of: pendingEvents, to: localStateStore)
    }

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > maxEvents {
            let overflow = events.count - maxEvents
            events.removeFirst(overflow)
            persistedEventCount = max(0, persistedEventCount - overflow)
        }

        if let localStateStore {
            persistedEventCount = events.count
            Self.enqueuePersistence(of: [event], to: localStateStore)
        }
    }

    public func record(
        metric: String,
        durationMs: Double,
        labels: [String: String] = [:]
    ) {
        record(
            DiagnosticEvent(
                timestamp: Date(),
                metric: metric,
                durationMs: durationMs,
                labels: labels
            )
        )
    }

    public var eventCount: Int {
        events.count
    }

    public func allEvents() -> [DiagnosticEvent] {
        events
    }

    public func export(
        appVersion: String? = nil,
        buildNumber: String? = nil
    ) -> DiagnosticsBundle {
        let resolvedAppVersion =
            appVersion
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "unknown"
        let resolvedBuildNumber =
            buildNumber
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "unknown"

        return DiagnosticsBundle(
            appVersion: resolvedAppVersion,
            buildNumber: resolvedBuildNumber,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture(),
            capturedAt: Date(),
            events: events
        )
    }

    public func clear() {
        events.removeAll()
        persistedEventCount = 0
    }

    private func currentArchitecture() -> String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func enqueuePersistence(
        of events: [DiagnosticEvent],
        to localStateStore: LocalStateStore
    ) {
        guard !events.isEmpty else { return }
        Task {
            for event in events {
                try? await localStateStore.recordDiagnosticEvent(
                    metric: event.metric,
                    durationMs: event.durationMs,
                    labels: event.labels,
                    occurredAt: event.timestamp
                )
            }
        }
    }
}

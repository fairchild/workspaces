import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("StartupDiagnosticsStore")
struct StartupDiagnosticsStoreTests {

    @Test("Records events and returns them in order")
    func recordEventsInOrder() async {
        let store = StartupDiagnosticsStore()

        await store.record(
            metric: "launch_to_first_prompt",
            durationMs: 120.5,
            labels: ["trigger": "terminal_focus"]
        )
        await store.record(
            metric: "repo_hydration",
            durationMs: 340.2,
            labels: ["discovered": "12", "imported": "3"]
        )

        let events = await store.allEvents()
        #expect(events.count == 2)
        #expect(events[0].metric == "launch_to_first_prompt")
        #expect(events[0].durationMs == 120.5)
        #expect(events[0].labels["trigger"] == "terminal_focus")
        #expect(events[1].metric == "repo_hydration")
        #expect(events[1].durationMs == 340.2)
    }

    @Test("Ring buffer caps at maxEvents")
    func ringBufferCaps() async {
        let store = StartupDiagnosticsStore(maxEvents: 5)

        for i in 0..<8 {
            await store.record(
                metric: "event_\(i)",
                durationMs: Double(i),
                labels: [:]
            )
        }

        let events = await store.allEvents()
        #expect(events.count == 5)
        #expect(events[0].metric == "event_3")
        #expect(events[4].metric == "event_7")
    }

    @Test("Event count reflects current buffer size")
    func eventCountReflectsBufferSize() async {
        let store = StartupDiagnosticsStore(maxEvents: 3)

        #expect(await store.eventCount == 0)

        await store.record(metric: "a", durationMs: 1, labels: [:])
        #expect(await store.eventCount == 1)

        await store.record(metric: "b", durationMs: 2, labels: [:])
        await store.record(metric: "c", durationMs: 3, labels: [:])
        await store.record(metric: "d", durationMs: 4, labels: [:])
        #expect(await store.eventCount == 3)
    }

    @Test("Clear removes all events")
    func clearRemovesAllEvents() async {
        let store = StartupDiagnosticsStore()

        await store.record(metric: "x", durationMs: 1, labels: [:])
        await store.record(metric: "y", durationMs: 2, labels: [:])
        await store.clear()

        #expect(await store.eventCount == 0)
        #expect(await store.allEvents().isEmpty)
    }

    @Test("Attached local state store receives existing and future events")
    func attachedLocalStateStorePersistsDiagnostics() async throws {
        let fixture = try StartupDiagnosticsTemporaryDirectory()
        defer { fixture.cleanup() }
        let localStateStore = try LocalStateStore(
            databaseURL: fixture.url.appendingPathComponent("state.sqlite", isDirectory: false)
        )
        let store = StartupDiagnosticsStore()

        await store.record(
            metric: "before_attach",
            durationMs: 1,
            labels: ["phase": "bootstrap"]
        )
        await store.attach(localStateStore: localStateStore)
        try await waitForDiagnosticEventCount(1, in: localStateStore)

        await store.record(
            metric: "after_attach",
            durationMs: 2,
            labels: ["phase": "runtime"]
        )
        try await waitForDiagnosticEventCount(2, in: localStateStore)
    }

    @Test("Export produces a valid bundle with metadata")
    func exportProducesValidBundle() async {
        let store = StartupDiagnosticsStore()

        await store.record(
            metric: "test_metric",
            durationMs: 99.9,
            labels: ["key": "value"]
        )

        let bundle = await store.export(appVersion: "1.2.3", buildNumber: "42")

        #expect(bundle.schemaVersion == 1)
        #expect(bundle.appVersion == "1.2.3")
        #expect(bundle.buildNumber == "42")
        #expect(!bundle.osVersion.isEmpty)
        #expect(!bundle.architecture.isEmpty)
        #expect(bundle.events.count == 1)
        #expect(bundle.events[0].metric == "test_metric")
    }

    @Test("DiagnosticEvent Codable roundtrip preserves all fields")
    func diagnosticEventCodableRoundtrip() throws {
        let event = StartupDiagnosticsStore.DiagnosticEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000),
            metric: "launch_to_first_prompt",
            durationMs: 523.45,
            labels: ["trigger": "terminal_focus", "outcome": "success"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StartupDiagnosticsStore.DiagnosticEvent.self, from: data)

        #expect(decoded.metric == event.metric)
        #expect(decoded.durationMs == event.durationMs)
        #expect(decoded.labels == event.labels)
    }

    @Test("DiagnosticsBundle Codable roundtrip preserves all fields")
    func diagnosticsBundleCodableRoundtrip() throws {
        let event = StartupDiagnosticsStore.DiagnosticEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000),
            metric: "repo_hydration",
            durationMs: 210.0,
            labels: ["discovered": "5", "imported": "2"]
        )

        let bundle = StartupDiagnosticsStore.DiagnosticsBundle(
            appVersion: "2.0.0",
            buildNumber: "100",
            osVersion: "macOS 15.3",
            architecture: "arm64",
            capturedAt: Date(timeIntervalSinceReferenceDate: 700_000_001),
            events: [event]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StartupDiagnosticsStore.DiagnosticsBundle.self, from: data)

        #expect(decoded.schemaVersion == bundle.schemaVersion)
        #expect(decoded.appVersion == bundle.appVersion)
        #expect(decoded.buildNumber == bundle.buildNumber)
        #expect(decoded.osVersion == bundle.osVersion)
        #expect(decoded.architecture == bundle.architecture)
        #expect(decoded.events.count == 1)
        #expect(decoded.events[0].metric == "repo_hydration")
        #expect(decoded.events[0].durationMs == 210.0)
        #expect(decoded.events[0].labels == ["discovered": "5", "imported": "2"])
    }

    @Test("Export with empty events produces valid JSON")
    func exportWithEmptyEventsProducesValidJSON() async throws {
        let store = StartupDiagnosticsStore()
        let bundle = await store.export(appVersion: "1.0.0", buildNumber: "1")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(StartupDiagnosticsStore.DiagnosticsBundle.self, from: data)

        #expect(decoded.events.isEmpty)
        #expect(decoded.appVersion == "1.0.0")
    }

    private func waitForDiagnosticEventCount(
        _ expectedCount: Int,
        in localStateStore: LocalStateStore
    ) async throws {
        var latestCount = 0
        for _ in 0..<20 {
            let summary = try await localStateStore.summary()
            latestCount = summary.tableCounts["diagnostic_events"] ?? 0
            if latestCount == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(latestCount == expectedCount)
    }
}

private struct StartupDiagnosticsTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "StartupDiagnosticsStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

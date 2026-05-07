//
//  TranscriptColdStartRecovery.swift
//  WorkspaceManagerCore
//
//  Cold-start state recovery: when the app launches and a previously-known host
//  session has no live hook stream, replay the tail of its transcript through
//  `AgentSessionRegistry.ingestBatch(_:for:origin:)` to rebuild state.
//
//  Two non-negotiable rules from the perf audit (`perf-audit-pr443-final.md`):
//
//    1. Replay rate cap ≤500 events/sec. Naive per-record `@Published` mutation
//       at full transcript-read speed will reproduce the allocator-pressure
//       pattern observed in the 10-min long-session run.
//
//    2. Batched publisher writes. Every flush calls `ingestBatch` so SwiftUI
//       sees one mutation per flush.
//
//  Implementation: token bucket. We accumulate up to `flushSize` events, then
//  hand them to the registry in one `ingestBatch` call. The throttle sleeps
//  the minimum amount needed to stay at or below `eventsPerSecond`.
//

import Foundation

public actor TranscriptColdStartRecovery {
    public struct Configuration: Sendable {
        public let eventsPerSecond: Int
        public let flushSize: Int
        public let flushIntervalMS: Int

        public init(
            eventsPerSecond: Int = 500,
            flushSize: Int = 64,
            flushIntervalMS: Int = 16
        ) {
            self.eventsPerSecond = eventsPerSecond
            self.flushSize = flushSize
            self.flushIntervalMS = flushIntervalMS
        }

        public static let `default` = Configuration()
    }

    public struct Outcome: Sendable, Equatable {
        public let recordsProcessed: Int
        public let eventsEmitted: Int
        public let durationSeconds: Double

        public init(recordsProcessed: Int, eventsEmitted: Int, durationSeconds: Double) {
            self.recordsProcessed = recordsProcessed
            self.eventsEmitted = eventsEmitted
            self.durationSeconds = durationSeconds
        }
    }

    private let registry: any AgentSessionRegistryProtocol
    private let configuration: Configuration

    public init(
        registry: any AgentSessionRegistryProtocol,
        configuration: Configuration = .default
    ) {
        self.registry = registry
        self.configuration = configuration
    }

    /// Replay `transcriptPath` into the registry under `hostSessionID`. The host
    /// session must already be registered (callers register it before invoking
    /// recovery so cwd / kind survive the replay's `sessionStart` event).
    @discardableResult
    public func replay(
        transcriptPath: URL,
        for hostSessionID: UUID,
        agentSessionID: String?,
        kind: AgentKind = .claudeCode
    ) async -> Outcome {
        let started = Date()
        var batch: [AgentEvent] = []
        batch.reserveCapacity(configuration.flushSize)

        var recordsProcessed = 0
        var eventsEmitted = 0

        // Token bucket: `eventsPerSecond` capacity refilled at the same rate.
        let bucketCapacity = Double(configuration.eventsPerSecond)
        var tokens = bucketCapacity
        var lastRefill = Date()

        let reader = TranscriptReader(transcriptPath: transcriptPath)

        for await record in reader.tail() {
            recordsProcessed += 1
            guard
                let event = TranscriptEventMapper.mapToAgentEvent(
                    record,
                    agentSessionID: agentSessionID,
                    kind: kind
                )
            else { continue }

            batch.append(event)
            eventsEmitted += 1

            if batch.count >= configuration.flushSize {
                await flush(&batch, hostSessionID: hostSessionID)
                await throttle(
                    tokensConsumed: Double(configuration.flushSize),
                    bucketCapacity: bucketCapacity,
                    tokens: &tokens,
                    lastRefill: &lastRefill
                )
            }
        }

        if !batch.isEmpty {
            await flush(&batch, hostSessionID: hostSessionID)
        }

        return Outcome(
            recordsProcessed: recordsProcessed,
            eventsEmitted: eventsEmitted,
            durationSeconds: Date().timeIntervalSince(started)
        )
    }

    private func flush(_ batch: inout [AgentEvent], hostSessionID: UUID) async {
        let events = batch
        batch.removeAll(keepingCapacity: true)
        await MainActor.run { [registry] in
            registry.ingestBatch(events: events, for: hostSessionID, origin: .transcript)
        }
    }

    /// Token-bucket throttle. Refills tokens based on elapsed wall time, then
    /// sleeps long enough to consume the requested amount without exceeding the
    /// configured rate.
    private func throttle(
        tokensConsumed: Double,
        bucketCapacity: Double,
        tokens: inout Double,
        lastRefill: inout Date
    ) async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        tokens = min(bucketCapacity, tokens + elapsed * bucketCapacity)
        lastRefill = now

        tokens -= tokensConsumed
        if tokens < 0 {
            let deficit = -tokens
            let sleepSeconds = deficit / bucketCapacity
            tokens = 0
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            lastRefill = Date()
        }
    }
}

/// Maps transcript records to the registry's `AgentEvent`. Only canonical types
/// translate; opaque records emit no event (they still render in the UI).
public enum TranscriptEventMapper {
    public static func mapToAgentEvent(
        _ record: TranscriptRecord,
        agentSessionID: String?,
        kind: AgentKind
    ) -> AgentEvent? {
        switch record {
        case .user(let u):
            return .userPrompt(prompt: u.text.isEmpty ? nil : u.text)

        case .assistant(let a):
            // Assistant messages move the registry from `.thinking` to `.idle`/
            // `.complete` only when the conversation actually settles — Channel 4
            // is replay-only, so we treat each assistant turn as a `.thinking`
            // tick which is harmless: a final `Stop` (if any) overrides it.
            var fields = AgentEvent.StatusFields()
            fields.modelDisplayName = a.model
            return .statusFields(fields)

        case .toolUse(let t):
            return .toolStart(name: t.toolName, detail: t.inputSummary)

        case .toolResult(let r):
            if r.isError {
                return .toolFailed(name: r.toolName ?? "tool", error: r.outputSummary)
            }
            return .toolEnd(name: r.toolName ?? "tool", durationMS: r.durationMS)

        case .summary:
            return nil

        case .opaque:
            return nil
        }
    }
}

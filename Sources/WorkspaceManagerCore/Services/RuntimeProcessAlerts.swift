//
//  RuntimeProcessAlerts.swift
//  WorkspaceManagerCore
//
//  Turns a run of process samples into the two statements worth interrupting
//  someone for: this process is enormous, and this process is still growing
//  (#1368). Both readings come from physical footprint, so they agree with
//  Activity Monitor and with the kernel limits that eventually kill the machine.
//

import Foundation

/// The thresholds a process has to cross before it is worth naming.
///
/// The defaults are set against the 2026-08-23 runaways this detector exists
/// for. The `codex` process that walked 2.7 GB → 7.5 GB over 30 hours averaged
/// about 160 MB/h, so the rate threshold sits below that at 128 MB/h — a
/// threshold above the leak it was written for would be decoration. The floor
/// and the observation span are what keep 128 MB/h from being noisy: a process
/// has to already hold a gigabyte and hold the rate for ten minutes.
public struct RuntimeProcessAlertPolicy: Equatable, Sendable {
    /// Footprint above which a process is called out on a single sample.
    public var footprintCeilingBytes: Int64
    /// Sustained growth above which a process is called out.
    public var growthBytesPerHour: Int64
    /// Footprint a process must already hold before its growth is judged, so a
    /// small process doubling from nothing stays quiet.
    public var growthFloorBytes: Int64
    /// Readings a process needs before a slope is fitted to it.
    public var minimumSampleCount: Int
    /// Wall time those readings must span. Without it a 30-second window
    /// extrapolates a normal allocation burst into an alarming hourly rate.
    public var minimumObservationSpan: TimeInterval
    /// How far back readings are kept and fitted.
    public var observationWindow: TimeInterval

    public init(
        footprintCeilingBytes: Int64 = 6 * 1_024 * 1_024 * 1_024,
        growthBytesPerHour: Int64 = 128 * 1_024 * 1_024,
        growthFloorBytes: Int64 = 1_024 * 1_024 * 1_024,
        minimumSampleCount: Int = 5,
        minimumObservationSpan: TimeInterval = 600,
        observationWindow: TimeInterval = 3_600
    ) {
        self.footprintCeilingBytes = footprintCeilingBytes
        self.growthBytesPerHour = growthBytesPerHour
        self.growthFloorBytes = growthFloorBytes
        self.minimumSampleCount = minimumSampleCount
        self.minimumObservationSpan = minimumObservationSpan
        self.observationWindow = observationWindow
    }

    public static let `default` = RuntimeProcessAlertPolicy()
}

/// One process the sampler wants the user to know about.
public struct RuntimeProcessAlert: Equatable, Identifiable, Sendable {
    public enum Trigger: String, Equatable, Sendable {
        /// Above the ceiling right now.
        case footprintCeiling
        /// Below the ceiling, but climbing fast enough to reach it.
        case growthRate
    }

    public var id: Int32 { pid }

    public let pid: Int32
    /// The process's recorded start time, paired with the pid so a signal cannot
    /// land on a recycled one.
    public let startedAt: Date?
    public let name: String
    public let trigger: Trigger
    public let footprintBytes: Int64
    /// Fitted slope over the observation window. Meaningful for either trigger;
    /// a ceiling alert on its first sample reports zero.
    public let growthBytesPerHour: Int64
    public let sampleCount: Int
    public let observedSince: Date
    /// True when the process is inside the app's own tree, which is what makes
    /// stopping it the app's business rather than a suggestion about the Mac.
    public let isAppDescendant: Bool

    public var identity: RuntimeProcessIdentity {
        RuntimeProcessIdentity(pid: pid, startedAt: startedAt)
    }

    public init(
        pid: Int32,
        startedAt: Date? = nil,
        name: String,
        trigger: Trigger,
        footprintBytes: Int64,
        growthBytesPerHour: Int64,
        sampleCount: Int,
        observedSince: Date,
        isAppDescendant: Bool
    ) {
        self.pid = pid
        self.startedAt = startedAt
        self.name = name
        self.trigger = trigger
        self.footprintBytes = footprintBytes
        self.growthBytesPerHour = growthBytesPerHour
        self.sampleCount = sampleCount
        self.observedSince = observedSince
        self.isAppDescendant = isAppDescendant
    }
}

/// A compact per-process footprint series over the alert window.
///
/// It exists rather than reading the sampler's snapshot history because that
/// history holds every process on the host: keeping an hour of it at a 30 s
/// cadence to answer a question about a dozen processes would cost tens of
/// megabytes, in a feature whose whole subject is memory honesty.
public struct RuntimeProcessGrowthLedger: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        let sampledAt: Date
        let footprintBytes: Int64
    }

    struct Series: Equatable, Sendable {
        var name: String
        var startedAt: Date?
        var isAppDescendant: Bool
        var readings: [Reading]
    }

    private(set) var series: [Int32: Series] = [:]

    public init() {}

    /// Records this sample's candidates and forgets anything outside the window
    /// or no longer running. A pid that leaves the candidate set is dropped
    /// outright, so a recycled pid never inherits a stranger's slope.
    public mutating func record(
        candidates: [RuntimeProcessSample],
        appDescendantPIDs: Set<Int32>,
        at sampledAt: Date,
        policy: RuntimeProcessAlertPolicy = .default
    ) {
        let cutoff = sampledAt.addingTimeInterval(-policy.observationWindow)
        var next: [Int32: Series] = [:]
        next.reserveCapacity(candidates.count)

        for candidate in candidates {
            let reading = Reading(
                sampledAt: sampledAt,
                footprintBytes: candidate.residentMemoryBytes
            )
            var existing =
                series[candidate.pid]
                ?? Series(
                    name: candidate.name,
                    startedAt: candidate.startedAt,
                    isAppDescendant: false,
                    readings: []
                )
            // A pid the kernel handed to a new process starts a new series. Left
            // alone it would inherit its predecessor's slope and alert about
            // growth that never happened.
            if existing.startedAt != candidate.startedAt {
                existing = Series(
                    name: candidate.name,
                    startedAt: candidate.startedAt,
                    isAppDescendant: false,
                    readings: []
                )
            }
            existing.name = candidate.name
            existing.isAppDescendant = appDescendantPIDs.contains(candidate.pid)
            existing.readings.removeAll { $0.sampledAt < cutoff }
            existing.readings.append(reading)
            next[candidate.pid] = existing
        }

        series = next
    }

    /// The processes currently over a threshold, worst footprint first.
    public func alerts(
        policy: RuntimeProcessAlertPolicy = .default,
        muted: Set<RuntimeProcessIdentity> = []
    ) -> [RuntimeProcessAlert] {
        series.compactMap { pid, series -> RuntimeProcessAlert? in
            let identity = RuntimeProcessIdentity(pid: pid, startedAt: series.startedAt)
            guard !muted.contains(identity) else { return nil }
            guard let latest = series.readings.last, let first = series.readings.first else {
                return nil
            }

            let slope = Self.growthBytesPerHour(series.readings, policy: policy)

            let trigger: RuntimeProcessAlert.Trigger
            if latest.footprintBytes >= policy.footprintCeilingBytes {
                trigger = .footprintCeiling
            } else if latest.footprintBytes >= policy.growthFloorBytes,
                let slope, slope >= policy.growthBytesPerHour
            {
                trigger = .growthRate
            } else {
                return nil
            }

            return RuntimeProcessAlert(
                pid: pid,
                startedAt: series.startedAt,
                name: series.name,
                trigger: trigger,
                footprintBytes: latest.footprintBytes,
                growthBytesPerHour: slope ?? 0,
                sampleCount: series.readings.count,
                observedSince: first.sampledAt,
                isAppDescendant: series.isAppDescendant
            )
        }
        .sorted { lhs, rhs in
            if lhs.footprintBytes != rhs.footprintBytes {
                return lhs.footprintBytes > rhs.footprintBytes
            }
            return lhs.pid < rhs.pid
        }
    }

    /// Least-squares slope through the readings, in bytes per hour.
    ///
    /// A fit rather than last-minus-first: a process that allocates and frees in
    /// bursts would otherwise alert or stay silent on the accident of where the
    /// window's ends landed. Returns nil until the run is long enough and wide
    /// enough to mean anything.
    static func growthBytesPerHour(
        _ readings: [Reading],
        policy: RuntimeProcessAlertPolicy
    ) -> Int64? {
        guard readings.count >= policy.minimumSampleCount,
            let first = readings.first,
            let last = readings.last
        else { return nil }

        let span = last.sampledAt.timeIntervalSince(first.sampledAt)
        guard span >= policy.minimumObservationSpan else { return nil }

        let points = readings.map {
            (x: $0.sampledAt.timeIntervalSince(first.sampledAt), y: Double($0.footprintBytes))
        }
        let count = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / count
        let meanY = points.reduce(0) { $0 + $1.y } / count
        let covariance = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) }
        let variance = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard variance > 0 else { return nil }

        let bytesPerSecond = covariance / variance
        let bytesPerHour = (bytesPerSecond * 3_600).rounded()
        guard bytesPerHour.isFinite else { return nil }
        // A finite Double outside Int64's range traps on conversion, and a
        // degenerate fit can produce one.
        guard bytesPerHour >= Double(Int64.min), bytesPerHour <= Double(Int64.max) else {
            return bytesPerHour > 0 ? Int64.max : Int64.min
        }
        return Int64(bytesPerHour)
    }
}

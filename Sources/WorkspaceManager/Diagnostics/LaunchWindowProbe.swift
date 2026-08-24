//
//  LaunchWindowProbe.swift
//  WorkspaceManager
//
//  Splits the first-surface surface_create→first_output window (#1251) into segments
//  observable from the app side: when the child shell is actually spawned (libproc
//  polling), when libghostty wakes the app to deliver work, and how long each
//  wakeup→tick MainActor hop waits — the hop every title/pwd delivery rides.
//  Active only while the launch_to_first_prompt interval is open, and only when
//  WORKSPACES_TERMINAL_DIAGNOSTICS=1 (the perf lane sets it; normal launches emit nothing).
//

import Darwin
import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "PerformanceSignposts")

enum LaunchWindowProbe {
    struct WakeupToken: Sendable {
        let seq: Int
        let at: ContinuousClock.Instant
    }

    private static let enabled =
        ProcessInfo.processInfo.environment["WORKSPACES_TERMINAL_DIAGNOSTICS"] == "1"
    private static let clock = ContinuousClock()
    private static let lock = NSLock()
    /// Wakeups fire ~every frame once output flows; the cap bounds log volume if a
    /// launch never reaches a prompt and the window stays open for the whole run.
    private static let maxWakeupEvents = 500
    private static let pollIntervalMicroseconds: UInt32 = 5_000
    private static let maxPollerLifetime: Duration = .seconds(15)

    nonisolated(unsafe) private static var origin: ContinuousClock.Instant?
    nonisolated(unsafe) private static var closed = false
    nonisolated(unsafe) private static var wakeupSeq = 0
    nonisolated(unsafe) private static var pollerStarted = false
    nonisolated(unsafe) private static var heartbeatTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var heartbeatSeq = 0
    private static let heartbeatInterval: DispatchTimeInterval = .milliseconds(25)
    private static let maxHeartbeats = 400

    /// Opens the observation window. Called when the launch_to_first_prompt interval
    /// begins, so every `t_ms` below shares that metric's zero.
    static func open() {
        guard enabled else { return }

        lock.lock()
        let shouldStartPoller: Bool
        if origin == nil, !closed {
            origin = clock.now
            shouldStartPoller = !pollerStarted
            pollerStarted = true
        } else {
            shouldStartPoller = false
        }
        lock.unlock()

        guard shouldStartPoller else { return }
        emit(phase: "open", fields: ["t_ms": "0.00"])
        startChildSpawnPoller()
        startMainQueueHeartbeat()
    }

    /// Closes the window: wakeup/tick logging stops, the spawn poller winds down.
    static func close(trigger: String) {
        guard enabled else { return }

        lock.lock()
        let originSnapshot = origin
        let alreadyClosed = closed
        closed = true
        let timer = heartbeatTimer
        heartbeatTimer = nil
        lock.unlock()

        timer?.cancel()
        guard let originSnapshot, !alreadyClosed else { return }
        emit(
            phase: "close",
            fields: [
                "t_ms": formattedMilliseconds(since: originSnapshot),
                "trigger": trigger,
            ]
        )
    }

    /// Called from libghostty's wakeup callback (any thread). Returns a token the
    /// scheduled main-thread tick hands back to `noteTickStart`, or nil when the
    /// window is not open — the tick then logs nothing.
    static func noteWakeup() -> WakeupToken? {
        guard enabled else { return nil }

        lock.lock()
        guard let originSnapshot = origin, !closed, wakeupSeq < maxWakeupEvents else {
            lock.unlock()
            return nil
        }
        wakeupSeq += 1
        let token = WakeupToken(seq: wakeupSeq, at: clock.now)
        lock.unlock()

        emit(
            phase: "wakeup",
            fields: [
                "seq": "\(token.seq)",
                "main_thread": Thread.isMainThread ? "true" : "false",
                "t_ms": formattedMilliseconds(from: originSnapshot, to: token.at),
            ]
        )
        return token
    }

    /// Called on the main thread when the tick a wakeup scheduled actually starts.
    /// `hop_ms` is the MainActor scheduling latency that wakeup's delivery waited.
    ///
    /// Ticks queued before the window closed are still reported after it, marked
    /// `after_close=true`: the first tick to run delivers the title that closes the
    /// interval, so its queued siblings land afterwards, and their hops are what show
    /// how long the main thread had actually been blocked. Dropping them would discard
    /// the measurement — the marker keeps the trace unambiguous instead.
    static func noteTickStart(token: WakeupToken?) {
        guard enabled, let token else { return }

        lock.lock()
        let originSnapshot = origin
        let isClosed = closed
        lock.unlock()
        guard let originSnapshot else { return }

        let now = clock.now
        var fields = [
            "seq": "\(token.seq)",
            "hop_ms": formattedMilliseconds(from: token.at, to: now),
            "t_ms": formattedMilliseconds(from: originSnapshot, to: now),
        ]
        if isClosed {
            fields["after_close"] = "true"
        }
        emit(phase: "tick", fields: fields)
    }

    /// Called when the runtime action callback receives a title/pwd action, before any
    /// hop to the main thread — with `first_output_observed` it brackets the delivery
    /// hop even if libghostty invokes the callback off the app tick.
    static func noteShellSignalAction(kind: String) {
        guard enabled else { return }

        lock.lock()
        let originSnapshot = origin
        let isClosed = closed
        lock.unlock()
        guard let originSnapshot, !isClosed else { return }

        emit(
            phase: "shell_signal_action",
            fields: [
                "kind": kind,
                "main_thread": Thread.isMainThread ? "true" : "false",
                "t_ms": formattedMilliseconds(since: originSnapshot),
            ]
        )
    }

    // MARK: - Main-queue heartbeat

    /// A 25 ms main-queue timer during the window. Steady beats while a wakeup→tick hop
    /// waits mean the main thread was servicing GCD but the actor job starved; a gap in
    /// beats means the main thread itself was busy or blocked for that stretch.
    private static func startMainQueueHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + heartbeatInterval, repeating: heartbeatInterval)
        timer.setEventHandler {
            lock.lock()
            let originSnapshot = origin
            let isClosed = closed
            heartbeatSeq += 1
            let seq = heartbeatSeq
            let isFinalBeat = isClosed || seq >= maxHeartbeats
            let timerToCancel = isFinalBeat ? heartbeatTimer : nil
            if timerToCancel != nil { heartbeatTimer = nil }
            lock.unlock()

            // `cancel()` from a non-main `close()` can still let one already-dequeued
            // handler run, so the window's end is decided by `closed` — not by whether
            // this handler was the one holding the timer. Nothing is emitted past the
            // `close` line either way.
            timerToCancel?.cancel()
            guard !isFinalBeat, let originSnapshot else { return }
            emit(
                phase: "main_heartbeat",
                fields: [
                    "seq": "\(seq)",
                    "t_ms": formattedMilliseconds(since: originSnapshot),
                ]
            )
        }
        lock.lock()
        heartbeatTimer = timer
        lock.unlock()
        timer.resume()
    }

    // MARK: - Child spawn poller

    /// Watches this process's direct children while the window is open, so the shell
    /// fork is timestamped from the process table rather than inferred from when its
    /// first output arrives. ~5 ms resolution; each iteration is one cheap syscall.
    private static func startChildSpawnPoller() {
        let thread = Thread {
            let started = clock.now
            var knownPids = Set<pid_t>()
            var firstIteration = true

            while true {
                lock.lock()
                let isClosed = closed
                let originSnapshot = origin
                lock.unlock()

                guard let originSnapshot, !isClosed,
                    started.duration(to: clock.now) < maxPollerLifetime
                else { return }

                // Enumeration and name lookup run outside the lock, so the window can close
                // mid-iteration. Unlike a queued tick — whose late arrival is itself the
                // measurement — a spawn seen after the first prompt says nothing about the
                // launch, so it is dropped rather than reported past the close line.
                let discovered = currentChildPids().filter { !knownPids.contains($0) }
                for pid in discovered {
                    knownPids.insert(pid)
                    lock.lock()
                    let stillOpen = !closed
                    lock.unlock()
                    guard stillOpen else { return }

                    emit(
                        phase: firstIteration ? "child_present" : "child_spawn",
                        fields: [
                            "pid": "\(pid)",
                            "name": processName(pid: pid),
                            "t_ms": formattedMilliseconds(since: originSnapshot),
                        ]
                    )
                }
                firstIteration = false
                usleep(pollIntervalMicroseconds)
            }
        }
        thread.name = "LaunchWindowProbe.childSpawnPoller"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func currentChildPids() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 128)
        let byteCount = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listpids(
                UInt32(PROC_PPID_ONLY),
                UInt32(getpid()),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard byteCount > 0 else { return [] }
        let count = Int(byteCount) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private static func processName(pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return "unknown" }
        let path = String(cString: pathBuffer)
        return (path as NSString).lastPathComponent
    }

    // MARK: - Emission

    private static func emit(phase: String, fields: [String: String]) {
        var components = ["[Perf]", "event=launch_probe", "phase=\(phase)"]
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            components.append("\(key)=\(value.replacingOccurrences(of: " ", with: "_"))")
        }
        log.info("\(components.joined(separator: " "), privacy: .public)")
    }

    private static func formattedMilliseconds(since start: ContinuousClock.Instant) -> String {
        formattedMilliseconds(from: start, to: clock.now)
    }

    private static func formattedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> String {
        let components = start.duration(to: end).components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.2f", milliseconds)
    }
}

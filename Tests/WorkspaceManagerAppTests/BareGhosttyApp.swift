//
//  BareGhosttyApp.swift
//  WorkspaceManagerAppTests
//
//  A libghostty app owned by a test, with its own runtime callbacks, so a test can hand
//  `ghostty_surface_new` a raw config (initial_input included) and count wakeups and ticks
//  without going through `GhosttyAppManager`. Its tick has the app's shape — one main-actor
//  task per wakeup — so the counts describe what the real app pays.
//

import AppKit
import Darwin
import Foundation
import GhosttyKit

@testable import WorkspaceManager

/// Wakeup and tick tallies, safe to update from libghostty's IO threads.
final class GhosttyWakeupLedger: @unchecked Sendable {
    struct Counts: Sendable, Equatable {
        var wakeups = 0
        var ticks = 0
        /// Wakeups that arrived while an earlier tick was enqueued and had not yet run:
        /// exactly the ones a "tick already scheduled" bit would have skipped.
        var coalescible = 0
    }

    private let lock = NSLock()
    private var counts = Counts()
    private var pending = 0
    private var appAddress: UInt?

    var snapshot: Counts { lock.withLock { counts } }

    func reset() { lock.withLock { counts = Counts() } }

    fileprivate func bind(app: ghostty_app_t) {
        lock.withLock { appAddress = UInt(bitPattern: app) }
    }

    fileprivate func unbind() {
        lock.withLock { appAddress = nil }
    }

    fileprivate func noteWakeup() -> UInt? {
        lock.withLock {
            counts.wakeups += 1
            if pending > 0 { counts.coalescible += 1 }
            pending += 1
            return appAddress
        }
    }

    fileprivate func noteTickStart() -> UInt? {
        lock.withLock {
            counts.ticks += 1
            pending -= 1
            return appAddress
        }
    }
}

struct BareSurfaceConfig {
    var command: String?
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var initialInput: String?
}

@MainActor
final class BareGhosttyApp {
    enum HarnessError: Error { case config, app, surface }

    let ledger = GhosttyWakeupLedger()
    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var surfaces: [ObjectIdentifier: (view: NSView, surface: ghostty_surface_t)] = [:]

    init() throws {
        Self.prepareProcess()

        guard let config = ghostty_config_new() else { throw HarnessError.config }
        ghostty_config_finalize(config)
        self.config = config

        var runtime = Self.runtimeConfig(ledger: ledger)
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            throw HarnessError.app
        }
        self.app = app
        ledger.bind(app: app)
    }

    /// `GhosttyAppManager` reads `NSApp`, which a test process has only once something has
    /// asked for the shared application; a filtered run may have nothing else that does.
    static func prepareProcess() {
        _ = NSApplication.shared
        GhosttyAppManager.shared.initializeIfNeeded()
    }

    /// Creates one surface. The returned view is the handle: pass it to `free(_:)`.
    func makeSurface(_ spec: BareSurfaceConfig) throws -> NSView {
        guard let app else { throw HarnessError.app }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = 2
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        let fields = [spec.command, spec.workingDirectory, spec.initialInput].map { $0.flatMap { strdup($0) } }
        let pairs = spec.environment.compactMap {
            key, value -> (UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)? in
            guard let key = strdup(key), let value = strdup(value) else { return nil }
            return (key, value)
        }
        defer {
            for pointer in fields + pairs.flatMap({ [Optional($0.0), Optional($0.1)] }) { Darwin.free(pointer) }
        }

        config.command = UnsafePointer(fields[0])
        config.working_directory = UnsafePointer(fields[1])
        config.initial_input = UnsafePointer(fields[2])
        var envVars = pairs.map { ghostty_env_var_s(key: UnsafePointer($0.0), value: UnsafePointer($0.1)) }

        let surface = envVars.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return ghostty_surface_new(app, &config)
        }
        guard let surface else { throw HarnessError.surface }
        surfaces[ObjectIdentifier(view)] = (view, surface)
        return view
    }

    func surface(for view: NSView) -> ghostty_surface_t? {
        surfaces[ObjectIdentifier(view)]?.surface
    }

    func hasProcessExited(_ view: NSView) -> Bool {
        surface(for: view).map { ghostty_surface_process_exited($0) } ?? true
    }

    /// Drains the app mailbox before the free, so the join inside `ghostty_surface_free`
    /// never waits on an IO thread blocked pushing into a full mailbox (#1856).
    func free(_ view: NSView) {
        guard let entry = surfaces.removeValue(forKey: ObjectIdentifier(view)) else { return }
        if let app { ghostty_app_tick(app) }
        ghostty_surface_free(entry.surface)
    }

    func shutdown() {
        for view in surfaces.values.map(\.view) { free(view) }
        ledger.unbind()
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
        app = nil
        config = nil
    }

    nonisolated private static func runtimeConfig(ledger: GhosttyWakeupLedger) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(ledger).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in BareGhosttyApp.wakeup(userdata) },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )
    }

    nonisolated private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let ledger = Unmanaged<GhosttyWakeupLedger>.fromOpaque(userdata).takeUnretainedValue()
        guard ledger.noteWakeup() != nil else { return }
        Task { @MainActor in
            guard let address = ledger.noteTickStart(),
                let app = UnsafeMutableRawPointer(bitPattern: address)
            else { return }
            ghostty_app_tick(app)
        }
    }
}

enum ProcessTree {
    /// Every live descendant of `root`, walked breadth-first through the process table.
    static func descendants(of root: pid_t = getpid()) -> Set<pid_t> {
        var found = Set<pid_t>()
        var frontier = [root]
        while let parent = frontier.popLast() {
            var pids = [pid_t](repeating: 0, count: 512)
            let bytes = pids.withUnsafeMutableBytes { buffer in
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), buffer.baseAddress, Int32(buffer.count))
            }
            guard bytes > 0 else { continue }
            for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 && found.insert(pid).inserted {
                frontier.append(pid)
            }
        }
        return found
    }

    static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return (String(cString: buffer) as NSString).lastPathComponent
    }

    /// True while the pid names a process, zombies included: an unreaped child still counts.
    static func exists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

extension BareGhosttyApp {
    /// Polls `condition` until it holds or `timeout` passes. The timeout bounds failure
    /// only; a passing wait returns the moment the state is observed.
    static func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }
}

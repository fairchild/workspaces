//
//  GhosttyAppManager.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit
import os
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "GhosttyAppManager")

@MainActor
final class GhosttyAppManager: NSObject {
    typealias SplitActionKind = GhosttyRuntimeActionBridge.SplitActionKind
    typealias SplitDirection = GhosttyRuntimeActionBridge.SplitDirection
    typealias SplitFocusDirection = GhosttyRuntimeActionBridge.SplitFocusDirection
    typealias SplitResizeDirection = GhosttyRuntimeActionBridge.SplitResizeDirection
    typealias SplitActionRequest = GhosttyRuntimeActionBridge.SplitActionRequest
    typealias TabActionKind = GhosttyRuntimeActionBridge.TabActionKind
    typealias TabCloseMode = GhosttyRuntimeActionBridge.TabCloseMode
    typealias TabGotoTarget = GhosttyRuntimeActionBridge.TabGotoTarget
    typealias TabActionRequest = GhosttyRuntimeActionBridge.TabActionRequest

    static let shared = GhosttyAppManager()
    nonisolated static let splitActionNotification = GhosttyRuntimeActionBridge.splitActionNotification
    nonisolated static let splitActionKindUserInfoKey = GhosttyRuntimeActionBridge.splitActionKindUserInfoKey
    nonisolated static let splitActionDirectionUserInfoKey =
        GhosttyRuntimeActionBridge.splitActionDirectionUserInfoKey
    nonisolated static let splitActionAmountUserInfoKey = GhosttyRuntimeActionBridge.splitActionAmountUserInfoKey
    nonisolated static let tabActionNotification = GhosttyRuntimeActionBridge.tabActionNotification
    nonisolated static let tabActionKindUserInfoKey = GhosttyRuntimeActionBridge.tabActionKindUserInfoKey
    nonisolated static let tabActionCloseModeUserInfoKey = GhosttyRuntimeActionBridge.tabActionCloseModeUserInfoKey
    nonisolated static let tabActionGotoUserInfoKey = GhosttyRuntimeActionBridge.tabActionGotoUserInfoKey
    nonisolated static let tabActionMoveAmountUserInfoKey = GhosttyRuntimeActionBridge.tabActionMoveAmountUserInfoKey
    nonisolated static let tabActionTitleUserInfoKey = GhosttyRuntimeActionBridge.tabActionTitleUserInfoKey

    private(set) var app: ghostty_app_t?

    /// Every wakeup so far. Ghostty wakes the app after each attempt to push into the app mailbox,
    /// and an attempt fails only when the mailbox is full, so 64 wakeups with no tick in between
    /// prove the 64-slot mailbox filled.
    nonisolated static let wakeupCount = OSAllocatedUnfairLock(initialState: 0)
    private(set) var tickCount = 0

    /// While true, nothing drains the app mailbox: wakeups skip their tick and retired surfaces
    /// wait. A test holds the mailbox full this way without blocking the main thread under every
    /// other suite, then lets the waiting frees run the way they always do, each after a tick.
    var mailboxDrainSuspended = false {
        didSet {
            guard oldValue, !mailboxDrainSuspended else { return }
            if retiredSurfaces.isEmpty {
                GhosttyThreadingBridge.enqueueOnMain { self.tick() }
            } else {
                drainRetiredSurfacesIfNeeded()
            }
        }
    }
    private var config: ghostty_config_t?
    private var initialized = false
    private var currentColorScheme: ghostty_color_scheme_e?

    /// Live surfaces, weakly held, so a Terminal Theme change can be broadcast
    /// to every open terminal via `ghostty_surface_update_config`. Weak objects
    /// drop automatically when a `GhosttySurfaceView` deallocates, so a stale
    /// entry can never be visited.
    private let surfaceViews = NSHashTable<GhosttySurfaceView>.weakObjects()

    /// Surfaces whose views are gone, waiting to be freed. `ghostty_surface_free` joins the
    /// surface's `io` thread, which may be blocked pushing into the app mailbox, and only
    /// `ghostty_app_tick` on this thread drains that mailbox: a free that starts behind a full
    /// mailbox never returns. So each free runs right after a tick, on a main-actor turn of its
    /// own rather than inside whatever released the view, where a tick's callbacks could
    /// re-enter that caller.
    ///
    /// The free must run on this thread, and the `io` thread it joins exits only once the
    /// surface's command has: it sends SIGHUP and sleeps in 10 ms steps until the command is
    /// gone. So retired surfaces' commands are hung up here instead, and each free waits,
    /// without holding this thread, until libghostty reports its command exited.
    private var retiredSurfaces: [RetiredSurface] = []
    private var drainingRetiredSurfaces = false
    var retiredSurfaceCount: Int { retiredSurfaces.count }

    /// How long a hung-up command gets to exit before its surface is freed anyway, and the
    /// free waits for the command on this thread as it would have without the hang-up.
    static let hangUpGrace: Duration = .seconds(5)

    /// Told how long each `ghostty_surface_free` held this thread.
    var onSurfaceFreed: ((ghostty_surface_t, Duration) -> Void)?

    private struct RetiredSurface {
        let surface: ghostty_surface_t
        let callbackTarget: Unmanaged<GhosttySurfaceCallbackTarget>
        var freeAnywayAt: ContinuousClock.Instant?

        var isReadyToFree: Bool {
            ghostty_surface_process_exited(surface) || freeAnywayAt.map { ContinuousClock.now >= $0 } ?? false
        }
    }

    private override init() {
        super.init()
    }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)

            if let app {
                ghostty_app_free(app)
            }
            if let config {
                ghostty_config_free(config)
            }
        }
    }

    func initializeIfNeeded() {
        guard !initialized else { return }

        if let resourcesDirectory = GhosttyResourcesLocator.configureProcessEnvironment() {
            log.info("[GhosttyAppManager] using Ghostty resources dir: \(resourcesDirectory.path, privacy: .public)")
        } else {
            log.error("[GhosttyAppManager] Ghostty resources dir unavailable")
        }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            log.error("[GhosttyAppManager] ghostty_init failed: \(initResult, privacy: .public)")
            return
        }

        guard let config = makeConfig(for: GhosttyThemePersistence.load()) else {
            log.error("[GhosttyAppManager] failed to build initial Ghostty config")
            return
        }
        self.config = config

        var runtimeConfig = GhosttyRuntimeConfigFactory.make(userdata: Unmanaged.passUnretained(self).toOpaque())

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            log.error("[GhosttyAppManager] ghostty_app_new failed")
            return
        }

        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardSelectionDidChange(_:)),
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )

        initialized = true
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func applyColorScheme(_ colorScheme: ghostty_color_scheme_e) {
        guard let app else { return }
        guard
            let colorSchemeToApply = GhosttyAppearanceSync.nextColorScheme(
                resolvedColorScheme: colorScheme,
                currentColorScheme: currentColorScheme
            )
        else {
            return
        }

        ghostty_app_set_color_scheme(app, colorSchemeToApply)
        currentColorScheme = colorSchemeToApply
    }

    // MARK: Surface registry

    func registerSurface(_ view: GhosttySurfaceView) {
        surfaceViews.add(view)
    }

    func unregisterSurface(_ view: GhosttySurfaceView) {
        surfaceViews.remove(view)
    }

    func retireSurface(_ surface: ghostty_surface_t, callbackTarget: Unmanaged<GhosttySurfaceCallbackTarget>) {
        GhosttySurfaceChildProcess.hangUp(surface)
        retiredSurfaces.append(RetiredSurface(surface: surface, callbackTarget: callbackTarget))
        drainRetiredSurfacesIfNeeded()
    }

    private func drainRetiredSurfacesIfNeeded() {
        guard !drainingRetiredSurfaces, !retiredSurfaces.isEmpty, !mailboxDrainSuspended else { return }
        drainingRetiredSurfaces = true
        Task { @MainActor in
            await drainRetiredSurfaces()
            drainingRetiredSurfaces = false
        }
    }

    /// One free per main-actor turn, each right after the tick that may have delivered its
    /// command's exit, so retiring many surfaces never adds up to one long block. Until then
    /// the hang-up repeats, as libghostty's own does: `login` misses one that lands while it
    /// is still starting, and the command runs on. The grace starts here rather than at
    /// retirement, so time spent with the drain suspended doesn't count against it.
    private func drainRetiredSurfaces() async {
        while !retiredSurfaces.isEmpty, !mailboxDrainSuspended {
            tick()
            if let index = retiredSurfaces.firstIndex(where: \.isReadyToFree) {
                let retired = retiredSurfaces.remove(at: index)
                let freeStarted = ContinuousClock.now
                ghostty_surface_free(retired.surface)
                onSurfaceFreed?(retired.surface, ContinuousClock.now - freeStarted)
                // A callback may have queued main-actor work holding this userdata's address
                // before the free; release only after that work has run.
                let callbackTarget = retired.callbackTarget
                GhosttyThreadingBridge.enqueueOnMain { callbackTarget.release() }
                await Task.yield()
                continue
            }
            let freeAnywayAt = ContinuousClock.now + Self.hangUpGrace
            for index in retiredSurfaces.indices {
                GhosttySurfaceChildProcess.hangUp(retiredSurfaces[index].surface)
                retiredSurfaces[index].freeAnywayAt = retiredSurfaces[index].freeAnywayAt ?? freeAnywayAt
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Terminal Theme

    /// Apply a light/dark Terminal Theme pair to the app and every live surface
    /// without recreating surfaces (scrollback is preserved). Mirrors the real
    /// Ghostty reload-config path: rebuild a fresh config from the app-owned
    /// file, broadcast it via `ghostty_app_update_config` /
    /// `ghostty_surface_update_config`, then free the previous config.
    ///
    /// Callers persist the selection separately; this only drives the live
    /// apply, so it serves both committed changes and transient previews.
    func applyTheme(lightTheme: String, darkTheme: String) {
        guard initialized, let app else { return }
        let pair = GhosttyThemePersistence.Pair(lightTheme: lightTheme, darkTheme: darkTheme)
        guard let newConfig = makeConfig(for: pair) else { return }

        ghostty_app_update_config(app, newConfig)
        for view in surfaceViews.allObjects {
            guard let surface = view.surface else { continue }
            ghostty_surface_update_config(surface, newConfig)
        }

        if let previous = config {
            ghostty_config_free(previous)
        }
        config = newConfig
    }

    /// Build a finalized `ghostty_config_t` from the app-owned config file.
    /// Theme selection is optional, but WorkSpaces-owned terminal behavior
    /// defaults such as scrollbar and scroll-speed tuning are always loaded.
    private func makeConfig(for pair: GhosttyThemePersistence.Pair) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            log.error("[GhosttyAppManager] ghostty_config_new failed")
            return nil
        }

        if let url = try? GhosttyThemeConfig.writeConfigFile(
            lightTheme: pair.lightTheme,
            darkTheme: pair.darkTheme
        ) {
            ghostty_config_load_file(config, url.path)
        }

        ghostty_config_finalize(config)
        return config
    }

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    private func tick() {
        guard let app else { return }
        tickCount += 1
        ghostty_app_tick(app)
    }

    // MARK: Runtime callbacks

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        wakeupCount.withLock { $0 += 1 }
        let probeToken = LaunchWindowProbe.noteWakeup()
        GhosttyThreadingBridge.enqueueOnMain {
            LaunchWindowProbe.noteTickStart(token: probeToken)
            guard let manager = GhosttyCallbackUserdata.manager(from: userdataAddress),
                !manager.mailboxDrainSuspended
            else { return }
            manager.tick()
        }
    }

    nonisolated static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        _ = app
        return GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: GhosttyCallbackUserdata.surfaceAddress(from:),
            resolveSurfaceView: { address in
                GhosttyCallbackUserdata.surfaceView(from: address)
            },
            runOnMainAsync: GhosttyThreadingBridge.runOnMainAsync(_:)
        )
    }

    nonisolated static func splitActionRequest(from notification: Notification) -> SplitActionRequest? {
        GhosttyRuntimeActionBridge.splitActionRequest(from: notification)
    }

    nonisolated static func tabActionRequest(from notification: Notification) -> TabActionRequest? {
        GhosttyRuntimeActionBridge.tabActionRequest(from: notification)
    }

    nonisolated static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        GhosttyThreadingBridge.runOnMainAsync {
            guard let surfaceView = GhosttyCallbackUserdata.surfaceView(from: userdataAddress) else { return }
            surfaceView.runtimeDidRequestClose(processAlive: processAlive)
        }
    }
}

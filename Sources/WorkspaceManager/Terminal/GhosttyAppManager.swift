//
//  GhosttyAppManager.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit
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
    private var config: ghostty_config_t?
    private var initialized = false
    private var currentColorScheme: ghostty_color_scheme_e?

    /// Live surfaces, weakly held, so a Terminal Theme change can be broadcast
    /// to every open terminal via `ghostty_surface_update_config`. Weak objects
    /// drop automatically when a `GhosttySurfaceView` deallocates, so a stale
    /// entry can never be visited.
    private let surfaceViews = NSHashTable<GhosttySurfaceView>.weakObjects()

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
        ghostty_app_tick(app)
    }

    // MARK: Runtime callbacks

    nonisolated static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let userdataAddress = GhosttyCallbackUserdata.address(from: userdata)
        GhosttyThreadingBridge.runOnMainAsync {
            guard let manager = GhosttyCallbackUserdata.manager(from: userdataAddress) else { return }
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

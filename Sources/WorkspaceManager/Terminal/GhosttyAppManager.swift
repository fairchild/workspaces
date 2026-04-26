//
//  GhosttyAppManager.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttyAppManager: NSObject {
    typealias SplitActionKind = GhosttyRuntimeActionBridge.SplitActionKind
    typealias SplitDirection = GhosttyRuntimeActionBridge.SplitDirection
    typealias SplitFocusDirection = GhosttyRuntimeActionBridge.SplitFocusDirection
    typealias SplitResizeDirection = GhosttyRuntimeActionBridge.SplitResizeDirection
    typealias SplitActionRequest = GhosttyRuntimeActionBridge.SplitActionRequest

    static let shared = GhosttyAppManager()
    nonisolated static let splitActionNotification = GhosttyRuntimeActionBridge.splitActionNotification
    nonisolated static let splitActionKindUserInfoKey = GhosttyRuntimeActionBridge.splitActionKindUserInfoKey
    nonisolated static let splitActionDirectionUserInfoKey =
        GhosttyRuntimeActionBridge.splitActionDirectionUserInfoKey
    nonisolated static let splitActionAmountUserInfoKey = GhosttyRuntimeActionBridge.splitActionAmountUserInfoKey

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var initialized = false
    private var currentColorScheme: ghostty_color_scheme_e?

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
            NSLog("[GhosttyAppManager] using Ghostty resources dir: %@", resourcesDirectory.path)
        } else {
            NSLog("[GhosttyAppManager] Ghostty resources dir unavailable")
        }

        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == GHOSTTY_SUCCESS else {
            NSLog("[GhosttyAppManager] ghostty_init failed: %d", initResult)
            return
        }

        guard let config = ghostty_config_new() else {
            NSLog("[GhosttyAppManager] ghostty_config_new failed")
            return
        }

        ghostty_config_finalize(config)
        self.config = config

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                GhosttyAppManager.wakeup(userdata)
            },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyAppManager.action(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyClipboardBridge.read(userdata: userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                GhosttyClipboardBridge.confirmRead(userdata: userdata, state: state)
            },
            write_clipboard_cb: { userdata, location, content, len, _ in
                GhosttyClipboardBridge.write(userdata: userdata, location: location, content: content, len: len)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyAppManager.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            NSLog("[GhosttyAppManager] ghostty_app_new failed")
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

    @objc private func keyboardSelectionDidChange(_ notification: Notification) {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: Runtime callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        GhosttyThreadingBridge.runOnMainAsync {
            guard let manager = GhosttyCallbackUserdata.manager(from: userdata) else { return }
            manager.tick()
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        _ = app
        return GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: GhosttyCallbackUserdata.surfaceAddress(from:),
            resolveSurfaceView: GhosttyCallbackUserdata.surfaceView(from:),
            runOnMainAsync: GhosttyThreadingBridge.runOnMainAsync(_:)
        )
    }

    nonisolated static func splitActionRequest(from notification: Notification) -> SplitActionRequest? {
        GhosttyRuntimeActionBridge.splitActionRequest(from: notification)
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        GhosttyThreadingBridge.runOnMainAsync {
            guard let surfaceView = GhosttyCallbackUserdata.surfaceView(from: userdata) else { return }
            surfaceView.runtimeDidRequestClose(processAlive: processAlive)
        }
    }
}

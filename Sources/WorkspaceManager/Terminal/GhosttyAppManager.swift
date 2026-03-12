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
                GhosttyAppManager.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                GhosttyAppManager.confirmReadClipboard(userdata, state: state)
            },
            write_clipboard_cb: { userdata, location, content, len, _ in
                GhosttyAppManager.writeClipboard(userdata, location: location, content: content, len: len)
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
        guard let colorSchemeToApply = GhosttyAppearanceSync.nextColorScheme(
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

    private static func manager(from userdata: UnsafeMutableRawPointer?) -> GhosttyAppManager? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyAppManager>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func surfaceUserdata(from target: ghostty_target_s) -> UnsafeMutableRawPointer? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface
        else {
            return nil
        }

        return ghostty_surface_userdata(surface)
    }

    private static func surfaceAddress(from target: ghostty_target_s) -> UInt? {
        surfaceUserdata(from: target).map { UInt(bitPattern: $0) }
    }

    private static func surfaceView(from address: UInt?) -> GhosttySurfaceView? {
        guard let address else { return nil }
        return surfaceView(from: UnsafeMutableRawPointer(bitPattern: address))
    }

    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        surfaceView(from: surfaceUserdata(from: target))
    }

    private static func runOnMainAsync(_ operation: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { operation() }
            return
        }

        Task { @MainActor in
            operation()
        }
    }

    private static func runOnMainSync<T: Sendable>(_ operation: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { operation() }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { operation() }
        }
    }

    // MARK: Runtime callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        runOnMainAsync {
            guard let manager = manager(from: userdata) else { return }
            manager.tick()
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        _ = app
        return GhosttyRuntimeActionBridge.handle(
            target: target,
            action: action,
            resolveSurfaceAddress: surfaceAddress(from:),
            resolveSurfaceView: surfaceView(from:),
            runOnMainAsync: runOnMainAsync(_:)
        )
    }

    nonisolated static func splitActionRequest(from notification: Notification) -> SplitActionRequest? {
        GhosttyRuntimeActionBridge.splitActionRequest(from: notification)
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        let surfaceAddress = runOnMainSync {
            surfaceView(from: userdata)?.surface.map { UInt(bitPattern: $0) }
        }
        let surface = surfaceAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        guard let surface else {
            return
        }

        let value = runOnMainSync {
            let pasteboard: NSPasteboard =
                switch location {
                case GHOSTTY_CLIPBOARD_STANDARD:
                    .general
                default:
                    .general
                }

            return pasteboard.string(forType: .string) ?? ""
        }
        value.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    private static func confirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) {
        let surfaceAddress = runOnMainSync {
            surfaceView(from: userdata)?.surface.map { UInt(bitPattern: $0) }
        }
        let surface = surfaceAddress.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
        guard let surface else {
            return
        }

        "".withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int
    ) {
        guard surfaceView(from: userdata) != nil,
            location == GHOSTTY_CLIPBOARD_STANDARD,
            let content,
            len > 0
        else {
            return
        }

        var preferredText: String?
        var fallbackText: String?

        for index in 0..<len {
            let item = content[index]
            guard let dataPointer = item.data else { continue }
            let data = String(cString: dataPointer)

            if fallbackText == nil {
                fallbackText = data
            }

            if let mimePointer = item.mime,
                String(cString: mimePointer) == "text/plain"
            {
                preferredText = data
                break
            }
        }

        guard let value = preferredText ?? fallbackText else { return }

        runOnMainAsync {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        runOnMainAsync {
            guard let surfaceView = surfaceView(from: userdata) else { return }
            surfaceView.runtimeDidRequestClose(processAlive: processAlive)
        }
    }
}

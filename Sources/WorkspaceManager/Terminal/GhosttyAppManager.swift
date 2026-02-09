//
//  GhosttyAppManager.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

final class GhosttyAppManager: NSObject {
    static let shared = GhosttyAppManager()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var initialized = false

    private override init() {
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let app {
            ghostty_app_free(app)
        }
        if let config {
            ghostty_config_free(config)
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

    private static func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
            let surface = target.target.surface,
            let userdata = ghostty_surface_userdata(surface)
        else {
            return nil
        }

        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    // MARK: Runtime callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let manager = manager(from: userdata) else { return }
        DispatchQueue.main.async {
            manager.tick()
        }
    }

    private static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard let surfaceView = surfaceView(from: target) else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                surfaceView.updateTerminalTitle(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                surfaceView.updateWorkingDirectory(pwd)
            }
            return true

        default:
            return false
        }
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) {
        guard let surfaceView = surfaceView(from: userdata),
            let surface = surfaceView.surface
        else {
            return
        }

        let pasteboard: NSPasteboard =
            switch location {
            case GHOSTTY_CLIPBOARD_STANDARD:
                .general
            default:
                .general
            }

        let value = pasteboard.string(forType: .string) ?? ""
        value.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
    }

    private static func confirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) {
        guard let surfaceView = surfaceView(from: userdata),
            let surface = surfaceView.surface
        else {
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

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let surfaceView = surfaceView(from: userdata) else { return }

        DispatchQueue.main.async {
            surfaceView.runtimeDidRequestClose(processAlive: processAlive)
        }
    }
}

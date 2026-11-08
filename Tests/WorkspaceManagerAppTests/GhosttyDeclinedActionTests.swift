//
//  GhosttyDeclinedActionTests.swift
//  WorkspaceManagerAppTests
//
//  A tile does not own its window, so the runtime declines Ghostty's window-level
//  requests: `RESIZE_WINDOW` (a program's CSI 8 t) and `SET_WINDOW_THEME`. These pin
//  that each returns not-handled and leaves the hosting window's frame and appearance
//  as they were, so an edit to the action switch cannot start obeying a terminal program.
//

import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import WorkspaceManager

@Suite("Ghostty declined window actions")
@MainActor
struct GhosttyDeclinedActionTests {
    @Test(
        "A declined window action is not handled and schedules nothing",
        arguments: ["resize_window", "set_window_theme"]
    )
    func declinedAtTheBridge(actionName: String) {
        let action =
            actionName == "resize_window"
            ? Self.resizeWindow() : Self.setWindowTheme(GHOSTTY_ACTION_WINDOW_THEME_DARK)
        let scheduled = LockedCounter()
        let posted = LockedCounter()
        let observers = [
            GhosttyRuntimeActionBridge.splitActionNotification,
            GhosttyRuntimeActionBridge.tabActionNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in posted.increment() }
        }
        defer { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        let handled = GhosttyRuntimeActionBridge.handle(
            target: ghostty_target_s(),
            action: action,
            resolveSurfaceAddress: { _ in 0x1 },
            resolveSurfaceView: { _ in
                Issue.record("a declined action must not reach a surface view")
                return nil
            },
            runOnMainAsync: { _ in scheduled.increment() }
        )

        #expect(handled == false)
        #expect(scheduled.value == 0)
        #expect(posted.value == 0)
    }

    @Test("A terminal's resize and theme requests leave its window's frame and appearance alone")
    func windowUnchangedThroughTheAppCallback() async throws {
        let view = GhosttySurfaceView(workingDirectory: FileManager.default.temporaryDirectory)
        let app = try #require(GhosttyAppManager.shared.app, "creating a surface starts the shared Ghostty app")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        defer { window.contentView = nil }
        let surface = try #require(view.surface, "the view needs a Ghostty surface to target")

        var surfaceTarget = ghostty_target_s()
        surfaceTarget.tag = GHOSTTY_TARGET_SURFACE
        surfaceTarget.target.surface = surface
        var appTarget = ghostty_target_s()
        appTarget.tag = GHOSTTY_TARGET_APP

        let frame = window.frame
        let appAppearance = NSApp.appearance
        let requests: [(ghostty_target_s, ghostty_action_s)] = [
            (surfaceTarget, Self.resizeWindow()),
            (surfaceTarget, Self.setWindowTheme(GHOSTTY_ACTION_WINDOW_THEME_DARK)),
            (appTarget, Self.setWindowTheme(GHOSTTY_ACTION_WINDOW_THEME_DARK)),
            (appTarget, Self.setWindowTheme(GHOSTTY_ACTION_WINDOW_THEME_LIGHT)),
        ]
        for (target, action) in requests {
            #expect(GhosttyAppManager.action(app, target: target, action: action) == false)
        }
        await Self.drainMainQueue()

        #expect(window.frame == frame)
        #expect(window.appearance?.name == .aqua)
        #expect(NSApp.appearance == appAppearance)
    }

    private static func resizeWindow() -> ghostty_action_s {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RESIZE_WINDOW
        action.action.resize_window = ghostty_action_resize_window_s(width: 1800, height: 1200)
        return action
    }

    private static func setWindowTheme(_ theme: ghostty_action_window_theme_e) -> ghostty_action_s {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_WINDOW_THEME
        action.action.set_window_theme = theme
        return action
    }

    /// Anything the callback queued for the main thread runs before this returns.
    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

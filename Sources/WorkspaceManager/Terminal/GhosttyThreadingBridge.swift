//
//  GhosttyThreadingBridge.swift
//  WorkspaceManager
//

import Foundation

enum GhosttyThreadingBridge {
    static func runOnMainAsync(_ operation: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { operation() }
            return
        }

        Task { @MainActor in
            operation()
        }
    }

    /// Always enqueues, even on the main thread. The wakeup→tick path needs this:
    /// libghostty can invoke the wakeup callback on the main thread from inside another
    /// libghostty call, and an inline `ghostty_app_tick` there re-enters the core mid-call
    /// (upstream Ghostty.app also dispatches its wakeup tick asynchronously). The inline
    /// shortcut also let a launch close `launch_to_first_prompt` while the main thread was
    /// still mid-bring-up — the #1251 fast mode was that artifact, not a faster launch.
    static func enqueueOnMain(_ operation: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            operation()
        }
    }

    static func runOnMainSync<T: Sendable>(_ operation: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { operation() }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { operation() }
        }
    }
}

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

    static func runOnMainSync<T: Sendable>(_ operation: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { operation() }
        }

        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { operation() }
        }
    }
}

//
//  TmuxLaunchGuard.swift
//  WorkspaceManager
//
//  Stops a test process from starting tmux on a socket the running app uses. A test that
//  realizes a tmux-mode surface would otherwise create sessions, and set server options,
//  on the person's live tmux server.
//

import Foundation
import MachO
import WorkspaceManagerCore

enum TmuxLaunchGuard {
    /// The labels a running app's tiles live on: the default, and the one a rejected
    /// override falls back to.
    static let liveSocketLabels: Set<String> = [
        TmuxSessionProbe.defaultSocketLabel,
        TmuxSessionProbe.quarantineSocketLabel,
    ]

    /// Why a launch on `socketLabel` is refused, or `nil` when it may go ahead. Only a test
    /// process is refused, and only on a live label.
    static func refusal(socketLabel: String, inTestProcess: Bool) -> String? {
        guard inTestProcess, liveSocketLabels.contains(socketLabel) else { return nil }
        return """
            A test is launching tmux on the live socket -L \(socketLabel). Realize the surface in \
            ghosttyManagedSplits mode; tmux itself is tested against a server on an isolated label, \
            as TerminalSessionExitTests does.
            """
    }

    /// Fails the process when a test is about to run `launchScript` on a live socket.
    static func check(launchScript: String?) {
        guard launchScript != nil,
            let message = refusal(socketLabel: TmuxSessionProbe.socketLabel, inTestProcess: isTestProcess)
        else { return }
        preconditionFailure(message)
    }

    /// Whether an XCTest bundle is loaded, which is true under `swift test` for both XCTest
    /// and Swift Testing, and never in the app.
    static let isTestProcess: Bool = (0..<_dyld_image_count()).contains { index in
        guard let name = _dyld_get_image_name(index) else { return false }
        return String(cString: name).contains(".xctest/")
    }
}

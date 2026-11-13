//
//  TmuxLiveSocketGuard.swift
//  WorkspaceManagerCore
//
//  Stops a test process from reaching tmux on a socket the running app uses: starting a
//  session there, killing one, or asking its server anything. A test that did would
//  create, kill or read sessions on the person's live tmux server.
//

import Foundation
import MachO

public enum TmuxLiveSocketGuard {
    /// The labels a running app's tiles live on: the default, and the one a rejected
    /// override falls back to.
    public static let liveSocketLabels: Set<String> = [
        TmuxSessionProbe.defaultSocketLabel,
        TmuxSessionProbe.quarantineSocketLabel,
    ]

    /// Why reaching tmux on `socketLabel` is refused, or `nil` when it may go ahead. Only a
    /// test process is refused, and only on a live label.
    public static func refusal(socketLabel: String, inTestProcess: Bool) -> String? {
        guard inTestProcess, liveSocketLabels.contains(socketLabel) else { return nil }
        return """
            A test is reaching tmux on the live socket -L \(socketLabel). Realize surfaces in \
            ghosttyManagedSplits mode and inject the store's tmux seams; tmux itself is tested \
            against a server on an isolated label, as TerminalSessionExitTests does.
            """
    }

    /// Whether a tmux command with `arguments` may run. One that names a live socket from a
    /// test process fails the process, or, while a test observes refusals through
    /// `onRefusal`, is reported there and does not run.
    public static func permits(tmuxArguments arguments: [String]) -> Bool {
        guard let flag = arguments.firstIndex(of: "-L"), flag + 1 < arguments.count else { return true }
        return permits(socketLabel: arguments[flag + 1])
    }

    /// Fails the process when a test is about to run `launchScript` on a live socket. A
    /// launch is never only reported: it would already have run.
    public static func check(launchScript: String?) {
        guard launchScript != nil,
            let message = refusal(socketLabel: TmuxSessionProbe.socketLabel, inTestProcess: isTestProcess)
        else { return }
        preconditionFailure(message)
    }

    private static func permits(socketLabel: String) -> Bool {
        guard let message = refusal(socketLabel: socketLabel, inTestProcess: isTestProcess) else { return true }
        guard let onRefusal else { preconditionFailure(message) }
        onRefusal(message)
        return false
    }

    /// Where a test observes refusals instead of failing the process.
    @TaskLocal public static var onRefusal: (@Sendable (String) -> Void)?

    /// Whether an XCTest bundle is loaded, which is true under `swift test` for both XCTest
    /// and Swift Testing, and never in the app.
    public static let isTestProcess: Bool = (0..<_dyld_image_count()).contains { index in
        guard let name = _dyld_get_image_name(index) else { return false }
        return String(cString: name).contains(".xctest/")
    }
}

//
//  TerminalForegroundProcessResolver.swift
//  WorkspaceManager
//
//  Resolves the real foreground process name of a plain terminal tab (e.g. `vim`,
//  `python`, `zsh`) so the sidebar hover card can show what is actually running rather
//  than the terminal title, which only approximates it. Only tmux-per-session mode is
//  resolvable: libghostty exposes no child PID or PTY fd, so ghostty-managed-splits
//  surfaces fall back to the title/directory (see #666 and the upstream pid/fd gap).
//  Resolution is async and lazy; results are cached briefly per session.
//

import Foundation
import WorkspaceManagerCore

struct TerminalForegroundProcessResolver: Sendable {
    static let cacheTTL: TimeInterval = 2.0
    private static let cache = CacheBox()

    private let probe: TmuxSessionProbe
    private let tmuxSessionName: @Sendable (URL) -> String

    init(
        probe: TmuxSessionProbe = TmuxSessionProbe(),
        tmuxSessionName: @escaping @Sendable (URL) -> String = { GhosttyTerminalConfig.tmuxSessionName(for: $0) }
    ) {
        self.probe = probe
        self.tmuxSessionName = tmuxSessionName
    }

    /// The foreground process name for `session`, or `nil` when it cannot be resolved:
    /// ghostty-splits mode (no PID/fd exposure), no live tmux session, or tmux
    /// unavailable. Cached per session id for `cacheTTL`.
    func foregroundName(
        for session: HostTerminalSession,
        mode: TerminalMultiplexingMode
    ) async -> String? {
        guard mode == .tmuxPerSession else { return nil }
        if let cached = Self.cache.read(sessionID: session.id, ttl: Self.cacheTTL) {
            return cached
        }
        let name = await probe.foregroundCommand(forSessionNamed: tmuxSessionName(session.directoryURL))
        Self.cache.write(sessionID: session.id, name: name)
        return name
    }

    /// Fallback ladder for a plain tab's display string: the real foreground process
    /// name when resolved, otherwise the existing terminal title (which already falls
    /// back to the directory).
    static func preferredTabTitle(foregroundName: String?, terminalTitle: String) -> String {
        if let foregroundName, !foregroundName.trimmingCharacters(in: .whitespaces).isEmpty {
            return foregroundName
        }
        return terminalTitle
    }

    private final class CacheBox: @unchecked Sendable {
        private struct Entry {
            let name: String?
            let recordedAt: Date
        }
        private var entries: [UUID: Entry] = [:]
        private let lock = NSLock()

        func read(sessionID: UUID, ttl: TimeInterval) -> String?? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[sessionID],
                Date().timeIntervalSince(entry.recordedAt) < ttl
            else { return nil }
            return .some(entry.name)
        }

        func write(sessionID: UUID, name: String?) {
            lock.lock()
            defer { lock.unlock() }
            entries[sessionID] = Entry(name: name, recordedAt: Date())
        }
    }
}

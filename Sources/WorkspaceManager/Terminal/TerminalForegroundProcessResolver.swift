//
//  TerminalForegroundProcessResolver.swift
//  WorkspaceManager
//
//  Resolves the real foreground process name of a plain terminal tab (e.g. `vim`,
//  `python`) so the sidebar hover card can show what is actually running rather than the
//  terminal title, which only approximates it.
//
//  Resolution ladder, tried in order:
//    1. tmux mode only — the session's active pane command (`pane_current_command`),
//       which disambiguates tabs that share a working directory.
//    2. all modes — the non-shell program running in the session's directory, via
//       WorkspaceProcessMonitor's `lsof` cwd match. This is what covers the DEFAULT
//       ghostty-managed-splits mode, where libghostty exposes no child PID or PTY fd to
//       do true per-surface detection (see #666; upstream fd/pid ask filed separately).
//  A `nil` result means the caller falls back to the terminal title / directory. The
//  cwd match is directory-scoped, so sibling tabs in one directory can't be told apart
//  outside tmux mode — an acceptable limit for an advisory hover card.
//
//  Resolution is async and lazy; results are cached briefly per session.
//

import Foundation
import WorkspaceManagerCore

struct TerminalForegroundProcessResolver: Sendable {
    static let cacheTTL: TimeInterval = 2.0
    private static let cache = CacheBox()

    private let probe: TmuxSessionProbe
    private let tmuxSessionName: @Sendable (URL) -> String
    /// The non-shell program running in a directory (via `lsof` cwd match), or nil.
    private let cwdProgramName: @Sendable (URL) async -> String?

    init(
        probe: TmuxSessionProbe = TmuxSessionProbe(),
        tmuxSessionName: @escaping @Sendable (URL) -> String = { GhosttyTerminalConfig.tmuxSessionName(for: $0) },
        cwdProgramName: @escaping @Sendable (URL) async -> String? = TerminalForegroundProcessResolver
            .defaultCwdProgramName
    ) {
        self.probe = probe
        self.tmuxSessionName = tmuxSessionName
        self.cwdProgramName = cwdProgramName
    }

    /// The foreground process name for `session`, or `nil` when nothing resolves (the
    /// caller then falls back to the terminal title / directory). Cached per session id
    /// for `cacheTTL`.
    func foregroundName(
        for session: HostTerminalSession,
        mode: TerminalMultiplexingMode
    ) async -> String? {
        if let cached = Self.cache.read(sessionID: session.id, ttl: Self.cacheTTL) {
            return cached
        }
        var resolved: String?
        if mode == .tmuxPerSession {
            resolved = await probe.foregroundCommand(forSessionNamed: tmuxSessionName(session.directoryURL))
        }
        if resolved == nil {
            resolved = await cwdProgramName(session.directoryURL)
        }
        Self.cache.write(sessionID: session.id, name: resolved)
        return resolved
    }

    /// Fallback ladder tail: the resolved foreground process name when present, otherwise
    /// the existing terminal title (which already falls back to the directory).
    static func preferredTabTitle(foregroundName: String?, terminalTitle: String) -> String {
        if let foregroundName, !foregroundName.trimmingCharacters(in: .whitespaces).isEmpty {
            return foregroundName
        }
        return terminalTitle
    }

    /// Production cwd resolver: the first non-agent program whose cwd is the session's
    /// directory, per `WorkspaceProcessMonitor` (which ignores shells and known agents).
    /// Returns nil for a bare shell so the caller falls back to the title.
    static let defaultCwdProgramName: @Sendable (URL) async -> String? = { directory in
        let status = await WorkspaceProcessMonitor().detectAgentSession(in: directory)
        return status.processes.first { !$0.isKnownAgent }?.displayName
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

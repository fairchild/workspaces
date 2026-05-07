//
//  PTYForegroundProbe.swift
//  WorkspaceManager
//
//  Detect the foreground agent type for a libghostty surface by looking at the
//  PTY's foreground process group leader (`tcgetpgrp` + `proc_pidpath`). PR #1
//  ships a fail-safe default that always returns `.claudeCode`, since the only
//  rich-hooks adapter is Claude — OSC fallback covers everything else and an
//  upstream libghostty change is required to expose the PTY fd cleanly.
//
//  See coordination.md (PR #1 deviations) and spec § "Anti-patterns" → process-name
//  detection.
//

import Foundation
import WorkspaceManagerCore

public struct PTYForegroundProbe: Sendable {
    private struct CacheEntry {
        let kind: AgentKind
        let recordedAt: Date
    }

    private static let cacheTTL: TimeInterval = 2.0
    private static let cache = CacheBox()

    public init() {}

    // MARK: - Stub — see coordination.md
    //
    // PR #1 ships this method as a deliberate stub that returns `.claudeCode` for
    // every surface. The probe is fail-safe because Claude is the only adapter that
    // decodes hook payloads, and the OSC fallback covers every other agent
    // regardless of detected kind.
    //
    // Real foreground-process detection becomes a Channel 3 concern when opencode
    // or aider parity matters. At that point, replace the body with
    // `tcgetpgrp` + a `proc_pidpath` lookup against the slave-side PTY fd (requires
    // either an upstream libghostty addition that exposes the fd, or platform
    // traversal of the surface's child-process tree via `proc_listpids`). The
    // cache, the public surface, and the call sites are stable — only the body
    // changes.
    public func detect(surfaceID: UInt64) -> AgentKind {
        if let cached = Self.cache.read(surfaceID: surfaceID),
            Date().timeIntervalSince(cached.recordedAt) < Self.cacheTTL
        {
            return cached.kind
        }
        let resolved = AgentKind.claudeCode
        Self.cache.write(surfaceID: surfaceID, kind: resolved)
        return resolved
    }

    private final class CacheBox: @unchecked Sendable {
        private var entries: [UInt64: CacheEntry] = [:]
        private let lock = NSLock()

        func read(surfaceID: UInt64) -> CacheEntry? {
            lock.lock()
            defer { lock.unlock() }
            return entries[surfaceID]
        }

        func write(surfaceID: UInt64, kind: AgentKind) {
            lock.lock()
            defer { lock.unlock() }
            entries[surfaceID] = CacheEntry(kind: kind, recordedAt: Date())
        }
    }
}

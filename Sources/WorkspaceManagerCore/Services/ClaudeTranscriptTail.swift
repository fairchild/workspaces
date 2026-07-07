//
//  ClaudeTranscriptTail.swift
//  WorkspaceManagerCore
//
//  Resolves the last assistant message from a Claude Code session's JSONL transcript, for the
//  sidebar hover card's latest-activity line (#680). Claude Code stores transcripts at
//  ~/.claude/projects/<slug>/<agentSessionID>.jsonl, where <slug> is the session cwd with every
//  '/' and '.' turned into '-'. The pure pieces (path + last-assistant parse) are unit-tested;
//  the actor reads only the file's tail (no whole-file loads) with a short TTL cache. Every
//  failure mode — wrong agent kind, missing id, unreadable or unparseable file — resolves to nil.
//

import Foundation

public enum ClaudeTranscriptTail {
    /// Default number of bytes read from the end of a transcript. Comfortably larger than a
    /// single assistant turn's JSONL line, so the last message is present without loading the file.
    public static let defaultTailByteCount = 16_384

    /// The on-disk transcript for a Claude Code session, or `nil` when it can't apply (non-Claude
    /// agent, missing session id, or empty cwd). Existence is not checked here — callers read lazily.
    public static func transcriptURL(
        cwd: String,
        agentSessionID: String?,
        kind: AgentKind,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard kind == .claudeCode else { return nil }
        guard let agentSessionID, !agentSessionID.isEmpty else { return nil }
        let trimmedCWD = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCWD.isEmpty else { return nil }
        return
            homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectSlug(forCWD: trimmedCWD), isDirectory: true)
            .appendingPathComponent("\(agentSessionID).jsonl", isDirectory: false)
    }

    /// Claude Code's project-directory slug: the cwd with every '/' and '.' replaced by '-'
    /// (so `/a/b/.hidden` becomes `-a-b--hidden`). Verified against on-disk transcript dirs.
    public static func projectSlug(forCWD cwd: String) -> String {
        String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    /// The last assistant text block found in a JSONL tail chunk, collapsed to one line and
    /// truncated. The chunk may begin mid-line (a partial leading line simply fails to parse and
    /// is skipped). Lines are scanned newest-first; `thinking`/`tool_use` blocks and non-assistant
    /// rows are ignored. Returns `nil` when no assistant text is present.
    public static func lastAssistantText(
        inTailChunk chunk: String,
        maxLength: Int = SessionActivitySnippet.defaultMaxLength
    ) -> String? {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content.reversed()
            where block["type"] as? String == "text" {
                if let text = block["text"] as? String {
                    let single = text.singleLineTruncated(maxLength: maxLength)
                    if !single.isEmpty { return single }
                }
            }
        }
        return nil
    }
}

/// Reads the last assistant message from a Claude Code transcript, caching by path + mtime for a
/// short TTL so the hover card's repeated re-renders don't re-read the file. Reads only the tail.
public actor ClaudeTranscriptTailResolver {
    private struct CacheEntry {
        let value: String?
        let modificationDate: Date?
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private let tailByteCount: Int
    private let maxLength: Int
    private var cache: [String: CacheEntry] = [:]

    public init(
        ttl: TimeInterval = 2,
        tailByteCount: Int = ClaudeTranscriptTail.defaultTailByteCount,
        maxLength: Int = SessionActivitySnippet.defaultMaxLength
    ) {
        self.ttl = ttl
        self.tailByteCount = tailByteCount
        self.maxLength = maxLength
    }

    /// The latest assistant message for a Claude Code session, or `nil` for any non-happy path.
    public func tail(
        cwd: String,
        agentSessionID: String?,
        kind: AgentKind,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date()
    ) -> String? {
        guard
            let url = ClaudeTranscriptTail.transcriptURL(
                cwd: cwd, agentSessionID: agentSessionID, kind: kind, homeDirectory: homeDirectory)
        else { return nil }

        let path = url.path
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let cached = cache[path],
            cached.expiresAt > now,
            cached.modificationDate == modificationDate
        {
            return cached.value
        }

        let value = Self.readTail(at: url, tailByteCount: tailByteCount, maxLength: maxLength)
        cache[path] = CacheEntry(
            value: value, modificationDate: modificationDate, expiresAt: now.addingTimeInterval(ttl))
        return value
    }

    private static func readTail(at url: URL, tailByteCount: Int, maxLength: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(tailByteCount) ? end - UInt64(tailByteCount) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(),
            !data.isEmpty
        else { return nil }
        let chunk = String(decoding: data, as: UTF8.self)
        return ClaudeTranscriptTail.lastAssistantText(inTailChunk: chunk, maxLength: maxLength)
    }
}

//
//  ClaudeTranscriptLocator.swift
//  WorkspaceManagerCore
//
//  Locates a Claude Code session transcript on disk so cold-start restore can
//  decide whether `claude --resume <id>` will succeed. Claude stores transcripts
//  at <claudeHome>/projects/<encoded-cwd>/<session-id>.jsonl, where the directory
//  name encodes the launch cwd by replacing every non-ASCII-alphanumeric
//  character with '-' (1:1, no run-collapsing — e.g. "/.claude" -> "--claude").
//

import Foundation

/// Pure encoder + path composer for Claude transcript locations. No filesystem
/// access, so the encoding is unit-testable in isolation.
public struct ClaudeTranscriptLocator: Sendable {
    public init() {}

    /// Encode a cwd into Claude's `projects/` directory name: each character that
    /// is not `[A-Za-z0-9]` becomes `-`, per Unicode scalar, preserving length.
    public static func encodeProjectDirectory(_ path: String) -> String {
        var encoded = String.UnicodeScalarView()
        encoded.reserveCapacity(path.unicodeScalars.count)
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:  // 0-9, A-Z, a-z
                encoded.append(scalar)
            default:
                encoded.append("-")
            }
        }
        return String(encoded)
    }

    /// The transcript path for a session launched from `cwd`. `cwd` is encoded
    /// verbatim — not standardized or symlink-resolved — because Claude keyed the
    /// directory off the exact cwd its hook reported, which is what the store
    /// persisted in `agentCwd`.
    public func transcriptURL(claudeHome: URL, cwd: String, sessionID: String) -> URL {
        claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(Self.encodeProjectDirectory(cwd), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }
}

/// Synchronous transcript-existence check that conforms to the planner's
/// `TranscriptResumabilityCheck`. Resolves `claudeHome` from `CLAUDE_CONFIG_DIR`
/// when set, else `~/.claude`. Filesystem access is injected for testability.
public struct ClaudeTranscriptResumability: Sendable {
    private let claudeHome: URL
    private let fileExists: @Sendable (String) -> Bool
    private let transcriptIDsNewestFirst: @Sendable (URL) -> [String]
    private let locator = ClaudeTranscriptLocator()

    /// Transcript ids in one `projects/<encoded-cwd>` directory, newest first by file
    /// modification date. Unreadable directories yield none rather than throwing:
    /// "no transcript here" and "cannot look" mean the same thing to restore.
    public static let defaultTranscriptIDsNewestFirst: @Sendable (URL) -> [String] = { directory in
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return
            urls
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let modified =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return (id: url.deletingPathExtension().lastPathComponent, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
            .map(\.id)
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        transcriptIDsNewestFirst: @escaping @Sendable (URL) -> [String] = defaultTranscriptIDsNewestFirst
    ) {
        self.transcriptIDsNewestFirst = transcriptIDsNewestFirst
        if let configDir = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !configDir.isEmpty
        {
            claudeHome = URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            claudeHome = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        self.fileExists = fileExists
    }

    public func isResumable(agentSessionID: String, cwd: String) -> Bool {
        existingTranscriptURL(agentSessionID: agentSessionID, cwd: cwd) != nil
    }

    /// The transcript URL for this session when the file still exists on disk,
    /// else `nil`. Same predicate as `isResumable`, but returns the resolved URL
    /// so a history view can both badge resumability and render the transcript
    /// from one `claudeHome` resolution.
    public func existingTranscriptURL(agentSessionID: String, cwd: String) -> URL? {
        let url = locator.transcriptURL(claudeHome: claudeHome, cwd: cwd, sessionID: agentSessionID)
        return fileExists(url.path) ? url : nil
    }

    /// The newest transcript id recorded for `cwd` that no earlier surface claimed,
    /// or `nil` when the directory holds none. Newest-first is what makes "the
    /// conversation I was just in" the answer.
    public func newestTranscriptID(cwd: String, claimed: Set<String> = []) -> String? {
        let directory =
            claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscriptLocator.encodeProjectDirectory(cwd), isDirectory: true)
        return transcriptIDsNewestFirst(directory).first { !claimed.contains($0) }
    }

    /// Adapt to the planner's injected `TranscriptResumabilityCheck` closure.
    public func asCheck() -> TerminalRestorePlanner.TranscriptResumabilityCheck {
        { agentSessionID, cwd in isResumable(agentSessionID: agentSessionID, cwd: cwd) }
    }

    /// Adapt to the planner's injected `TranscriptIdentityResolver` closure.
    public func asIdentityResolver() -> TerminalRestorePlanner.TranscriptIdentityResolver {
        { cwd, claimed in newestTranscriptID(cwd: cwd, claimed: claimed) }
    }
}

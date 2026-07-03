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
    private let locator = ClaudeTranscriptLocator()

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
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
        let url = locator.transcriptURL(claudeHome: claudeHome, cwd: cwd, sessionID: agentSessionID)
        return fileExists(url.path)
    }

    /// Adapt to the planner's injected `TranscriptResumabilityCheck` closure.
    public func asCheck() -> TerminalRestorePlanner.TranscriptResumabilityCheck {
        { agentSessionID, cwd in isResumable(agentSessionID: agentSessionID, cwd: cwd) }
    }
}

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeTranscriptLocator")
struct ClaudeTranscriptLocatorTests {
    // Real cwd → encoded-dir pairs pulled from live ~/.claude/projects transcripts.
    // These regression-lock the two behaviors that are easy to get wrong: "/." → "--"
    // (a double dash, not one) and no collapsing of dash runs.
    @Test("Encoding matches real Claude project directory names")
    func encodesRealPairs() {
        #expect(
            ClaudeTranscriptLocator.encodeProjectDirectory("/Users/fairchild/code/workspaces")
                == "-Users-fairchild-code-workspaces"
        )
        #expect(
            ClaudeTranscriptLocator.encodeProjectDirectory(
                "/Users/fairchild/code/mfwiki/.claude/worktrees/chat-noise-routing"
            ) == "-Users-fairchild-code-mfwiki--claude-worktrees-chat-noise-routing"
        )
    }

    @Test("Every non-alphanumeric character becomes a single dash, length preserved")
    func encodesSyntheticRule() {
        #expect(ClaudeTranscriptLocator.encodeProjectDirectory("/tmp/a_b") == "-tmp-a-b")  // underscore
        #expect(ClaudeTranscriptLocator.encodeProjectDirectory("/a/.b") == "-a--b")  // "/." -> "--"
        #expect(ClaudeTranscriptLocator.encodeProjectDirectory("/x y") == "-x-y")  // space
        #expect(ClaudeTranscriptLocator.encodeProjectDirectory("/Repo/CamelCase") == "-Repo-CamelCase")  // case kept
        let path = "/Users/x/proj"
        #expect(ClaudeTranscriptLocator.encodeProjectDirectory(path).count == path.count)  // 1:1 length
    }

    @Test("transcriptURL composes projects/<encoded>/<id>.jsonl")
    func composesTranscriptURL() {
        let url = ClaudeTranscriptLocator().transcriptURL(
            claudeHome: URL(fileURLWithPath: "/home/.claude"),
            cwd: "/repo/app",
            sessionID: "sess-123"
        )
        #expect(url.path == "/home/.claude/projects/-repo-app/sess-123.jsonl")
    }

    @Test("Resumability reflects transcript presence under the default ~/.claude home")
    func resumabilityUsesDefaultHome() {
        let present = "/home/.claude/projects/-repo-app/sess-9.jsonl"
        let checker = ClaudeTranscriptResumability(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/home"),
            fileExists: { $0 == present }
        )
        #expect(checker.isResumable(agentSessionID: "sess-9", cwd: "/repo/app"))
        #expect(!checker.isResumable(agentSessionID: "missing", cwd: "/repo/app"))
    }

    @Test("CLAUDE_CONFIG_DIR re-roots the probed transcript path")
    func resumabilityHonorsConfigDirOverride() {
        let recorder = PathRecorder()
        let checker = ClaudeTranscriptResumability(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/cfg"],
            homeDirectory: URL(fileURLWithPath: "/home"),
            fileExists: { path in
                recorder.path = path
                return true
            }
        )
        #expect(checker.isResumable(agentSessionID: "sess-1", cwd: "/repo"))
        #expect(recorder.path == "/custom/cfg/projects/-repo/sess-1.jsonl")
    }
}

/// Reference recorder so a `@Sendable` `fileExists` stub can report the path it
/// was handed (a mutable local can't be captured by a `@Sendable` closure).
private final class PathRecorder: @unchecked Sendable {
    var path: String?
}

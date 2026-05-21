//
//  DefaultAgentResolverTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("DefaultAgentResolver")
struct DefaultAgentResolverTests {
    private let resolver = DefaultAgentResolver()

    @Test("All nil → nil")
    func allNil() {
        #expect(resolver.resolve(workspaceCommand: nil, repoCommand: nil, globalCommand: nil) == nil)
    }

    @Test("Only global set → returns global")
    func globalOnly() {
        #expect(
            resolver.resolve(
                workspaceCommand: nil,
                repoCommand: nil,
                globalCommand: "claude --resume"
            ) == "claude --resume"
        )
    }

    @Test("Repo overrides global")
    func repoOverridesGlobal() {
        #expect(
            resolver.resolve(
                workspaceCommand: nil,
                repoCommand: "codex",
                globalCommand: "claude --resume"
            ) == "codex"
        )
    }

    @Test("Workspace overrides repo and global")
    func workspaceOverridesAll() {
        #expect(
            resolver.resolve(
                workspaceCommand: "aider",
                repoCommand: "codex",
                globalCommand: "claude --resume"
            ) == "aider"
        )
    }

    @Test("Empty string is treated as nil and falls through")
    func emptyFallsThrough() {
        #expect(
            resolver.resolve(
                workspaceCommand: "",
                repoCommand: "",
                globalCommand: "claude"
            ) == "claude"
        )
        #expect(
            resolver.resolve(
                workspaceCommand: "",
                repoCommand: "codex",
                globalCommand: nil
            ) == "codex"
        )
    }

    @Test("Whitespace-only is treated as nil and falls through")
    func whitespaceFallsThrough() {
        #expect(
            resolver.resolve(
                workspaceCommand: "   ",
                repoCommand: "\t\n",
                globalCommand: "claude"
            ) == "claude"
        )
    }

    @Test("Non-empty values are trimmed of surrounding whitespace")
    func trimsSurroundingWhitespace() {
        #expect(
            resolver.resolve(
                workspaceCommand: "  claude --resume  \n",
                repoCommand: nil,
                globalCommand: nil
            ) == "claude --resume"
        )
    }

    @Test("Internal whitespace is preserved")
    func preservesInternalWhitespace() {
        #expect(
            resolver.resolve(
                workspaceCommand: "claude --resume --model opus",
                repoCommand: nil,
                globalCommand: nil
            ) == "claude --resume --model opus"
        )
    }
}

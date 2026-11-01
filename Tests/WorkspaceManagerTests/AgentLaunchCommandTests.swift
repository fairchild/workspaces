//
//  AgentLaunchCommandTests.swift
//  WorkspaceManagerTests
//
//  Pins what a launch command is read as. The failure this guards is quiet either way: a
//  command wrongly rewritten runs something the caller did not write, and one wrongly left
//  alone loses its conversation when the session ends.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Agent launch command")
struct AgentLaunchCommandTests {
    private static let id = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"

    private func plan(_ command: String?) -> AgentLaunchCommand.Plan {
        AgentLaunchCommand.plan(command: command, newConversationID: { Self.id })
    }

    @Test("A plain claude command names its conversation right after the command word")
    func namesTheConversation() {
        let plan = plan("claude --model claude-opus-5-5 --effort xhigh --name work 'fix the bug'")
        #expect(
            plan.command
                == "claude --session-id \(Self.id) --model claude-opus-5-5 --effort xhigh --name work 'fix the bug'"
        )
        #expect(
            plan.identity
                == AgentLaunchIdentity(
                    conversationID: Self.id,
                    requestedModel: "claude-opus-5-5",
                    requestedEffort: "xhigh"
                )
        )
    }

    @Test(
        "The command word is found however it is spelled",
        arguments: [
            ("claude", "claude --session-id \(id)"),
            ("/usr/local/bin/claude 'hi'", "/usr/local/bin/claude --session-id \(id) 'hi'"),
            ("FOO=bar claude", "FOO=bar claude --session-id \(id)"),
            ("  claude  'two  spaces'", "  claude --session-id \(id)  'two  spaces'"),
            ("claude -- --model x", "claude --session-id \(id) -- --model x"),
        ]
    )
    func commandWord(command: String, expected: String) {
        #expect(plan(command).command == expected)
    }

    @Test("Both flag spellings are read")
    func flagSpellings() {
        let identity = plan("claude --model=opus --effort=max").identity
        #expect(identity?.requestedModel == "opus")
        #expect(identity?.requestedEffort == "max")
    }

    @Test("Nothing past -- is a flag, and an alias with a variant suffix is kept whole")
    func valueHandling() {
        #expect(plan("claude -- --model x").identity?.requestedModel == nil)
        #expect(plan("claude --model 'claude-opus-5-5[1m]'").identity?.requestedModel == "claude-opus-5-5[1m]")
    }

    @Test("A value that could not be typed back safely is not recorded, and the launch still runs")
    func unsafeValue() {
        let plan = plan("claude --model 'x;y' 'hi'")
        #expect(plan.identity?.conversationID == Self.id)
        #expect(plan.identity?.requestedModel == nil)
    }

    @Test("A command that already names its conversation keeps it")
    func existingConversation() {
        for flag in ["--session-id", "--resume", "-r"] {
            let command = "claude \(flag) \(Self.id) --effort low"
            let plan = AgentLaunchCommand.plan(command: command, newConversationID: { "unused" })
            #expect(plan.command == command)
            #expect(plan.identity?.conversationID == Self.id)
        }
    }

    @Test(
        "Anything else runs exactly as written and names nothing",
        arguments: [
            "codex", "aider --yes", "echo claude", "claude-as work",
            "claude -p 'one shot'", "claude --print hi", "claude --continue", "claude -c",
            "claude --resume", "claude --resume not-a-uuid", "claude --fork-session --resume \(id)",
            "claude --bg", "claude doctor", "claude mcp list", "claude update",
            "claude; rm -rf x", "claude && echo done", "claude | tee log", "claude > log",
            "(claude)", "claude $FLAGS", "claude `flags`", "claude # note", "claude 'unbalanced",
            "CLAUDE_CONFIG_DIR=/tmp/other claude",
            "claude \"$MODE\" 'do the work'", "claude \"`mode`\"", "claude --model \"$MODEL\"",
            "claude \"--resume=$ID\"", "claude --session-id \(id) --resume \(id)",
            "claude {--resume,\(id)}", "claude --res*", "claude --resum?", "claude [-]-resume",
        ]
    )
    func opaque(command: String) {
        let plan = AgentLaunchCommand.plan(command: command, newConversationID: { "unused" })
        #expect(plan.command == command)
        #expect(plan.identity == nil)
    }

    @Test("No command is a login shell, with nothing to name")
    func noCommand() {
        #expect(plan(nil) == AgentLaunchCommand.Plan(command: nil, identity: nil))
    }

    @Test("A hash inside a word and a dollar past the start of a prompt do not make a command opaque")
    func notOperators() {
        #expect(plan("claude 'issue #12'").identity != nil)
        #expect(plan("claude fix#12").identity != nil)
        #expect(plan("claude \"fix $PATH handling\"").identity != nil)
        #expect(plan("claude '$MODE stays literal here'").identity != nil)
        #expect(plan("claude 'what is {this} [really] about?'").identity != nil)
        #expect(plan("claude \"\\$MODE is escaped\"").identity != nil)
    }

    @Test("A resume command is built from a validated id and a known effort")
    func resumeCommand() {
        #expect(
            AgentLaunchCommand.claudeResume(conversationID: Self.id, effort: "xhigh")
                == "claude --resume \(Self.id) --effort xhigh"
        )
        #expect(AgentLaunchCommand.claudeResume(conversationID: Self.id, effort: nil) == "claude --resume \(Self.id)")
    }

    @Test("A stored value that is not the right shape never reaches a shell")
    func resumeRejectsBadShapes() {
        #expect(AgentLaunchCommand.claudeResume(conversationID: "x; rm -rf ~;", effort: "low") == nil)
        #expect(
            AgentLaunchCommand.claudeResume(conversationID: Self.id, effort: "low; rm -rf ~")
                == "claude --resume \(Self.id)"
        )
    }
}

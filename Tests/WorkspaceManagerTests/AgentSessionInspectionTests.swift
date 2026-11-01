//
//  AgentSessionInspectionTests.swift
//  WorkspaceManagerTests
//
//  Pins how the three observations become one verdict, and how each is read. A script gates
//  on `verified`, so a false one starts work on a session that is not what it asked for.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Agent session inspection")
struct AgentSessionInspectionTests {
    private static let id = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"
    private static let identity = AgentLaunchIdentity(
        conversationID: id,
        requestedModel: "claude-opus-5-5",
        requestedEffort: "xhigh"
    )
    private static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private static let afterStart = startedAt.addingTimeInterval(30)
    private static let matchingTurn = ClaudeTranscriptTurn(
        model: "claude-opus-5-5",
        effort: "xhigh",
        timestamp: afterStart
    )

    private func verdict(
        sessionLive: Bool = true,
        identity: AgentLaunchIdentity? = identity,
        agentProcesses: Int? = 1,
        blocker: String? = nil,
        inputReady: Bool = true,
        lastTurn: ClaudeTranscriptTurn? = matchingTurn,
        agentStartedAt: Date? = startedAt
    ) -> AgentSessionVerdict {
        AgentSessionInspection.verdict(
            sessionLive: sessionLive,
            identity: identity,
            agentProcesses: agentProcesses,
            blocker: blocker,
            inputReady: inputReady,
            lastTurn: lastTurn,
            agentStartedAt: agentStartedAt
        ).verdict
    }

    @Test("One agent, ready, whose last turn ran as requested is verified")
    func verified() {
        #expect(verdict() == .verified)
    }

    @Test("Requests left to the default are satisfied by whatever ran")
    func defaultsAreNotCompared() {
        let identity = AgentLaunchIdentity(conversationID: Self.id, requestedModel: nil, requestedEffort: nil)
        let turn = ClaudeTranscriptTurn(model: "claude-haiku-5-5", effort: "low", timestamp: Self.afterStart)
        #expect(verdict(identity: identity, lastTurn: turn) == .verified)
    }

    @Test("Each missing piece of evidence keeps the answer at waiting")
    func waiting() {
        #expect(verdict(agentProcesses: 0) == .waiting)
        #expect(verdict(agentProcesses: nil) == .waiting)
        #expect(verdict(inputReady: false) == .waiting)
        #expect(verdict(inputReady: false, lastTurn: nil) == .waiting)
    }

    @Test("An agent that is up and has not taken a turn is ready, and nothing more")
    func ready() {
        #expect(verdict(lastTurn: nil) == .ready)
    }

    @Test("A turn the process before this one took proves nothing about this one")
    func staleTurn() {
        let stale = ClaudeTranscriptTurn(
            model: "claude-opus-5-5",
            effort: "xhigh",
            timestamp: Self.startedAt.addingTimeInterval(-600)
        )
        #expect(verdict(lastTurn: stale) == .ready)

        // Nor does it count against it: the old turn is not a mismatch either.
        let staleAndDifferent = ClaudeTranscriptTurn(
            model: "claude-haiku-5-5",
            effort: "low",
            timestamp: Self.startedAt.addingTimeInterval(-600)
        )
        #expect(verdict(lastTurn: staleAndDifferent) == .ready)
    }

    @Test("A turn with no time, or a process with none, is not evidence")
    func unknownTimes() {
        #expect(verdict(lastTurn: ClaudeTranscriptTurn(model: "claude-opus-5-5", effort: "xhigh")) == .ready)
        #expect(verdict(agentStartedAt: nil) == .ready)
    }

    @Test("A turn from just before the process started is not its own")
    func justBeforeStart() {
        let turn = ClaudeTranscriptTurn(
            model: "claude-opus-5-5",
            effort: "xhigh",
            timestamp: Self.startedAt.addingTimeInterval(-0.5)
        )
        #expect(verdict(lastTurn: turn) == .ready)
    }

    @Test("A session that is gone says so before anything else is weighed")
    func notRunning() {
        #expect(verdict(sessionLive: false) == .notRunning)
        #expect(verdict(sessionLive: false, blocker: "trust-folder") == .notRunning)
    }

    @Test("A prompt outranks everything a live session could still show")
    func blocked() {
        #expect(verdict(blocker: "trust-folder") == .blocked)
        #expect(verdict(identity: nil, blocker: "dialog") == .blocked)
        #expect(verdict(agentProcesses: 0, blocker: "login", lastTurn: nil) == .blocked)
    }

    @Test("A second holder of the conversation is its own answer")
    func duplicate() {
        #expect(verdict(agentProcesses: 2) == .duplicate)
    }

    @Test("A turn on the wrong model or effort is a mismatch, and an unrecorded value is not a match")
    func mismatch() {
        func turn(_ model: String?, _ effort: String?) -> ClaudeTranscriptTurn {
            ClaudeTranscriptTurn(model: model, effort: effort, timestamp: Self.afterStart)
        }
        #expect(verdict(lastTurn: turn("claude-haiku-5-5", "xhigh")) == .mismatch)
        #expect(verdict(lastTurn: turn("claude-opus-5-5", "low")) == .mismatch)
        #expect(verdict(lastTurn: turn("claude-opus-5-5", nil)) == .mismatch)
        #expect(verdict(lastTurn: turn(nil, "xhigh")) == .mismatch)
    }

    @Test("A live session with nothing to compare against says that rather than verified")
    func unverifiable() {
        #expect(verdict(identity: nil) == .unverifiable)
    }

    @Test("The trust prompt as claude draws it is named")
    func trustPrompt() {
        let pane = """
             Accessing workspace:
             /tmp/somewhere
             Quick safety check: Is this a project you created or one you trust?
             Claude Code'll be able to read, edit, and execute files here.
             Security guide
             ❯ No, exit
               Yes, I trust this folder
             Enter to confirm · Esc to cancel
            """
        #expect(AgentSessionInspection.blocker(inPane: pane) == "trust-folder")
    }

    @Test("Any other selection dialog is still a blocker")
    func genericDialog() {
        #expect(AgentSessionInspection.blocker(inPane: "❯ Option one\n  Option two\nEnter to confirm") == "dialog")
    }

    @Test("A conversation quoting a prompt's wording is not blocked by it")
    func quotedPrompt() {
        let pane = """
            ⏺ It showed 'Yes, I trust this folder' and 'Enter to confirm'.
            ────────
            ❯ 
            ────────
              repo main Opus 5.5
              ⏵⏵ auto mode on
            """
        #expect(AgentSessionInspection.blocker(inPane: pane) == nil)
    }

    @Test("The input box is ready when its prompt is on screen, and not before")
    func inputReady() {
        #expect(AgentSessionInspection.inputReady(inPane: "⏺ pong\n────\n❯ \n────\n  repo Haiku 5.5"))
        #expect(AgentSessionInspection.inputReady(inPane: "──── durable-launch ─\n❯ a draft\n────"))
        #expect(!AgentSessionInspection.inputReady(inPane: "Claude Code v2\nloading"))
        var rows = ["────", "❯ an old prompt in scrollback"]
        rows += (0..<12).map { "⏺ output \($0)" }
        #expect(!AgentSessionInspection.inputReady(inPane: rows.joined(separator: "\n")))
    }

    @Test("A dialog's selection cursor is not an input box")
    func dialogCursorIsNotReady() {
        #expect(!AgentSessionInspection.inputReady(inPane: "Security guide\n❯ No, exit\n  Yes\nEnter to confirm"))
    }

    @Test("Only the agent that holds the conversation counts as a process")
    func holders() {
        let id = Self.id
        let listing = """
               05:00 /Users/me/.local/bin/claude --model claude-opus-5-5 --session-id \(id) hello
               05:00 /bin/zsh -lc claude --model claude-opus-5-5 --session-id \(id) hello
               00:01 tmux -L workspaces new-session -d -s x -- /bin/zsh -lc claude --session-id \(id)
               00:01 /bin/bash /hooks/forwarder.sh --session-id \(id)
               03:00 claude --model claude-opus-5-5 mentions \(id) in its prompt
            01:00:30 /bin/sh /tmp/fixture/bin/claude --resume \(id) --effort low
               09:00 claude --session-id 00000000-0000-0000-0000-000000000000
            """
        #expect(AgentSessionInspection.conversationHolders(id, processListing: listing) == [300, 3630])
    }

    @Test("A flag joined to its value holds the conversation like one apart from it")
    func joinedFlags() {
        let id = Self.id
        let listing = """
               00:05 claude --session-id=\(id)
               00:06 claude --resume=\(id)
            """
        #expect(AgentSessionInspection.conversationHolders(id, processListing: listing) == [5, 6])
    }

    @Test("Claude run by an interpreter is a holder, under either name it installs as")
    func interpreterLayouts() {
        let id = Self.id
        let listing = """
               00:05 node /opt/homebrew/bin/claude --resume \(id)
               00:06 node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume \(id)
            """
        #expect(AgentSessionInspection.conversationHolders(id, processListing: listing) == [5, 6])
    }

    @Test("A conversation id past `--` is a prompt, and a program merely naming claude holds nothing")
    func notHolders() {
        let id = Self.id
        let listing = """
               00:05 claude -- --resume \(id)
               00:06 claude --session-id 00000000-0000-0000-0000-000000000000 -- see --resume=\(id)
               00:07 tmux -L workspaces new-session -d -s wm-a-1 claude --session-id \(id)
               00:08 tail -f /tmp/\(id).jsonl
            """
        #expect(AgentSessionInspection.conversationHolders(id, processListing: listing).isEmpty)
    }

    @Test("A short flag names a conversation too, and nothing listed means nothing holds it")
    func holderEdges() {
        let id = Self.id
        #expect(AgentSessionInspection.conversationHolders(id, processListing: "00:09 claude -r \(id)") == [9])
        #expect(AgentSessionInspection.conversationHolders(id, processListing: "").isEmpty)
    }

    @Test(
        "Elapsed time reads in every form ps prints it",
        arguments: [
            ("00:07", 7), ("12:34", 754), ("02:00:01", 7201), ("3-01:00:00", 262_800),
        ] as [(String, Int)]
    )
    func elapsed(text: String, seconds: Int) {
        #expect(AgentSessionInspection.elapsedSeconds(text) == seconds)
    }

    @Test("Text that is not an elapsed time is not one", arguments: ["", "claude", "1", "a:b", "1-2-3:00"])
    func notElapsed(text: String) {
        #expect(AgentSessionInspection.elapsedSeconds(text) == nil)
    }
}

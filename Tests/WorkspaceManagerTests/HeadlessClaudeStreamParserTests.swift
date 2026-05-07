//
//  HeadlessClaudeStreamParserTests.swift
//  WorkspaceManagerTests
//
//  Pure parser tests for the `claude -p --output-format stream-json` NDJSON
//  shape. Fixtures are synthesized to the canonical schema from
//  https://code.claude.com/docs/en/cli — we don't include real captures
//  because that would require running `claude -p` with credentials.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("HeadlessClaudeStreamParser")
struct HeadlessClaudeStreamParserTests {

    @Test("system init line surfaces model + session_id + tools")
    func parsesSystemInit() {
        let line =
            #"{"type":"system","subtype":"init","model":"claude-3-5-sonnet","session_id":"sess-1","tools":["Read","Bash"]}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        guard case .systemInit(let model, let sessionID, let tools) = event else {
            Issue.record("expected systemInit, got \(String(describing: event))")
            return
        }
        #expect(model == "claude-3-5-sonnet")
        #expect(sessionID == "sess-1")
        #expect(tools == ["Read", "Bash"])
    }

    @Test("text_delta inside stream_event yields .textDelta")
    func parsesTextDelta() {
        let line =
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        #expect(event == .textDelta("Hello"))
    }

    @Test("content_block_start with tool_use yields .toolUse")
    func parsesToolUse() {
        let line =
            #"{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/a"}}}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        guard case .toolUse(let name, let inputJSON) = event else {
            Issue.record("expected toolUse, got \(String(describing: event))")
            return
        }
        #expect(name == "Read")
        // JSONSerialization escapes forward slashes as \/, so check for the
        // path piece after the leading slash to keep the test robust.
        #expect(inputJSON?.contains("file_path") == true)
        #expect(inputJSON?.contains("tmp") == true)
    }

    @Test("user message with tool_result yields .toolResult")
    func parsesToolResultString() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"file contents"}]}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        #expect(event == .toolResult(content: "file contents"))
    }

    @Test("user message with structured tool_result blocks concatenates text")
    func parsesToolResultBlocks() {
        let line =
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        #expect(event == .toolResult(content: "line one\nline two"))
    }

    @Test("assistant message text block surfaces as a textDelta for compatibility")
    func parsesAssistantText() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Final answer"}]}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        #expect(event == .textDelta("Final answer"))
    }

    @Test("api retry envelope decodes attempt + delay")
    func parsesApiRetry() {
        let line =
            #"{"type":"stream_event","event":{"type":"api_error_retry","attempt":2,"max_retries":5,"delay_ms":1500,"error_category":"rate_limit"}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        guard case .apiRetry(let attempt, let max, let delay, let category) = event else {
            Issue.record("expected apiRetry, got \(String(describing: event))")
            return
        }
        #expect(attempt == 2)
        #expect(max == 5)
        #expect(delay == 1500)
        #expect(category == "rate_limit")
    }

    @Test("result line decodes cost + duration + session_id")
    func parsesResult() {
        let line =
            #"{"type":"result","result":"all done","total_cost_usd":0.0123,"duration_ms":4242,"num_turns":3,"session_id":"sess-9"}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        guard case .result(let text, let cost, let duration, let turns, let sid) = event else {
            Issue.record("expected result, got \(String(describing: event))")
            return
        }
        #expect(text == "all done")
        #expect(cost == 0.0123)
        #expect(duration == 4242)
        #expect(turns == 3)
        #expect(sid == "sess-9")
    }

    @Test("unrecognized JSON shape surfaces as .unknown carrying the raw line")
    func unknownPassthrough() {
        let line = #"{"type":"future_event_we_have_not_seen","payload":{"x":1}}"#
        let event = HeadlessClaudeStreamParser.parseLine(line)
        guard case .unknown(let raw) = event else {
            Issue.record("expected unknown, got \(String(describing: event))")
            return
        }
        #expect(raw.contains("future_event_we_have_not_seen"))
    }

    @Test("non-JSON line surfaces as .unknown so we never lose data")
    func nonJSONPassthrough() {
        let event = HeadlessClaudeStreamParser.parseLine("oops not json")
        #expect(event == .unknown(raw: "oops not json"))
    }

    @Test("blank lines parse to nil so they don't pollute the event stream")
    func blankLinesSkipped() {
        #expect(HeadlessClaudeStreamParser.parseLine("") == nil)
        #expect(HeadlessClaudeStreamParser.parseLine("   \n") == nil)
    }

    @Test("feed handles partial lines across chunks")
    func partialLineBuffering() {
        var parser = HeadlessClaudeStreamParser()
        let first = parser.feed(#"{"type":"system","subtype":"init","mod"#)
        #expect(first.isEmpty)
        let second = parser.feed("el\":\"x\",\"session_id\":\"s\",\"tools\":[]}\n")
        #expect(second.count == 1)
        guard case .systemInit(let model, let sid, _) = second[0] else {
            Issue.record("expected systemInit")
            return
        }
        #expect(model == "x")
        #expect(sid == "s")
    }

    @Test("flush surfaces a trailing line that lacked a newline")
    func flushTrailing() {
        var parser = HeadlessClaudeStreamParser()
        _ = parser.feed(#"{"type":"result","result":"done","session_id":"z"}"#)
        let trailing = parser.flush()
        #expect(trailing.count == 1)
        if case .result(_, _, _, _, let sid) = trailing[0] {
            #expect(sid == "z")
        } else {
            Issue.record("expected result")
        }
    }
}

//
//  LastCommandStatusTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("LastCommandStatus")
struct LastCommandStatusValueTests {
    @Test("Running status reports isRunning, no duration, no isSuccess")
    func runningInvariants() {
        let started = Date()
        let s = LastCommandStatus.started(commandLine: "ls", at: started)
        #expect(s.isRunning == true)
        #expect(s.endedAt == nil)
        #expect(s.exitCode == nil)
        #expect(s.duration == nil)
        #expect(s.isSuccess == nil)
        #expect(s.commandLine == "ls")
    }

    @Test("ending() transitions a running status and computes duration")
    func endingTransition() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_002.5)
        let running = LastCommandStatus.started(commandLine: "make", at: started)
        let done = running.ending(exitCode: 0, at: ended)
        #expect(done.isRunning == false)
        #expect(done.exitCode == 0)
        #expect(done.isSuccess == true)
        #expect(done.duration == 2.5)
    }

    @Test("Non-zero exit code reports isSuccess == false")
    func failureCase() {
        let s = LastCommandStatus(
            commandLine: "false",
            exitCode: 1,
            startedAt: Date(),
            endedAt: Date()
        )
        #expect(s.isSuccess == false)
    }

    @Test("ending() is a no-op on already-ended status")
    func endingNoOp() {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = Date(timeIntervalSince1970: 1_001)
        let later = Date(timeIntervalSince1970: 1_999)
        let done = LastCommandStatus(
            commandLine: "x", exitCode: 0, startedAt: started, endedAt: ended
        )
        let again = done.ending(exitCode: 1, at: later)
        #expect(again == done)
    }
}

@Suite("CommandMarkerParser")
struct CommandMarkerParserTests {
    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let backslash: UInt8 = 0x5C

    private func seq(_ payload: String, bel terminator: Bool = true) -> Data {
        var d = Data([Self.esc, 0x5D, 0x31, 0x33, 0x33, 0x3B])
        d.append(payload.data(using: .utf8)!)
        if terminator {
            d.append(Self.bel)
        } else {
            d.append(Self.esc)
            d.append(Self.backslash)
        }
        return d
    }

    @Test("Parses a full OSC 133 cycle with BEL terminator")
    func fullCycle() {
        var data = Data()
        data.append(seq("A"))
        data.append("$ ls\n".data(using: .utf8)!)
        data.append(seq("B"))
        data.append(seq("C"))
        data.append("a  b  c\n".data(using: .utf8)!)
        data.append(seq("D;0"))
        let markers = CommandMarkerParser.parse(data)
        #expect(markers == [.promptStart, .commandStart, .outputStart, .commandEnd(exitCode: 0)])
    }

    @Test("ST terminator (ESC \\) is recognised")
    func stTerminator() {
        let data = seq("D;42", bel: false)
        #expect(CommandMarkerParser.parse(data) == [.commandEnd(exitCode: 42)])
    }

    @Test("Command end without exit code parses to nil")
    func endWithoutExit() {
        #expect(CommandMarkerParser.parse(seq("D")) == [.commandEnd(exitCode: nil)])
        #expect(CommandMarkerParser.parse(seq("D;")) == [.commandEnd(exitCode: nil)])
    }

    @Test("Tail key=value after exit code is tolerated")
    func tolerantTail() {
        let data = seq("D;137;err=killed")
        #expect(CommandMarkerParser.parse(data) == [.commandEnd(exitCode: 137)])
    }

    @Test("Plain text without markers yields no events")
    func plainText() {
        let data = "hello world\n".data(using: .utf8)!
        #expect(CommandMarkerParser.parse(data) == [])
    }

    @Test("Unknown marker letters are ignored, surrounding markers still parse")
    func unknownMarker() {
        var data = Data()
        data.append(seq("A"))
        data.append(seq("Z;ignored"))
        data.append(seq("B"))
        let markers = CommandMarkerParser.parse(data)
        #expect(markers == [.promptStart, .commandStart])
    }

    @Test("Markers split across chunks reassemble correctly")
    func splitAcrossChunks() {
        let full = seq("D;0")
        let mid = full.count / 2
        let first = full.prefix(mid)
        let second = full.suffix(from: mid)
        var parser = CommandMarkerParser()
        let firstMarkers = parser.consume(Data(first))
        #expect(firstMarkers == [])
        let secondMarkers = parser.consume(Data(second))
        #expect(secondMarkers == [.commandEnd(exitCode: 0)])
    }

    @Test("Trailing partial introducer is held until next chunk")
    func partialIntroducerHeld() {
        var parser = CommandMarkerParser()
        // Send "noise" + ESC ] 1   (introducer truncated before "33;")
        var chunk = "noise".data(using: .utf8)!
        chunk.append(Data([0x1B, 0x5D, 0x31]))
        let first = parser.consume(chunk)
        #expect(first == [])

        // Now send the rest: "33;B" + BEL.
        var rest = Data([0x33, 0x33, 0x3B])
        rest.append("B".data(using: .utf8)!)
        rest.append(0x07)
        let second = parser.consume(rest)
        #expect(second == [.commandStart])
    }

    @Test("Prompt start prefix tail (A;aid=...) parses as promptStart")
    func promptStartWithTail() {
        let data = seq("A;aid=42;cl=m")
        #expect(CommandMarkerParser.parse(data) == [.promptStart])
    }
}

@MainActor
@Suite("LastCommandStatusRegistry")
struct LastCommandStatusRegistryTests {
    private final class FakeClock: @unchecked Sendable {
        var now: Date
        init(_ start: Date) { self.now = start }
    }

    private func makeRegistry(start: Date = Date(timeIntervalSince1970: 1_000))
        -> (LastCommandStatusRegistry, FakeClock)
    {
        let clock = FakeClock(start)
        let registry = LastCommandStatusRegistry(clock: { clock.now })
        return (registry, clock)
    }

    @Test("Ingesting commandStart publishes a running status")
    func startedThenRunning() {
        let session = UUID()
        let (registry, clock) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "make test")
        let s = registry.statusByTerminalSession[session]
        #expect(s?.isRunning == true)
        #expect(s?.commandLine == "make test")
        #expect(s?.startedAt == clock.now)
    }

    @Test("Start → end with exit 0 records duration and success")
    func startedToSuccess() {
        let session = UUID()
        let (registry, clock) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "ls")
        clock.now = clock.now.addingTimeInterval(1.25)
        registry.ingest(markers: [.commandEnd(exitCode: 0)], for: session)
        let s = registry.statusByTerminalSession[session]
        #expect(s?.isRunning == false)
        #expect(s?.isSuccess == true)
        #expect(s?.duration == 1.25)
    }

    @Test("Start → end with non-zero exit records failure")
    func startedToFailure() {
        let session = UUID()
        let (registry, _) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "false")
        registry.ingest(markers: [.commandEnd(exitCode: 1)], for: session)
        #expect(registry.statusByTerminalSession[session]?.isSuccess == false)
        #expect(registry.statusByTerminalSession[session]?.exitCode == 1)
    }

    @Test("Sequential commands replace the prior status")
    func sequentialCommands() {
        let session = UUID()
        let (registry, clock) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "first")
        registry.ingest(markers: [.commandEnd(exitCode: 0)], for: session)
        clock.now = clock.now.addingTimeInterval(5)
        registry.ingest(markers: [.commandStart], for: session, commandLine: "second")
        let s = registry.statusByTerminalSession[session]
        #expect(s?.commandLine == "second")
        #expect(s?.isRunning == true)
    }

    @Test("promptStart while a previous command is running ends it with nil exit")
    func orphanedRunningClosed() {
        let session = UUID()
        let (registry, clock) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "stray")
        clock.now = clock.now.addingTimeInterval(0.5)
        registry.ingest(markers: [.promptStart], for: session)
        let s = registry.statusByTerminalSession[session]
        #expect(s?.isRunning == false)
        #expect(s?.exitCode == nil)
    }

    @Test("commandEnd without a preceding start records a zero-duration ended status")
    func endWithoutStart() {
        let session = UUID()
        let (registry, _) = makeRegistry()
        registry.ingest(markers: [.commandEnd(exitCode: 0)], for: session)
        let s = registry.statusByTerminalSession[session]
        #expect(s?.isRunning == false)
        #expect(s?.duration == 0)
    }

    @Test("Sessions are tracked independently")
    func sessionsAreIndependent() {
        let a = UUID()
        let b = UUID()
        let (registry, _) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: a, commandLine: "a")
        registry.ingest(markers: [.commandStart, .commandEnd(exitCode: 2)], for: b, commandLine: "b")
        #expect(registry.statusByTerminalSession[a]?.isRunning == true)
        #expect(registry.statusByTerminalSession[b]?.isRunning == false)
        #expect(registry.statusByTerminalSession[b]?.exitCode == 2)
    }

    @Test("clear(terminalSessionID:) drops tracking")
    func clearDrops() {
        let session = UUID()
        let (registry, _) = makeRegistry()
        registry.ingest(markers: [.commandStart], for: session, commandLine: "x")
        registry.clear(terminalSessionID: session)
        #expect(registry.statusByTerminalSession[session] == nil)
    }
}

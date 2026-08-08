//
//  CLIAppProbeTests.swift
//  WorkspaceManagerTests
//
//  Pins the probe's failure taxonomy: which socket error means which outcome, and which
//  outcomes an operator hears about. A probe that misses always falls back to the appless
//  plane; these tests are about it saying which way it missed instead of falling back mute.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLIAppProbe")
struct CLIAppProbeTests {
    typealias ClientError = AutomationSocketClient.ClientError

    @Test(
        "Socket errors classify into the outcome that explains them",
        arguments: [
            (ClientError.connectFailed("/tmp/automation.sock", 61), CLIAppProbe.Outcome.listenerUnreachable),
            (ClientError.socketOpenFailed(24), CLIAppProbe.Outcome.listenerUnreachable),
            (ClientError.socketPathTooLong, CLIAppProbe.Outcome.listenerUnreachable),
            (ClientError.timedOut(0.5), CLIAppProbe.Outcome.timedOut(0.5)),
            (ClientError.invalidHTTPResponse, CLIAppProbe.Outcome.unreadableResponse),
            (ClientError.readFailed(5), CLIAppProbe.Outcome.unreadableResponse),
            (ClientError.writeFailed(32), CLIAppProbe.Outcome.unreadableResponse),
        ]
    )
    func socketErrorClassification(error: ClientError, expected: CLIAppProbe.Outcome) {
        #expect(CLIAppProbe.outcome(forProbeError: error) == expected)
    }

    /// A decode failure, or a refusal envelope the CLI turned into its own error type, reached the
    /// app and came back unusable — the same operator problem as a malformed reply.
    @Test("Non-socket failures read as a reply the CLI could not use")
    func decodeFailureClassification() {
        struct Opaque: Error {}
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        #expect(CLIAppProbe.outcome(forProbeError: Opaque()) == .unreadableResponse)
        #expect(CLIAppProbe.outcome(forProbeError: decoding) == .unreadableResponse)
    }

    @Test("A working probe and an appless machine both stay silent")
    func silentOutcomes() {
        #expect(CLIAppProbe.Outcome.reachable.hint == nil)
        #expect(CLIAppProbe.Outcome.noOperatorCredential(appRunning: false).hint == nil)
    }

    @Test("Every reportable miss produces exactly one distinct line")
    func hintsAreSingleLineAndDistinct() throws {
        let reportable: [CLIAppProbe.Outcome] = [
            .noOperatorCredential(appRunning: true),
            .listenerUnreachable,
            .timedOut(CLIAppProbe.deadline),
            .unreadableResponse,
        ]
        var seen: Set<String> = []
        for outcome in reportable {
            let hint = try #require(outcome.hint)
            #expect(!hint.contains("\n"))
            #expect(hint.hasPrefix("note: "))
            #expect(seen.insert(hint).inserted, "two outcomes share one hint: \(hint)")
        }
    }

    /// The four ways to land on the appless plane are four different operator problems, so the
    /// line names its own cause rather than reporting a generic miss.
    @Test(
        "Each failure outcome names its own cause",
        arguments: [
            (CLIAppProbe.Outcome.noOperatorCredential(appRunning: true), "no operator credential"),
            (CLIAppProbe.Outcome.listenerUnreachable, "nothing is listening"),
            (CLIAppProbe.Outcome.timedOut(0.5), "did not answer the inventory probe within 0.5s"),
            (CLIAppProbe.Outcome.unreadableResponse, "could not be read"),
        ]
    )
    func hintsAreDifferentiated(outcome: CLIAppProbe.Outcome, phrase: String) throws {
        let hint = try #require(outcome.hint)
        #expect(hint.contains(phrase))
    }

    /// Each hint says which plane the output came from, so the line reads as an explanation of
    /// what was printed rather than an error the caller has to act on.
    @Test(
        "Every hint names the plane the output actually came from",
        arguments: [
            (CLIAppProbe.Outcome.listenerUnreachable, "CLI-local plane only"),
            (CLIAppProbe.Outcome.timedOut(0.5), "CLI-local plane only"),
            (CLIAppProbe.Outcome.unreadableResponse, "CLI-local plane only"),
            (
                CLIAppProbe.Outcome.noOperatorCredential(appRunning: true),
                "cannot see the app's repos or workspaces"
            ),
        ]
    )
    func hintsNameTheFallback(outcome: CLIAppProbe.Outcome, phrase: String) throws {
        let hint = try #require(outcome.hint)
        #expect(hint.contains(phrase))
    }

    @Test("The deadline renders the way help prints it")
    func deadlineDescriptionMatchesTheConstant() throws {
        let printed = CLIAppProbe.deadlineDescription
        #expect(printed.hasSuffix("s"))
        let parsed = try #require(Double(printed.dropLast()))
        #expect(parsed == CLIAppProbe.deadline)
    }
}

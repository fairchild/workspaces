//
//  TerminalCommandStatusSliverTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager
import WorkspaceManagerCore

@Suite("TerminalCommandStatusSliver")
struct TerminalCommandStatusSliverPresentationTests {
    @Test("Nil status renders no presentation")
    func nilStatusIsHidden() {
        #expect(TerminalCommandStatusSliverPresentation(status: nil) == nil)
    }

    @Test("Running status without a command uses generic copy")
    func runningWithoutCommand() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let status = LastCommandStatus.started(commandLine: nil, at: started)
        let presentation = try #require(TerminalCommandStatusSliverPresentation(status: status))

        #expect(presentation.primaryText == "Running command...")
        #expect(presentation.secondaryText == nil)
        #expect(presentation.accessibilityLabel == "Running command")
        #expect(presentation.tint == .running)
        #expect(presentation.isRunning == true)
    }

    @Test("Running status with command shows command and running metadata")
    func runningWithCommand() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let status = LastCommandStatus.started(commandLine: " swift test ", at: started)
        let presentation = try #require(TerminalCommandStatusSliverPresentation(status: status))

        #expect(presentation.primaryText == "swift test")
        #expect(presentation.secondaryText == "Running")
        #expect(presentation.accessibilityLabel == "Running command, swift test")
    }

    @Test("Success status without command uses success copy")
    func successWithoutCommand() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(1.2)
        let status = LastCommandStatus(
            commandLine: nil,
            exitCode: 0,
            startedAt: started,
            endedAt: ended
        )
        let presentation = try #require(TerminalCommandStatusSliverPresentation(status: status))

        #expect(presentation.primaryText == "Last command succeeded")
        #expect(presentation.secondaryText == "Exit 0 - 1.2s")
        #expect(presentation.accessibilityLabel == "Last command succeeded, exit code 0, duration 1.2s")
        #expect(presentation.symbolName == "checkmark.circle.fill")
        #expect(presentation.tint == .success)
        #expect(presentation.isRunning == false)
    }

    @Test("Failure status shows command, exit code, and duration")
    func failureWithCommand() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(2.4)
        let status = LastCommandStatus(
            commandLine: "swift test",
            exitCode: 1,
            startedAt: started,
            endedAt: ended
        )
        let presentation = try #require(TerminalCommandStatusSliverPresentation(status: status))

        #expect(presentation.primaryText == "swift test")
        #expect(presentation.secondaryText == "Exited 1 - 2.4s")
        #expect(presentation.accessibilityLabel == "Last command failed, swift test, exit code 1, duration 2.4s")
        #expect(presentation.symbolName == "xmark.circle.fill")
        #expect(presentation.tint == .failure)
    }

    @Test("Completed status with unknown exit code is neutral")
    func unknownExitCode() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        let ended = started.addingTimeInterval(0.4)
        let status = LastCommandStatus(
            commandLine: nil,
            exitCode: nil,
            startedAt: started,
            endedAt: ended
        )
        let presentation = try #require(TerminalCommandStatusSliverPresentation(status: status))

        #expect(presentation.primaryText == "Command finished")
        #expect(presentation.secondaryText == "Finished - <1s")
        #expect(presentation.accessibilityLabel == "Command finished, duration <1s")
        #expect(presentation.tint == .neutral)
    }

    @Test("Duration formatting keeps compact terminal chrome")
    func durationFormatting() {
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 0) == "<1s")
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 0.99) == "<1s")
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 1.24) == "1.2s")
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 9.96) == "10s")
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 12.2) == "12s")
        #expect(TerminalCommandStatusSliverPresentation.durationText(for: 65) == "1m 05s")
    }
}

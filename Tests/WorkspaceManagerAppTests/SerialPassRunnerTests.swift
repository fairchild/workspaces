//
//  SerialPassRunnerTests.swift
//  WorkspaceManagerAppTests
//
//  Two callers overlapping is the case that matters, so the passes here suspend the way a
//  real one does across a scan, and a gate decides when each may finish.
//

import Foundation
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("SerialPassRunner")
struct SerialPassRunnerTests {
    @MainActor
    private final class Log {
        var started = 0
        var running = 0
        var mostRunning = 0
        var mayFinish = false

        func pass() async {
            started += 1
            running += 1
            mostRunning = max(mostRunning, running)
            while !mayFinish {
                await Task.yield()
            }
            running -= 1
        }
    }

    @Test("A request during a pass waits for it, and runs once however many asked")
    func overlappingRequests() async {
        let runner = SerialPassRunner()
        let log = Log()

        let first = Task { await runner.run { await log.pass() } }
        while log.started == 0 {
            await Task.yield()
        }
        await runner.run { await log.pass() }
        await runner.run { await log.pass() }
        #expect(log.started == 1)

        log.mayFinish = true
        await first.value

        #expect(log.started == 2)
        #expect(log.mostRunning == 1)
    }

    @Test("With nothing overlapping, each call is one pass")
    func sequentialRequests() async {
        let runner = SerialPassRunner()
        let log = Log()
        log.mayFinish = true

        await runner.run { await log.pass() }
        await runner.run { await log.pass() }

        #expect(log.started == 2)
    }
}

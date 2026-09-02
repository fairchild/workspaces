//
//  RuntimeProcessMemoryTests.swift
//  WorkspaceManagerTests
//
//  Physical-footprint readings for the Diagnostics pane (#1347 D1): the pane
//  must report what the kernel's resource limits act on, not `ps rss`.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RuntimeProcessMemory")
struct RuntimeProcessMemoryTests {

    @Test("Own process reports a positive physical footprint")
    func ownFootprintPositive() {
        let footprint = RuntimeProcessMemory.physicalFootprint(pid: getpid())
        #expect((footprint ?? 0) > 0)
    }

    @Test("Lifetime max footprint is at least the current footprint")
    func lifetimeMaxAtLeastCurrent() {
        let pid = getpid()
        let current = RuntimeProcessMemory.physicalFootprint(pid: pid) ?? 0
        let lifetimeMax = RuntimeProcessMemory.lifetimeMaxPhysicalFootprint(pid: pid) ?? 0
        #expect(lifetimeMax >= current)
        #expect(lifetimeMax > 0)
    }

    @Test("A sample carries the kernel footprint, not a resident-size stand-in")
    func sampleCarriesFootprint() {
        let entry = ProcessInventoryEntry(
            pid: 100,
            parentPID: 1,
            uid: 501,
            name: "claude",
            cpuTimeSeconds: 30,
            footprintBytes: 8_192,
            elapsedSeconds: 60,
            currentDirectory: "/Users/fairchild/code",
            commandLine: "claude --continue"
        )

        let sample = LiveRuntimeProcessSnapshotProvider.sample(from: entry)

        #expect(sample.residentMemoryBytes == 8_192)
        #expect(sample.command == "claude --continue")
        #expect(sample.cpuPercent == 50)
    }

    @Test("A pid outside the kernel's range reads as nil, not zero")
    func outOfRangePIDReadsNil() {
        // `Int32.max` is above `PID_MAX`, so nothing can hold it and this never
        // skips itself.
        #expect(RuntimeProcessMemory.physicalFootprint(pid: Int32.max) == nil)
        #expect(RuntimeProcessMemory.lifetimeMaxPhysicalFootprint(pid: Int32.max) == nil)
    }
}

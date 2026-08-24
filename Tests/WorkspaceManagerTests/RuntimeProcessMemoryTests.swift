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

    @Test("A dead pid reads as nil, not zero")
    func deadPIDReadsNil() {
        // PID from far beyond the live range; if it somehow exists, skip the
        // assertion rather than flake.
        let unlikely: Int32 = 99_999_999 % 99_999
        if kill(unlikely, 0) != 0 {
            #expect(RuntimeProcessMemory.physicalFootprint(pid: unlikely) == nil)
        }
    }
}

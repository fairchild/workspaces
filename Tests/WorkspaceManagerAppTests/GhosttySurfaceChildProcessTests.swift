//
//  GhosttySurfaceChildProcessTests.swift
//  WorkspaceManagerAppTests
//
//  A retired surface is freed once its command is gone, and libghostty's teardown then signals
//  whatever group the recorded pid leads. These cases pin down when a process that has the
//  pid now is still the command found earlier, from synthetic process records.
//

import Darwin
import Testing

@testable import WorkspaceManager

@Suite("GhosttySurfaceChildProcess command identity")
struct GhosttySurfaceChildProcessTests {
    private static let parent: pid_t = 4000
    private static let command = GhosttySurfaceChildProcess.Command(
        pid: 4100, started: timeval(tv_sec: 1_700_000_000, tv_usec: 250))

    @Test("No process with the pid means the command is gone")
    func gone() {
        #expect(GhosttySurfaceChildProcess.fate(of: Self.command, given: nil, parent: Self.parent) == .gone)
    }

    @Test("The same pid, start time and parent is the command, running or exited")
    func same() {
        let running = Self.process(started: timeval(tv_sec: 1_700_000_000, tv_usec: 250))
        let exited = Self.process(started: timeval(tv_sec: 1_700_000_000, tv_usec: 250), status: SZOMB)
        #expect(GhosttySurfaceChildProcess.fate(of: Self.command, given: running, parent: Self.parent) == .running)
        #expect(GhosttySurfaceChildProcess.fate(of: Self.command, given: exited, parent: Self.parent) == .exited)
    }

    @Test("The pid with another start time is a later process")
    func reusedLater() {
        let later = Self.process(started: timeval(tv_sec: 1_700_000_042, tv_usec: 250))
        let laterInTheSameSecond = Self.process(started: timeval(tv_sec: 1_700_000_000, tv_usec: 900))
        #expect(GhosttySurfaceChildProcess.fate(of: Self.command, given: later, parent: Self.parent) == .replaced)
        #expect(
            GhosttySurfaceChildProcess.fate(of: Self.command, given: laterInTheSameSecond, parent: Self.parent)
                == .replaced)
    }

    @Test("The pid under another parent is not this process's command")
    func anotherParent() {
        let adopted = Self.process(started: timeval(tv_sec: 1_700_000_000, tv_usec: 250), parent: 1)
        #expect(GhosttySurfaceChildProcess.fate(of: Self.command, given: adopted, parent: Self.parent) == .replaced)
    }

    private static func process(started: timeval, parent: pid_t = parent, status: Int32 = SRUN) -> kinfo_proc {
        var info = kinfo_proc()
        info.kp_proc.p_pid = command.pid
        info.kp_proc.p_starttime = started
        info.kp_proc.p_stat = CChar(status)
        info.kp_eproc.e_ppid = parent
        return info
    }
}

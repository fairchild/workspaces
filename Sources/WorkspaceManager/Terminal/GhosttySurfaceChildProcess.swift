//
//  GhosttySurfaceChildProcess.swift
//  WorkspaceManager
//
//  The process libghostty spawned for a surface, and the signals that end it. Freeing a
//  surface joins its io thread, which sends that process group SIGHUP and polls every 10 ms
//  until the process is gone. Ending it before the free lets the free find it gone.
//

import Darwin
import GhosttyKit

enum GhosttySurfaceChildProcess {
    /// A process for its whole lifetime. A pid alone can name a later process once the first
    /// is reaped, so the start time travels with it.
    struct Command: Equatable, Sendable {
        let pid: pid_t
        let startSeconds: Int
        let startMicroseconds: Int32

        init(pid: pid_t, started: timeval) {
            self.pid = pid
            startSeconds = started.tv_sec
            startMicroseconds = started.tv_usec
        }
    }

    /// What a question to the kernel's process table established. A query that failed says
    /// nothing about whether the process exists.
    enum Query<Value> {
        case found(Value)
        case absent
        case failed(errno: Int32)

        var value: Value? {
            if case .found(let value) = self { value } else { nil }
        }

        func flatMap<Other>(_ transform: (Value) -> Query<Other>) -> Query<Other> {
            switch self {
            case .found(let value): transform(value)
            case .absent: .absent
            case .failed(let errno): .failed(errno: errno)
            }
        }
    }

    /// The process table these lookups read: the kernel's, or a stand-in under test.
    struct ProcessTable: Sendable {
        var process: @Sendable (pid_t) -> Query<kinfo_proc>
        var members: @Sendable (_ group: pid_t) -> Query<[pid_t]>

        static let system = ProcessTable(
            process: { GhosttySurfaceChildProcess.processInfo($0) },
            members: { GhosttySurfaceChildProcess.members(ofGroup: $0) })
    }

    /// What became of a `Command` since it was found.
    enum Fate: Equatable {
        /// Still this process's child, and not yet exited.
        case running
        /// Exited, and not yet reaped.
        case exited
        /// Reaped: no process has its pid.
        case gone
        /// Reaped, and its pid now names another process.
        case replaced
        /// The process table could not be read, so nothing is known.
        case unavailable
    }

    /// libghostty starts each surface's command in a new session on the surface's pty, so the
    /// session of whatever runs in the foreground there is that command's pid. The foreground
    /// is a process group whose leader may have exited while the rest of it runs on, as in
    /// `sleep 1 | less`, so the session comes from any live member. `absent` unless that pid is
    /// a child of this process at the instant of the check.
    @MainActor
    static func command(of surface: ghostty_surface_t, in table: ProcessTable = .system) -> Query<Command> {
        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard foreground > 0 else { return .absent }
        return table.members(foreground).flatMap { members in
            guard let leader = members.lazy.map(getsid).first(where: { $0 > 0 }) else { return .absent }
            return table.process(leader).flatMap { info in
                info.kp_eproc.e_ppid == getpid()
                    ? .found(Command(pid: leader, started: info.kp_proc.p_starttime)) : .absent
            }
        }
    }

    @MainActor
    static func pid(of surface: ghostty_surface_t) -> pid_t? {
        command(of: surface).value?.pid
    }

    /// Sends `signal` to the command's process group, the group libghostty's own teardown
    /// hangs up, and returns what the lookup found. Nothing is sent unless it found the
    /// command. Delivery is best effort: on Darwin `killpg` can fail with EPERM for a group it
    /// partly reached, which libghostty's teardown ignores too.
    @MainActor
    @discardableResult
    static func send(
        _ signal: Int32, to surface: ghostty_surface_t, in table: ProcessTable = .system
    )
        -> Query<Command>
    {
        let lookup = command(of: surface, in: table)
        if let command = lookup.value { killpg(command.pid, signal) }
        return lookup
    }

    static func fate(of command: Command, in table: ProcessTable = .system) -> Fate {
        fate(of: command, given: table.process(command.pid), parent: getpid())
    }

    /// `query` asked for whatever process has `command`'s pid now. Only a query that succeeded
    /// and found no such process means `gone`.
    static func fate(of command: Command, given query: Query<kinfo_proc>, parent: pid_t) -> Fate {
        switch query {
        case .failed: return .unavailable
        case .absent: return .gone
        case .found(let info):
            guard Command(pid: info.kp_proc.p_pid, started: info.kp_proc.p_starttime) == command,
                info.kp_eproc.e_ppid == parent
            else { return .replaced }
            return info.kp_proc.p_stat == SZOMB ? .exited : .running
        }
    }

    private static func members(ofGroup group: pid_t) -> Query<[pid_t]> {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0 else { return failure() }
        guard size > 0 else { return .absent }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
        size = processes.count * stride
        guard sysctl(&name, u_int(name.count), &processes, &size, nil, 0) == 0 else { return failure() }
        let members = processes.prefix(size / stride).map(\.kp_proc.p_pid)
        return members.isEmpty ? .absent : .found(members)
    }

    private static func processInfo(_ pid: pid_t) -> Query<kinfo_proc> {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return failure() }
        return size > 0 ? .found(info) : .absent
    }

    /// A `sysctl` that failed with ESRCH looked and found no such process; any other error
    /// means it could not look.
    private static func failure<Value>() -> Query<Value> {
        let error = errno
        return error == ESRCH ? .absent : .failed(errno: error)
    }
}

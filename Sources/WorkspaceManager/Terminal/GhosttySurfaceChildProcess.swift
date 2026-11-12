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
    struct Command: Equatable {
        let pid: pid_t
        let startSeconds: Int
        let startMicroseconds: Int32

        init(pid: pid_t, started: timeval) {
            self.pid = pid
            startSeconds = started.tv_sec
            startMicroseconds = started.tv_usec
        }
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
    }

    /// libghostty starts each surface's command in a new session on the surface's pty, so the
    /// session of whatever runs in the foreground there is that command's pid. The foreground
    /// is a process group whose leader may have exited while the rest of it runs on, as in
    /// `sleep 1 | less`, so the session comes from any live member. `nil` unless that pid is a
    /// child of this process at the instant of the check.
    @MainActor
    static func command(of surface: ghostty_surface_t) -> Command? {
        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard foreground > 0,
            let leader = members(ofGroup: foreground).lazy.map(getsid).first(where: { $0 > 0 }),
            let info = processInfo(leader), info.kp_eproc.e_ppid == getpid()
        else { return nil }
        return Command(pid: leader, started: info.kp_proc.p_starttime)
    }

    @MainActor
    static func pid(of surface: ghostty_surface_t) -> pid_t? {
        command(of: surface)?.pid
    }

    /// Sends `signal` to the command's process group, the group libghostty's own teardown
    /// hangs up, and returns the command it found. `nil`, sending nothing, before the command
    /// has a pid on the pty or once it has exited. Delivery is best effort: on Darwin `killpg`
    /// can fail with EPERM for a group it partly reached, which libghostty's teardown ignores
    /// too.
    @MainActor
    @discardableResult
    static func send(_ signal: Int32, to surface: ghostty_surface_t) -> Command? {
        guard let command = command(of: surface) else { return nil }
        killpg(command.pid, signal)
        return command
    }

    static func fate(of command: Command) -> Fate {
        fate(of: command, given: processInfo(command.pid), parent: getpid())
    }

    /// `info` describes whatever process has `command`'s pid now, if any.
    static func fate(of command: Command, given info: kinfo_proc?, parent: pid_t) -> Fate {
        guard let info else { return .gone }
        guard Command(pid: info.kp_proc.p_pid, started: info.kp_proc.p_starttime) == command,
            info.kp_eproc.e_ppid == parent
        else { return .replaced }
        return info.kp_proc.p_stat == SZOMB ? .exited : .running
    }

    private static func members(ofGroup group: pid_t) -> [pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, group]
        var size = 0
        guard sysctl(&name, u_int(name.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
        size = processes.count * stride
        guard sysctl(&name, u_int(name.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride).map(\.kp_proc.p_pid)
    }

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

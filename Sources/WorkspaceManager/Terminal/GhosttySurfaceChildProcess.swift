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
    /// libghostty starts each surface's command in a new session on the surface's pty, so the
    /// session of whatever runs in the foreground there is that command's pid. The foreground
    /// is a process group whose leader may have exited while the rest of it runs on, as in
    /// `sleep 1 | less`, so the session comes from any live member. `nil` unless that pid is a
    /// child of this process at the instant of the check.
    @MainActor
    static func pid(of surface: ghostty_surface_t) -> pid_t? {
        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard foreground > 0,
            let leader = members(ofGroup: foreground).lazy.map(getsid).first(where: { $0 > 0 }),
            parentPID(of: leader) == getpid()
        else { return nil }
        return leader
    }

    /// Sends `signal` to the command's process group, the group libghostty's own teardown
    /// hangs up. Does nothing before the command has a pid on the pty, or once it has exited.
    @MainActor
    static func send(_ signal: Int32, to surface: ghostty_surface_t) {
        guard let pid = pid(of: surface) else { return }
        _ = killpg(pid, signal)
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

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

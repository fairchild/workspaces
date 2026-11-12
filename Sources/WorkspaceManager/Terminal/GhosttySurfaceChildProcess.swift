//
//  GhosttySurfaceChildProcess.swift
//  WorkspaceManager
//
//  The process libghostty spawned for a surface, and the hang-up that ends it. Freeing a
//  surface joins its io thread, which sends that process group SIGHUP and polls every 10 ms
//  until the process is gone. Hanging up before the free lets the free find it gone.
//

import Darwin
import GhosttyKit

enum GhosttySurfaceChildProcess {
    /// libghostty starts each surface's command in a new session on the surface's pty, so the
    /// session of whatever runs in the foreground there is that command's pid. `nil` unless
    /// that pid is still a child of this process, so a hang-up never reaches anyone else.
    @MainActor
    static func pid(of surface: ghostty_surface_t) -> pid_t? {
        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        guard foreground > 0 else { return nil }
        let leader = getsid(foreground)
        guard leader > 0, parentPID(of: leader) == getpid() else { return nil }
        return leader
    }

    /// The signal libghostty's own teardown sends, to the same process group. Does nothing
    /// before the command has a pid on the pty, or once it has exited.
    @MainActor
    static func hangUp(_ surface: ghostty_surface_t) {
        guard let pid = pid(of: surface) else { return }
        _ = killpg(pid, SIGHUP)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

//
//  OpenFiles.swift
//  WorkspaceManagerTests
//
//  Which files a process holds open, from the kernel: tests wait on it to know a process has
//  reached a lock, where a sleep would only guess.
//

import Darwin

enum OpenFiles {
    static func paths(of pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard filled > 0 else { return [] }
        return descriptors.prefix(Int(filled) / stride)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) }
            .compactMap { descriptor in
                var info = vnode_fdinfowithpath()
                let length = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, length) == length
                else { return nil }
                return withUnsafeBytes(of: info.pvip.vip_path) {
                    $0.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
                }
            }
    }
}

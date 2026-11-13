//
//  ProcessInspector.swift
//  WorkspaceManagerCore
//
//  Reads one process from the kernel: when it started, its parent, and its arguments. A pid
//  is reused once its process ends; a pid with the start time it had when it was recorded is
//  one process lifetime, which is what lets a record name a holder that later checks can
//  trust. `sysctl` rather than `ps`, so the SessionStart hook can afford it.
//

import Darwin
import Foundation

/// One process lifetime: a pid and the moment that process started, to the microsecond.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    /// Microseconds since 1970, as the kernel keeps it.
    public let startedAtMicroseconds: Int64

    public init(pid: Int32, startedAtMicroseconds: Int64) {
        self.pid = pid
        self.startedAtMicroseconds = startedAtMicroseconds
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(startedAtMicroseconds) / 1_000_000)
    }

    /// `<pid>@<microseconds>`: one string, so a record keeps the two together.
    public var recorded: String { "\(pid)@\(startedAtMicroseconds)" }

    public init?(recorded: String) {
        let parts = recorded.split(separator: "@")
        guard parts.count == 2, let pid = Int32(parts[0]), let started = Int64(parts[1]) else { return nil }
        self.init(pid: pid, startedAtMicroseconds: started)
    }
}

/// What the kernel said about a pid: a process and when it started, no process at all, or
/// nothing, because it could not be asked. Only the first two are answers. A process that has
/// exited and waits for its parent to collect it is absent: its pid is taken, but nothing runs.
public enum ProcessRead: Equatable, Sendable {
    case found(ProcessIdentity)
    case absent
    case unreadable
}

/// Whether a recorded process lifetime is still running, from one kernel read.
public enum ProcessLiveness: Equatable, Sendable {
    case running
    /// It exited, and its pid is free, uncollected, or belongs to a later process.
    case ended
    /// The kernel could not be asked, so neither of the others can be ruled out.
    case unreadable
}

/// Seams over the kernel's process table, so a probe's answers are reachable without the
/// processes it reasons about.
public struct ProcessInspector: Sendable {
    public var read: @Sendable (Int32) -> ProcessRead
    public var parent: @Sendable (Int32) -> Int32?
    public var arguments: @Sendable (Int32) -> [String]?

    public init(
        read: @escaping @Sendable (Int32) -> ProcessRead,
        parent: @escaping @Sendable (Int32) -> Int32?,
        arguments: @escaping @Sendable (Int32) -> [String]?
    ) {
        self.read = read
        self.parent = parent
        self.arguments = arguments
    }

    /// An inspector whose kernel always answers: a pid `identity` does not know is absent.
    public init(
        identity: @escaping @Sendable (Int32) -> ProcessIdentity?,
        parent: @escaping @Sendable (Int32) -> Int32?,
        arguments: @escaping @Sendable (Int32) -> [String]?
    ) {
        self.init(read: { identity($0).map(ProcessRead.found) ?? .absent }, parent: parent, arguments: arguments)
    }

    public static let live = ProcessInspector(
        read: { pid in
            switch info(pid) {
            case .failure: return .unreadable
            case .success(nil): return .absent
            case .success(let process?) where Int32(process.kp_proc.p_stat) == SZOMB: return .absent
            case .success(let process?):
                let start = process.kp_proc.p_un.__p_starttime
                return .found(
                    ProcessIdentity(
                        pid: pid,
                        startedAtMicroseconds: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
                    ))
            }
        },
        parent: { pid in (try? info(pid).get())?.kp_eproc.e_ppid },
        arguments: { pid in processArguments(pid) }
    )

    /// The process at `pid` now, or nil when there is none or the kernel could not say.
    public func identity(_ pid: Int32) -> ProcessIdentity? {
        guard case .found(let identity) = read(pid) else { return nil }
        return identity
    }

    public func liveness(_ identity: ProcessIdentity) -> ProcessLiveness {
        switch read(identity.pid) {
        case .found(let now): now == identity ? .running : .ended
        case .absent: .ended
        case .unreadable: .unreadable
        }
    }

    /// Whether `identity` is still the process it was: alive, and started when it did.
    public func isRunning(_ identity: ProcessIdentity) -> Bool {
        liveness(identity) == .running
    }

    struct KernelError: Error {
        let code: Int32
    }

    /// `KERN_PROC_PID` answers a pid with no process by returning nothing, and fails only when
    /// it could not look.
    private static func info(_ pid: Int32) -> Result<kinfo_proc?, KernelError> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0 else {
            return .failure(KernelError(code: errno))
        }
        return .success(size > 0 ? process : nil)
    }

    /// `KERN_PROCARGS2`: an argument count, the executable path, padding, then the arguments.
    private static func processArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let count = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var words: [String] = []
        while words.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            words.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return words.count == count ? words : nil
    }
}

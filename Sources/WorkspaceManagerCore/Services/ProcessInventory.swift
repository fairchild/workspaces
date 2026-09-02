//
//  ProcessInventory.swift
//  WorkspaceManagerCore
//
//  Reads the live process table through `libproc` and `sysctl` instead of
//  spawning `ps` and `lsof` (#1368). Every entry point here is a syscall the
//  calling thread makes itself, so the sampling path forks nothing and the
//  sampler is cheap enough to run always rather than only while the
//  Diagnostics pane is open.
//

import Darwin
import Foundation

/// One process as the kernel describes it, before any WorkSpaces scoping.
public struct ProcessInventoryEntry: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: uid_t
    /// Short accounting name (`p_comm`), truncated by the kernel to 16 bytes.
    public let name: String
    /// Kernel task time, user plus system.
    public let cpuTimeSeconds: TimeInterval
    /// `ri_phys_footprint` when readable, else the task's resident size.
    public let footprintBytes: Int64
    /// Wall seconds since the process started, from its recorded start time.
    public let elapsedSeconds: TimeInterval
    /// When the kernel recorded this process starting. Together with the pid it
    /// identifies a process across samples, which a pid alone cannot: pids are
    /// reused, and a reused one must not inherit a stranger's history or a
    /// stranger's stop signal.
    public let startedAt: Date
    /// Working directory, filled only for processes the caller may inspect.
    public let currentDirectory: String?
    /// Full argument vector, filled only for processes the caller may inspect.
    public let commandLine: String?

    public init(
        pid: Int32,
        parentPID: Int32,
        uid: uid_t,
        name: String,
        cpuTimeSeconds: TimeInterval,
        footprintBytes: Int64,
        elapsedSeconds: TimeInterval,
        startedAt: Date = Date(timeIntervalSince1970: 0),
        currentDirectory: String? = nil,
        commandLine: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.cpuTimeSeconds = cpuTimeSeconds
        self.footprintBytes = footprintBytes
        self.elapsedSeconds = elapsedSeconds
        self.startedAt = startedAt
        self.currentDirectory = currentDirectory
        self.commandLine = commandLine
    }

    func addingDetail(currentDirectory: String?, commandLine: String?) -> ProcessInventoryEntry {
        ProcessInventoryEntry(
            pid: pid,
            parentPID: parentPID,
            uid: uid,
            name: name,
            cpuTimeSeconds: cpuTimeSeconds,
            footprintBytes: footprintBytes,
            elapsedSeconds: elapsedSeconds,
            startedAt: startedAt,
            currentDirectory: currentDirectory,
            commandLine: commandLine
        )
    }

    /// Share of one core this process has averaged over its life. `ps`'s own
    /// `%cpu` is a decaying scheduler average; this is the honest long-run
    /// figure, and it is the one a runaway is judged on.
    public var lifetimeCPUPercent: Double {
        guard elapsedSeconds > 0 else { return 0 }
        return (cpuTimeSeconds / elapsedSeconds) * 100
    }
}

/// Shell-out-free reads of the live process table.
///
/// Every call is a direct syscall. `hostSnapshot` is the whole sweep and is
/// what the sampler uses; the narrower entry points exist so tests can pin one
/// behaviour at a time.
public enum ProcessInventory {

    // MARK: - Enumeration

    /// Every pid the caller can see, via `proc_listallpids`.
    public static func allPIDs() -> [Int32] {
        listPIDs { buffer, size in
            proc_listallpids(buffer, size)
        }
    }

    /// Direct children of `pid`, via `proc_listchildpids`.
    public static func childPIDs(of pid: Int32) -> [Int32] {
        listPIDs { buffer, size in
            proc_listchildpids(pid, buffer, size)
        }
    }

    /// `pid` and every descendant beneath it, walked with `proc_listchildpids`.
    ///
    /// Cycles are impossible in a pid tree, but a pid recycled mid-walk could
    /// re-enter it, so visited pids are recorded rather than assumed unique.
    public static func descendantPIDs(of pid: Int32, limit: Int = 4_096) -> [Int32] {
        var visited: Set<Int32> = []
        var ordered: [Int32] = []
        var stack = [pid]

        while let next = stack.popLast(), ordered.count < limit {
            guard visited.insert(next).inserted else { continue }
            ordered.append(next)
            stack.append(contentsOf: childPIDs(of: next))
        }

        return ordered
    }

    /// Slots the enumeration starts with, and the ceiling it will grow to. A Mac
    /// under heavy agent load sits near 1,100 processes; the ceiling is there so a
    /// pathological table cannot turn one sample into an unbounded allocation.
    static let initialPIDCapacity = 2_048
    static let maximumPIDCapacity = 65_536

    /// Runs a `proc_list*pids` call into a buffer that grows until it stops
    /// coming back saturated.
    ///
    /// The return value's unit is the trap here. On Darwin 25 both the sizing
    /// call and the fill call answer in **pids**, while `libproc.h` documents
    /// bytes — and reading a count as bytes silently truncates the sweep to a
    /// quarter of the table, which is a wrong answer that still looks like a
    /// process list. Both readings are therefore honoured: a value that fits
    /// inside the slot count is a count, anything larger is a byte count.
    private static func listPIDs(
        _ call: (UnsafeMutableRawPointer?, Int32) -> Int32
    ) -> [Int32] {
        var capacity = initialPIDCapacity

        while true {
            var pids = [Int32](repeating: 0, count: capacity)
            let returned = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
                call(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.size))
            }
            guard returned > 0 else { return [] }

            let written =
                Int(returned) <= capacity
                ? Int(returned)
                : min(Int(returned) / MemoryLayout<Int32>.size, capacity)

            if written >= capacity, capacity < maximumPIDCapacity {
                capacity = min(capacity * 4, maximumPIDCapacity)
                continue
            }

            return pids.prefix(written).filter { $0 > 0 }
        }
    }

    // MARK: - The sweep

    /// Every visible process, with working directory and argument vector filled
    /// in for the ones the caller owns.
    ///
    /// The cheap reads run for every pid; the two expensive ones — the vnode
    /// path walk and the argument-area copy — run only where they can succeed,
    /// which is the caller's own uid. That restriction is not a shortcut: the
    /// kernel refuses both for other users, which is exactly why the `lsof` this
    /// replaces never saw them either.
    public static func hostSnapshot(
        now: Date = Date(),
        detailUID: uid_t? = getuid(),
        pids: [Int32]? = nil
    ) -> [ProcessInventoryEntry] {
        // One argument-area buffer for the whole sweep. `KERN_ARGMAX` is a
        // megabyte on macOS, and allocating that per process turned a 20 ms
        // sweep into a 1.7 s one that churned 65 MB — in a sampler whose subject
        // is memory.
        let argumentBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: argumentAreaMaximum)
        defer { argumentBuffer.deallocate() }

        return (pids ?? allPIDs()).compactMap { pid in
            guard let entry = entry(pid: pid, now: now) else { return nil }
            guard let detailUID, entry.uid == detailUID else { return entry }
            return entry.addingDetail(
                currentDirectory: currentDirectory(pid: pid),
                commandLine: commandLine(pid: pid, buffer: argumentBuffer, capacity: argumentAreaMaximum)
            )
        }
    }

    // MARK: - Per-process reads

    /// BSD and task info for `pid` in one `proc_pidinfo(PROC_PIDTASKALLINFO)`
    /// call. Returns nil when the pid is gone or belongs to another user
    /// without inspection rights.
    public static func entry(
        pid: Int32,
        now: Date = Date(),
        footprintReader: (Int32) -> Int64? = RuntimeProcessMemory.physicalFootprint(pid:)
    ) -> ProcessInventoryEntry? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, size)
        }
        guard read == size else { return nil }

        let cpuNanoseconds = Double(info.ptinfo.pti_total_user) + Double(info.ptinfo.pti_total_system)
        let startedAt = Date(
            timeIntervalSince1970: Double(info.pbsd.pbi_start_tvsec)
                + Double(info.pbsd.pbi_start_tvusec) / 1_000_000
        )
        let residentBytes = Int64(clamping: info.ptinfo.pti_resident_size)

        return ProcessInventoryEntry(
            pid: pid,
            parentPID: Int32(bitPattern: info.pbsd.pbi_ppid),
            uid: info.pbsd.pbi_uid,
            name: comm(from: info.pbsd),
            cpuTimeSeconds: cpuNanoseconds / 1_000_000_000,
            footprintBytes: footprintReader(pid) ?? residentBytes,
            elapsedSeconds: max(0, now.timeIntervalSince(startedAt)),
            startedAt: startedAt
        )
    }

    /// Working directory of `pid`, via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` —
    /// the syscall `lsof -d cwd` was being spawned for. Same-user processes
    /// only; anything else reads as nil rather than failing the sweep.
    public static func currentDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, size)
        }
        guard read == size else { return nil }

        return withUnsafePointer(to: info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { pointer in
                let path = String(cString: pointer)
                return path.isEmpty ? nil : path
            }
        }
    }

    /// Absolute executable path for `pid`, via `proc_pidpath`.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Full argument vector for `pid`, via `sysctl(KERN_PROCARGS2)` — the same
    /// source `ps -o args` reads, without the fork. Restricted by the kernel to
    /// the caller's own uid, so other users' processes read as nil.
    ///
    /// Allocates its own buffer. The sweep passes a shared one instead.
    public static func commandLine(pid: Int32) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: argumentAreaMaximum)
        defer { buffer.deallocate() }
        return commandLine(pid: pid, buffer: buffer, capacity: argumentAreaMaximum)
    }

    static func commandLine(
        pid: Int32,
        buffer: UnsafeMutablePointer<CChar>,
        capacity: Int
    ) -> String? {
        guard capacity > MemoryLayout<Int32>.size else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = capacity

        let result = sysctl(&mib, UInt32(mib.count), buffer, &length, nil, 0)
        guard result == 0, length > MemoryLayout<Int32>.size else { return nil }

        return parseArgumentArea(
            bytes: UnsafeBufferPointer(start: buffer, count: min(length, capacity))
        )
    }

    /// `KERN_ARGMAX`, read once. Bounds the `KERN_PROCARGS2` buffer so a single
    /// enormous argument area cannot be asked for repeatedly.
    public static let argumentAreaMaximum: Int = {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), &value, &length, nil, 0) == 0, value > 0 else {
            return 256 * 1_024
        }
        return Int(value)
    }()

    /// Decodes a `KERN_PROCARGS2` area.
    ///
    /// Layout, in order: an `Int32` argument count, the executable path, a run
    /// of NUL padding, then exactly `argc` NUL-terminated arguments, then the
    /// environment. The padding is the part worth naming — it is a run of empty
    /// fields between the path and `argv[0]`, and a parser that treats the first
    /// one as a terminator returns the path and none of the arguments.
    static func parseArgumentArea(bytes: UnsafeBufferPointer<CChar>) -> String? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }

        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            let source = UnsafeRawBufferPointer(bytes)
            destination.copyMemory(
                from: UnsafeRawBufferPointer(rebasing: source[0..<MemoryLayout<Int32>.size])
            )
        }
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size

        func readCString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let end = index
            if index < bytes.count { index += 1 }
            guard end > start else { return "" }
            let scalars = (start..<end).map { UInt8(bitPattern: bytes[$0]) }
            return String(decoding: scalars, as: UTF8.self)
        }

        guard let executablePath = readCString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var argv: [String] = []
        for _ in 0..<Int(argumentCount) {
            guard let argument = readCString() else { break }
            argv.append(argument)
        }

        let joined = argv.isEmpty ? executablePath : argv.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func comm(from info: proc_bsdinfo) -> String {
        var name = withUnsafePointer(to: info.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        if name.isEmpty {
            name = withUnsafePointer(to: info.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
        }
        return name
    }
}

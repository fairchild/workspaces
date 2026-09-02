//
//  ProcessInventoryTests.swift
//  WorkspaceManagerTests
//
//  Proves the sampling path reads the process table without forking (#1368):
//  the sweep sees the live machine, and the kernel's own child-resource
//  accounting stays untouched while it does.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ProcessInventory")
struct ProcessInventoryTests {

    @Test("Enumerates the whole process table, not a truncated prefix")
    func enumeratesWholeTable() {
        let pids = ProcessInventory.allPIDs()

        // A live Mac never runs a handful of processes. The specific trap this
        // guards is a sizing call whose unit is misread: taking a pid count as a
        // byte count truncates the sweep to a quarter of the table and still
        // returns a plausible-looking list.
        #expect(pids.count > 40)
        #expect(pids.contains(getpid()))
        #expect(pids.allSatisfy { $0 > 0 })
        #expect(Set(pids).count == pids.count)
    }

    @Test("Reads own pid: parent, name, footprint, and elapsed time")
    func readsOwnEntry() {
        let entry = ProcessInventory.entry(pid: getpid())

        #expect(entry != nil)
        #expect(entry?.pid == getpid())
        #expect(entry?.parentPID == getppid())
        #expect(entry?.uid == getuid())
        #expect((entry?.footprintBytes ?? 0) > 0)
        #expect((entry?.elapsedSeconds ?? -1) >= 0)
        #expect(entry?.name.isEmpty == false)
    }

    @Test("Reads own working directory without lsof")
    func readsOwnWorkingDirectory() {
        let cwd = ProcessInventory.currentDirectory(pid: getpid())

        #expect(cwd != nil)
        #expect(
            cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .resolvingSymlinksInPath().path
        )
    }

    @Test("Reads own argument vector without ps")
    func readsOwnCommandLine() {
        let command = ProcessInventory.commandLine(pid: getpid())

        #expect(command?.isEmpty == false)
    }

    @Test("Descendant walk includes the root and stops at unrelated processes")
    func descendantWalkIncludesRoot() {
        let descendants = ProcessInventory.descendantPIDs(of: getpid())

        #expect(descendants.first == getpid())
        #expect(Set(descendants).count == descendants.count)
        #expect(!descendants.contains(1))
    }

    @Test("A pid outside the kernel's range yields no entry")
    func outOfRangePIDYieldsNoEntry() {
        // `Int32.max` is far above `PID_MAX`, so no process can hold it and the
        // assertion never has to be skipped. (An earlier form of this test used
        // `99_999_999 % 99_999`, which is pid 999 — a pid a live process can and
        // does hold, so the check quietly skipped itself.)
        #expect(ProcessInventory.entry(pid: Int32.max) == nil)
        #expect(ProcessInventory.currentDirectory(pid: Int32.max) == nil)
        #expect(ProcessInventory.commandLine(pid: Int32.max) == nil)
        #expect(ProcessInventory.childPIDs(of: Int32.max).isEmpty)
    }

    @Test("An unreadable footprint falls back to the task's resident size")
    func unreadableFootprintFallsBackToResidentSize() {
        let withFootprint = ProcessInventory.entry(pid: getpid())
        let withoutFootprint = ProcessInventory.entry(pid: getpid(), footprintReader: { _ in nil })

        #expect((withoutFootprint?.footprintBytes ?? 0) > 0)
        // The two readings measure different things, which is why #1347 D1 moved
        // the metric: resident size counts shared and mapped pages the task is
        // not charged for, while physical footprint counts the compressed and
        // graphics pages resident size misses. Neither bounds the other, so what
        // the fallback has to prove is that it reported the other number rather
        // than zero.
        #expect(withoutFootprint?.footprintBytes != withFootprint?.footprintBytes)
    }

    @Test("Own entry records a start time in the past")
    func ownEntryRecordsStartTime() {
        let entry = ProcessInventory.entry(pid: getpid())

        #expect(entry?.startedAt != nil)
        #expect((entry?.startedAt ?? Date.distantFuture) <= Date())
        #expect((entry?.startedAt ?? Date.distantPast) > Date(timeIntervalSince1970: 1_000_000_000))
    }

    @Test("Host sweep fills detail for own processes and leaves others bare")
    func hostSweepFillsOwnDetail() {
        let entries = ProcessInventory.hostSnapshot()

        #expect(entries.count > 20)
        let own = entries.first { $0.pid == getpid() }
        #expect(own?.currentDirectory != nil)
        #expect(own?.commandLine != nil)

        // Nothing outside the caller's uid gets detail asked for, because the
        // kernel refuses it — the same reason `lsof` never saw those processes.
        let foreign = entries.filter { $0.uid != getuid() }
        #expect(foreign.allSatisfy { $0.currentDirectory == nil && $0.commandLine == nil })
    }

    @Test("Argument-area parsing keeps argv and drops the executable padding")
    func parsesArgumentArea() {
        var bytes: [CChar] = []
        withUnsafeBytes(of: Int32(3)) { raw in
            bytes.append(contentsOf: raw.map { CChar(bitPattern: $0) })
        }
        func append(_ text: String) {
            bytes.append(contentsOf: text.utf8.map { CChar(bitPattern: $0) })
            bytes.append(0)
        }
        append("/usr/local/bin/claude")
        bytes.append(contentsOf: [0, 0, 0])  // kernel padding after the exec path
        append("claude")
        append("--continue")
        append("--verbose")
        append("PATH=/usr/bin")  // the environment follows argv and is not ours

        let parsed = bytes.withUnsafeBufferPointer(ProcessInventory.parseArgumentArea(bytes:))

        #expect(parsed == "claude --continue --verbose")
    }
}

@Suite("RuntimeSamplerIsSpawnFree", .serialized)
struct RuntimeSamplerSpawnFreeTests {

    /// Binaries a process listing would have to reach for. `ps` and `lsof` are
    /// what this path used to spawn; the rest are where a reimplementation would
    /// go next.
    private static let listingTools: Set<String> = [
        "ps", "lsof", "top", "vmmap", "footprint", "sysctl", "pgrep", "pstree",
    ]

    /// The behavioural proof: watch this process's children while the sweep runs.
    ///
    /// A `ps` round trip over a thousand processes lives for tens of
    /// milliseconds, so a poll every 200 µs cannot step over one. Children are
    /// judged by name rather than by count, because the test bundle runs suites
    /// in parallel and a neighbouring suite's `git` is not this path's business.
    @Test("No process-listing binary is spawned while the sweep runs")
    func sweepSpawnsNoListingTool() async throws {
        let provider = LiveRuntimeProcessSnapshotProvider()
        _ = try await provider.processes()  // warm the one-time KERN_ARGMAX read

        let observer = Task.detached(priority: .high) { () -> Set<String> in
            var names: Set<String> = []
            while !Task.isCancelled {
                for child in ProcessInventory.childPIDs(of: getpid()) {
                    if let name = ProcessInventory.entry(pid: child)?.name {
                        names.insert(name)
                    }
                }
                try? await Task.sleep(for: .microseconds(200))
            }
            return names
        }

        for _ in 0..<25 {
            let samples = try await provider.processes()
            #expect(samples.count > 20)
        }

        observer.cancel()
        let observed = await observer.value
        #expect(
            observed.intersection(Self.listingTools).isEmpty,
            "sampling spawned \(observed.intersection(Self.listingTools).sorted())"
        )
    }

    /// The source-level proof, so the behavioural one cannot be satisfied by a
    /// spawn that happens to be short-lived. The sampling path constructs no
    /// `Process` and names no external binary. Comment lines are stripped first:
    /// the files explain what they no longer do, and saying so is not doing it.
    @Test("The sampling path constructs no subprocess")
    func samplingPathConstructsNoSubprocess() throws {
        let services = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkspaceManagerTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/WorkspaceManagerCore/Services")

        let files = [
            "RuntimeDiagnostics.swift", "ProcessInventory.swift", "RuntimeProcessAlerts.swift",
        ]
        for file in files {
            let source = try String(contentsOf: services.appendingPathComponent(file), encoding: .utf8)
            let code =
                source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            for forbidden in ["ProcessRunner", "Process(", "/bin/", "/usr/sbin/", "posix_spawn"] {
                #expect(
                    !code.contains(forbidden),
                    "\(file) must not reach for \(forbidden) on the sampling path"
                )
            }
        }
    }
}

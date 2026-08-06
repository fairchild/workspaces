//
//  LaunchBudget.swift
//  WorkspaceManagerTests
//
//  Sizes test deadlines from this machine's measured cost of launching a supervised
//  child and getting an answer out of it, instead of from a fixed wall clock. That
//  cost is the dominant and least predictable term for any test that supervises a
//  process: this laptop does it in ~0.3s while a loaded hosted runner has measured
//  ~35s, so a constant budget is a bet against a quantity the test cannot see.
//
//  The unit is deliberately the whole round trip — posix_spawn, `/bin/sh`, `python3`,
//  the imports, the bind, and the first successful HTTP response — because that is
//  what the tests wait on. Measuring a bare interpreter spawn instead under-predicts
//  it by more than an order of magnitude on exactly the machines that matter.
//
//  Load is not stationary either, so a single calibration at suite start is the same
//  bet one step removed. The baseline is therefore a running maximum that can be
//  re-measured on demand — budgets only ever widen, and a wait that misses its
//  deadline can ask whether the machine slowed down before calling it a regression.
//

import Darwin
import Foundation

actor LaunchBudget {
    /// Reproduces another machine's launch latency without needing that machine —
    /// set `WORKSPACES_TEST_LAUNCH_BASELINE_SECONDS=35` to run a launch-bound suite
    /// under loaded-hosted-runner budgets from a fast laptop.
    static let baselineOverrideKey = "WORKSPACES_TEST_LAUNCH_BASELINE_SECONDS"

    /// Longest a single probe may run before it is killed and its cap reported as the
    /// sample. A stub that never answers must not become an unbounded wait — the probe
    /// is load instrumentation, and a capped over-estimate only widens budgets.
    private static let probeCap: TimeInterval = 90

    /// Stand-in for a machine where the probe cannot run at all (no `python3`, no free
    /// port). Generous on purpose: an unmeasurable machine is not evidence of a fast
    /// one, and the stubs need the same interpreter anyway.
    private static let unmeasurableLaunchSeconds: TimeInterval = 20

    private static let shared = LaunchBudget()

    private var observedLaunchSeconds: TimeInterval?

    /// Highest launch cost observed so far in this test process. Measured on first use
    /// — the probe doubles as a warm-up, faulting in the interpreter and the modules
    /// the stubs import so the first real test does not pay for both.
    static func launchSeconds() async -> TimeInterval {
        await shared.value(refreshing: false)
    }

    /// Re-probes and folds the sample into the running maximum. Call when a wait has
    /// already missed its deadline, or right before handing a budget to something that
    /// cannot be extended later — those are the two places a stale baseline turns into
    /// a failure that has nothing to do with the code under test.
    static func refreshedLaunchSeconds() async -> TimeInterval {
        await shared.value(refreshing: true)
    }

    /// Deadline for an observable event costing roughly `launches` of those round
    /// trips. Never below `floor`, so a fast machine still fails quickly when something
    /// is genuinely broken; never above `ceiling`, so a pathological baseline cannot
    /// hang the run. These bound failure only: a passing test returns the moment it
    /// observes its state change, so a generous ceiling is free on a healthy machine.
    static func deadline(
        launches: Double,
        floor: TimeInterval,
        ceiling: TimeInterval,
        refreshing: Bool = false
    ) async -> TimeInterval {
        let baseline = refreshing ? await refreshedLaunchSeconds() : await launchSeconds()
        return deadline(launchSeconds: baseline, launches: launches, floor: floor, ceiling: ceiling)
    }

    /// The scaling itself, independent of what this machine measured, so the budget
    /// policy can be tested at latencies the test machine will never exhibit.
    static func deadline(
        launchSeconds: TimeInterval,
        launches: Double,
        floor: TimeInterval,
        ceiling: TimeInterval
    ) -> TimeInterval {
        min(ceiling, max(floor, launchSeconds * launches))
    }

    /// A free loopback TCP port, shared with the fixtures so probe and tests allocate
    /// ports the same way.
    static func findFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EIO) }
        defer { close(sock) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func value(refreshing: Bool) async -> TimeInterval {
        if let override = Self.baselineOverride {
            if observedLaunchSeconds == nil {
                Self.report(override, source: "override via \(Self.baselineOverrideKey)")
                observedLaunchSeconds = override
            }
            return override
        }
        if let observed = observedLaunchSeconds, !refreshing {
            return observed
        }

        let sample = await Self.probe()
        let updated = max(observedLaunchSeconds ?? 0, sample)
        if updated != observedLaunchSeconds {
            Self.report(updated, source: observedLaunchSeconds == nil ? "measured" : "re-measured")
        }
        observedLaunchSeconds = updated
        return updated
    }

    private static let baselineOverride: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment[baselineOverrideKey],
            let value = TimeInterval(raw), value > 0
        else { return nil }
        return value
    }()

    /// Times one launch-to-first-response round trip: `/bin/sh` execs a `python3` HTTP
    /// server on a free port, and the clock stops when a request to it succeeds. The
    /// shape mirrors the fixtures deliberately — a budget is only as good as the
    /// resemblance between what it measures and what it is spent on.
    private static func probe() async -> TimeInterval {
        guard let port = try? findFreePort() else { return unmeasurableLaunchSeconds }
        let started = Date()
        guard let pid = launchProbeServer(port: port) else { return unmeasurableLaunchSeconds }
        defer {
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        // swift-format-ignore: NeverForceUnwrap
        // Safe: fixed scheme/host plus a kernel-assigned port always forms a valid URL.
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let deadline = started.addingTimeInterval(probeCap)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5
            if let (_, response) = try? await session.data(for: request),
                (response as? HTTPURLResponse) != nil
            {
                return max(Date().timeIntervalSince(started), 0.05)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Capped, not measured: the machine is at least this slow, which is all a
        // budget needs to know.
        return probeCap
    }

    /// Spawns the probe server in its own process group so the whole thing can be
    /// killed by group, the same way the service under test manages its child.
    private static func launchProbeServer(port: Int) -> pid_t? {
        let script = "exec python3 -m http.server \(port) --bind 127.0.0.1"
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments: [String] = ["/bin/sh", "-c", script]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv { free(pointer) } }

        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argv, environ) == 0 else {
            return nil
        }
        return pid
    }

    /// Printed whenever the baseline changes so a future failure is diagnosable from
    /// the CI log alone: every budget in the launch-bound suites is a multiple of it.
    private static func report(_ seconds: TimeInterval, source: String) {
        print(String(format: "[LaunchBudget] launch-to-first-response baseline: %.3fs (%@)", seconds, source))
    }
}

/// Waits for `condition`, and when the deadline passes, asks whether the machine got
/// slower than the baseline the deadline was sized from before giving up. Re-measuring
/// only on a miss keeps the happy path free while removing the stationary-load
/// assumption — the assumption behind both previous attempts at these budgets.
func waitUntilLaunchScaled(
    launches: Double,
    floor: TimeInterval,
    ceiling: TimeInterval,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let budget = await LaunchBudget.deadline(launches: launches, floor: floor, ceiling: ceiling)
    if await waitUntil(timeout: budget, condition) { return true }

    let refreshed = await LaunchBudget.deadline(
        launches: launches, floor: floor, ceiling: ceiling, refreshing: true)
    guard refreshed > budget else { return false }
    return await waitUntil(timeout: refreshed - budget, condition)
}

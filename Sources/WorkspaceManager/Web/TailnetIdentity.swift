//
//  TailnetIdentity.swift
//  WorkspaceManager
//
//  Resolves this Mac's tailnet HTTPS origin (MagicDNS name) via the Tailscale
//  CLI, cached in UserDefaults so launch-path callers never pay the subprocess
//  twice. Returns nil — never blocking past a short deadline — when Tailscale
//  is absent, stopped, or unresponsive.
//

import Foundation
import WorkspaceManagerCore

enum TailnetIdentity {
    static let cacheKey = "tailnetHTTPSOrigin"

    private static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// The cached origin, or a live resolution (cached on success). The cache
    /// is deliberately sticky: a MagicDNS name changes only when the machine is
    /// renamed, and clearing the key forces a fresh resolve.
    static func httpsOrigin(defaults: UserDefaults = LaunchPreferences.defaults) -> String? {
        if let cached = defaults.string(forKey: cacheKey), !cached.isEmpty {
            return cached
        }
        guard let name = resolveDNSName() else { return nil }
        let origin = "https://\(name)"
        defaults.set(origin, forKey: cacheKey)
        return origin
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// `tailscale status --json` → `.Self.DNSName`, trailing dot stripped.
    /// Output is drained on a background queue so a large status document can
    /// never deadlock the pipe against the deadline wait.
    static func resolveDNSName(deadline: TimeInterval = 2) -> String? {
        guard
            let cli = cliCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard stderr rather than piping it: an undrained stderr pipe could
        // fill its buffer and wedge the child, and this call never reads it.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        let handle = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            readDone.signal()
        }
        if readDone.wait(timeout: .now() + deadline) == .timedOut {
            process.terminate()
            // terminate() is best-effort SIGTERM; reap on a detached queue so a
            // slow-to-exit child is still waited on (no zombie) without holding
            // the caller past the deadline.
            DispatchQueue.global(qos: .utility).async { process.waitUntilExit() }
            return nil
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: box.data) as? [String: Any],
            let selfNode = json["Self"] as? [String: Any],
            let dnsName = selfNode["DNSName"] as? String
        else { return nil }
        let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
        return trimmed.isEmpty ? nil : trimmed
    }
}

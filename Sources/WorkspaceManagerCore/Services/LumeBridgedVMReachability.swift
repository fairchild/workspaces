//
//  LumeBridgedVMReachability.swift
//  WorkspaceManagerCore
//
//  Host-side reachability fallback for bridged Lume VMs when daemon snapshots lag.
//

import Foundation
import Network

struct LumeBridgedReachabilitySnapshot: Sendable, Equatable {
    let ipAddress: String?
    let sshAvailable: Bool?
}

struct LumeBridgedVMReachability: Sendable {
    func resolve(
        vmName: String,
        storagePath: String,
        networkMode: String?,
        existingIPAddress: String?,
        existingSSHAvailable: Bool?
    ) async -> LumeBridgedReachabilitySnapshot? {
        guard let interfaceName = Self.bridgedInterface(from: networkMode) else {
            return nil
        }

        guard let macAddress = macAddress(forVMNamed: vmName, storagePath: storagePath) else {
            return nil
        }

        var ipAddress = sanitize(existingIPAddress)
        if ipAddress == nil {
            ipAddress = await discoverIPAddress(
                forMACAddress: macAddress,
                interfaceName: interfaceName
            )
        }

        var sshAvailable = existingSSHAvailable
        if let ipAddress, sshAvailable != true {
            let portOpen = await Self.isTCPPortOpen(host: ipAddress, port: 22, timeout: 1.0)
            if portOpen {
                sshAvailable = true
            }
        }

        guard ipAddress != sanitize(existingIPAddress) || sshAvailable != existingSSHAvailable else {
            return nil
        }

        return LumeBridgedReachabilitySnapshot(
            ipAddress: ipAddress,
            sshAvailable: sshAvailable
        )
    }

    static func bridgedInterface(from networkMode: String?) -> String? {
        guard let networkMode else { return nil }
        guard networkMode.hasPrefix("bridged:") else { return nil }

        let interfaceName = String(networkMode.dropFirst("bridged:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return interfaceName.isEmpty ? nil : interfaceName
    }

    static func ipAddress(
        forMACAddress macAddress: String,
        interfaceName: String,
        arpOutput: String
    ) -> String? {
        let normalizedMAC = macAddress.lowercased()
        return parseARPEntries(arpOutput)
            .first(where: { entry in
                entry.macAddress == normalizedMAC && entry.interfaceName == interfaceName
            })?
            .ipAddress
    }

    static func parseARPEntries(_ output: String) -> [ARPEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let pattern = #"\(([^)]+)\) at ([0-9a-f:]+) on ([^ ]+)"#
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    return nil
                }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: String(line), range: range) else {
                    return nil
                }
                guard
                    let ipRange = Range(match.range(at: 1), in: line),
                    let macRange = Range(match.range(at: 2), in: line),
                    let interfaceRange = Range(match.range(at: 3), in: line)
                else {
                    return nil
                }

                return ARPEntry(
                    ipAddress: String(line[ipRange]),
                    macAddress: normalizeMACAddress(String(line[macRange])),
                    interfaceName: String(line[interfaceRange])
                )
            }
    }

    private func macAddress(forVMNamed vmName: String, storagePath: String) -> String? {
        let configURL = URL(fileURLWithPath: storagePath, isDirectory: true)
            .appendingPathComponent(vmName, isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return nil
        }

        guard
            let data = try? Data(contentsOf: configURL),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMACAddress = payload["macAddress"] as? String
        else {
            return nil
        }

        return Self.normalizeMACAddress(rawMACAddress)
    }

    private func discoverIPAddress(forMACAddress macAddress: String, interfaceName: String) async -> String? {
        if let existingIPAddress = await ipAddressFromARP(
            forMACAddress: macAddress,
            interfaceName: interfaceName
        ) {
            return existingIPAddress
        }

        guard let subnetPrefix = ipv4SubnetPrefix(for: interfaceName) else {
            return nil
        }

        await stimulateARP(on: subnetPrefix)
        return await ipAddressFromARP(forMACAddress: macAddress, interfaceName: interfaceName)
    }

    private func ipAddressFromARP(forMACAddress macAddress: String, interfaceName: String) async -> String? {
        guard
            // Un-timed by design: `arp -an` reads a local table and reachability
            // probing has outer deadlines (scripts/check-subprocess-timeouts.py allowlist).
            let result = try? await ProcessRunner.run(executable: "/usr/sbin/arp", arguments: ["-an"]),
            result.success
        else {
            return nil
        }

        return Self.ipAddress(
            forMACAddress: macAddress,
            interfaceName: interfaceName,
            arpOutput: result.stdout
        )
    }

    private func ipv4SubnetPrefix(for interfaceName: String) -> String? {
        var addressesPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressesPointer) == 0, let addressesPointer else {
            return nil
        }
        defer { freeifaddrs(addressesPointer) }

        var cursor = addressesPointer
        while true {
            let interface = cursor.pointee
            let name = String(cString: interface.ifa_name)

            if name == interfaceName,
                let socketAddress = interface.ifa_addr,
                socketAddress.pointee.sa_family == UInt8(AF_INET)
            {
                var address = unsafeBitCast(socketAddress.pointee, to: sockaddr_in.self).sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
                let ipAddress = String(cString: buffer)
                let octets = ipAddress.split(separator: ".")
                if octets.count == 4 {
                    return octets.prefix(3).joined(separator: ".")
                }
            }

            guard let next = interface.ifa_next else {
                break
            }
            cursor = next
        }

        return nil
    }

    private func stimulateARP(on subnetPrefix: String) async {
        await withTaskGroup(of: Void.self) { group in
            for hostOctet in 1...254 {
                group.addTask {
                    let host = "\(subnetPrefix).\(hostOctet)"
                    _ = await Self.isTCPPortOpen(host: host, port: 22, timeout: 0.15)
                }
            }
        }
    }

    private func sanitize(_ ipAddress: String?) -> String? {
        guard let ipAddress else { return nil }
        let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeMACAddress(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: ":")
            .map { component in
                component.count == 1 ? "0\(component)" : String(component)
            }
            .joined(separator: ":")
    }

    private static func isTCPPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port),
                using: .tcp
            )

            let stateQueue = DispatchQueue(label: "LumeBridgedVMReachability.network", attributes: .concurrent)
            let resultEmitter = LockedEmitter(continuation: continuation)
            let timeoutWork = DispatchWorkItem {
                connection.cancel()
                resultEmitter.resume(with: false)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutWork.cancel()
                    connection.cancel()
                    resultEmitter.resume(with: true)
                case .failed, .cancelled:
                    timeoutWork.cancel()
                    resultEmitter.resume(with: false)
                default:
                    break
                }
            }

            stateQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            connection.start(queue: stateQueue)
        }
    }
}

extension LumeBridgedVMReachability {
    struct ARPEntry: Sendable, Equatable {
        let ipAddress: String
        let macAddress: String
        let interfaceName: String
    }
}

private final class LockedEmitter<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

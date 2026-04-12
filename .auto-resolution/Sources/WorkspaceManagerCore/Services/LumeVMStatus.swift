//
//  LumeVMStatus.swift
//  WorkspaceManagerCore
//
//  Normalized VM lifecycle states from the Lume daemon and CLI.
//

import Foundation

public enum LumeVMStatus: Sendable, Equatable {
    case running
    case stopped
    case provisioning
    case provisioningStale
    case missing
    case unknown(String)

    public init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "running":
            self = .running
        case "stopped":
            self = .stopped
        case "provisioning":
            self = .provisioning
        case "provisioning (stale)":
            self = .provisioningStale
        case "missing":
            self = .missing
        default:
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .running:
            return "running"
        case .stopped:
            return "stopped"
        case .provisioning:
            return "provisioning"
        case .provisioningStale:
            return "provisioning (stale)"
        case .missing:
            return "missing"
        case .unknown(let rawValue):
            return rawValue
        }
    }

    public var isRunning: Bool {
        self == .running
    }

    public var isProvisioning: Bool {
        switch self {
        case .provisioning, .provisioningStale:
            return true
        default:
            return false
        }
    }

    public var workspaceStatus: WorkspaceStatus {
        switch self {
        case .running:
            return .active
        case .stopped:
            return .stopped
        case .provisioning, .provisioningStale:
            return .provisioning
        case .missing, .unknown:
            return .archived
        }
    }
}

extension LumeBaseVMSnapshot {
    public var normalizedVMStatus: LumeVMStatus? {
        vmStatus.map(LumeVMStatus.init(rawValue:))
    }
}

import Foundation
import WorkspaceManagerCore

enum WorkspaceBackendChoice: String, CaseIterable, Identifiable, Sendable {
    case local
    case daytona
    case sshHost

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .daytona:
            return "Daytona"
        case .sshHost:
            return "SSH Host"
        }
    }

    var icon: String {
        switch self {
        case .local:
            return "laptopcomputer"
        case .daytona:
            return "cloud"
        case .sshHost:
            return "terminal"
        }
    }

    var summary: String {
        switch self {
        case .local:
            return "Copy the repository into a new local workspace directory."
        case .daytona:
            return "Create a Daytona-managed remote workspace."
        case .sshHost:
            return "Connect to an existing SSH host with an optional Docker Compose overlay."
        }
    }

    var usesSSHConfiguration: Bool {
        self == .sshHost
    }
}

struct SSHHostWorkspaceRequest: Equatable, Sendable {
    var ssh: SSHWorkspaceMetadata
    var compose: ComposeWorkspaceMetadata?
}

struct NewWorkspaceRequest: Equatable, Sendable {
    enum Backend: Equatable, Sendable {
        case local
        case daytona
        case sshHost(SSHHostWorkspaceRequest)
    }

    let name: String
    let backend: Backend

    var backendChoice: WorkspaceBackendChoice {
        switch backend {
        case .local:
            return .local
        case .daytona:
            return .daytona
        case .sshHost:
            return .sshHost
        }
    }
}

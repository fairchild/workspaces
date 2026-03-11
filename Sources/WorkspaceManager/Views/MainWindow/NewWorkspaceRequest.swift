import Foundation
import WorkspaceManagerCore

enum WorkspaceBackendChoice: String, CaseIterable, Identifiable, Sendable {
    case local
    case daytona
    case sshHost
    case kubernetesPod
    case sshCompose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "Local"
        case .daytona:
            return "Daytona"
        case .sshHost:
            return "SSH Host"
        case .kubernetesPod:
            return "Kubernetes Pod"
        case .sshCompose:
            return "SSH + Compose"
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
        case .kubernetesPod:
            return "shippingbox"
        case .sshCompose:
            return "square.stack.3d.forward.dottedline"
        }
    }

    var summary: String {
        switch self {
        case .local:
            return "Copy the repository into a new local workspace directory."
        case .daytona:
            return "Create a Daytona-managed remote sandbox for the repository."
        case .sshHost:
            return "Connect the workspace to an existing SSH host."
        case .kubernetesPod:
            return "Target an existing pod or launch from a Kubernetes image template."
        case .sshCompose:
            return "Connect over SSH and attach to a Docker Compose service."
        }
    }

    var usesSSHConfiguration: Bool {
        switch self {
        case .sshHost, .sshCompose:
            return true
        case .local, .daytona, .kubernetesPod:
            return false
        }
    }

    var usesKubernetesConfiguration: Bool {
        self == .kubernetesPod
    }

    var usesComposeConfiguration: Bool {
        self == .sshCompose
    }

    var requiresDaytonaAvailability: Bool {
        self == .daytona
    }

    var supportsCreationFlow: Bool {
        switch self {
        case .local, .daytona:
            return true
        case .sshHost, .kubernetesPod, .sshCompose:
            return false
        }
    }
}

enum SSHAuthenticationChoice: String, CaseIterable, Identifiable, Sendable {
    case agent = "ssh-agent"
    case key = "private-key"
    case password

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent:
            return "SSH Agent"
        case .key:
            return "Private Key"
        case .password:
            return "Password"
        }
    }
}

enum ComposeStartupStrategy: String, CaseIterable, Identifiable, Sendable {
    case execExisting
    case upThenExec
    case runOneOff

    var id: String { rawValue }

    var label: String {
        switch self {
        case .execExisting:
            return "Exec Existing"
        case .upThenExec:
            return "Up Then Exec"
        case .runOneOff:
            return "Run One-off"
        }
    }

    var summary: String {
        switch self {
        case .execExisting:
            return "Attach to an already-running service container."
        case .upThenExec:
            return "Start the service first, then open a shell inside it."
        case .runOneOff:
            return "Launch a one-off container session for the service."
        }
    }
}

struct KubernetesPodWorkspaceRequest: Equatable, Sendable {
    var context: String
    var namespace: String?
    var pod: String?
    var container: String?
    var imageTemplate: String?
}

struct SSHComposeWorkspaceRequest: Equatable, Sendable {
    var ssh: SSHWorkspaceMetadata
    var composeFiles: [String]
    var service: String
    var startupStrategy: ComposeStartupStrategy
}

struct NewWorkspaceRequest: Equatable, Sendable {
    enum Backend: Equatable, Sendable {
        case local
        case daytona
        case sshHost(SSHWorkspaceMetadata)
        case kubernetesPod(KubernetesPodWorkspaceRequest)
        case sshCompose(SSHComposeWorkspaceRequest)
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
        case .kubernetesPod:
            return .kubernetesPod
        case .sshCompose:
            return .sshCompose
        }
    }
}

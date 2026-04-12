//
//  Errors.swift
//  WorkspaceManager
//
//  Backend error types
//

import Foundation

public enum BackendError: LocalizedError {
    case notAvailable(String)
    case notRunning
    case alreadyRunning
    case initializationFailed(String)
    case executionFailed(String)
    case commandNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notAvailable(let backend):
            return "\(backend) is not available on this system"
        case .notRunning:
            return "Workspace is not running"
        case .alreadyRunning:
            return "Workspace is already running"
        case .initializationFailed(let reason):
            return "Failed to initialize workspace: \(reason)"
        case .executionFailed(let reason):
            return "Command execution failed: \(reason)"
        case .commandNotFound(let cmd):
            return "Command not found: \(cmd)"
        }
    }
}

public enum RemoteWorkspaceError: LocalizedError {
    case missingRemoteIdentifier
    case backendNotRegistered(String)
    case missingSSHMetadata
    case invalidSSHConfiguration(String)
    case missingRemoteURL
    case invalidComposeConfiguration(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingRemoteIdentifier:
            return "Remote workspace is missing a remote identifier."
        case .backendNotRegistered(let identifier):
            return "Remote backend '\(identifier)' is not registered."
        case .missingSSHMetadata:
            return "SSH workspace metadata is missing or invalid."
        case .invalidSSHConfiguration(let reason):
            return "SSH configuration is invalid: \(reason)"
        case .missingRemoteURL:
            return "The repository must have a remote URL to bootstrap an SSH workspace."
        case .invalidComposeConfiguration(let reason):
            return "Docker Compose configuration is invalid: \(reason)"
        case .commandFailed(let reason):
            return "Remote command failed: \(reason)"
        }
    }
}

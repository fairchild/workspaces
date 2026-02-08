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

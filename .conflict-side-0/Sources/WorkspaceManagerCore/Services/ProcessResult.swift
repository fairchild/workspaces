//
//  ProcessResult.swift
//  WorkspaceManager
//
//  Result of a process execution
//

import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var success: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

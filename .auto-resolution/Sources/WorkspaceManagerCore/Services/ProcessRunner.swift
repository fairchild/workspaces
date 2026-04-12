//
//  ProcessRunner.swift
//  WorkspaceManager
//
//  Shared async process execution with non-blocking stdout/stderr draining.
//

import Foundation

enum ProcessRunner {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()

        private var stdoutData: Data?
        private var stderrData: Data?
        private var exitCode: Int32?
        private var didResume = false

        func completeStdout(_ data: Data) -> ProcessResult? {
            lock.lock()
            stdoutData = data
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func completeStderr(_ data: Data) -> ProcessResult? {
            lock.lock()
            stderrData = data
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func markTerminated(exitCode: Int32) -> ProcessResult? {
            lock.lock()
            self.exitCode = exitCode
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func markFailed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }

        private func makeResultIfReadyLocked() -> ProcessResult? {
            guard
                !didResume,
                let exitCode,
                let stdoutData,
                let stderrData
            else { return nil }

            didResume = true
            return ProcessResult(
                exitCode: exitCode,
                stdout: String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self),
                stderr: String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)
            )
        }
    }

    static func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading
            let state = State()

            DispatchQueue.global(qos: .userInitiated).async {
                let data = stdoutHandle.readDataToEndOfFile()
                if let result = state.completeStdout(data) {
                    continuation.resume(returning: result)
                }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let data = stderrHandle.readDataToEndOfFile()
                if let result = state.completeStderr(data) {
                    continuation.resume(returning: result)
                }
            }

            process.terminationHandler = { process in
                if let result = state.markTerminated(exitCode: process.terminationStatus) {
                    continuation.resume(returning: result)
                }
            }

            do {
                try process.run()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                if state.markFailed() {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

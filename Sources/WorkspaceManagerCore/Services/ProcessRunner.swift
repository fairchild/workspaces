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

        private var stdoutData = Data()
        private var stderrData = Data()
        private var exitCode: Int32 = 0
        private var didTerminate = false
        private var stdoutDone = false
        private var stderrDone = false
        private var didResume = false

        func appendStdout(_ data: Data) {
            lock.lock()
            stdoutData.append(data)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            stderrData.append(data)
            lock.unlock()
        }

        func markStdoutDone() -> ProcessResult? {
            lock.lock()
            stdoutDone = true
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func markStderrDone() -> ProcessResult? {
            lock.lock()
            stderrDone = true
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func markTerminated(
            exitCode: Int32,
            remainingStdout: Data,
            remainingStderr: Data
        ) -> ProcessResult? {
            lock.lock()
            self.exitCode = exitCode
            didTerminate = true
            stdoutDone = true
            stderrDone = true
            if !remainingStdout.isEmpty {
                stdoutData.append(remainingStdout)
            }
            if !remainingStderr.isEmpty {
                stderrData.append(remainingStderr)
            }
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
            guard !didResume, didTerminate, stdoutDone, stderrDone else { return nil }
            didResume = true
            return ProcessResult(
                exitCode: exitCode,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
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

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let result = state.markStdoutDone() {
                        continuation.resume(returning: result)
                    }
                } else {
                    state.appendStdout(data)
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let result = state.markStderrDone() {
                        continuation.resume(returning: result)
                    }
                } else {
                    state.appendStderr(data)
                }
            }

            process.terminationHandler = { _ in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                let remainingStdout = stdoutHandle.readDataToEndOfFile()
                let remainingStderr = stderrHandle.readDataToEndOfFile()

                if let result = state.markTerminated(
                    exitCode: process.terminationStatus,
                    remainingStdout: remainingStdout,
                    remainingStderr: remainingStderr
                ) {
                    continuation.resume(returning: result)
                }
            }

            do {
                try process.run()
            } catch {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                if state.markFailed() {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

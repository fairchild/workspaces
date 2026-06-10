//
//  ProcessRunner.swift
//  WorkspaceManager
//
//  Shared async process execution with non-blocking stdout/stderr draining,
//  a bounded post-exit pipe-drain grace (so backgrounded children that inherit
//  the pipes cannot starve EOF and hang the caller), and an optional timeout
//  that kills the child and throws.
//

import Foundation

enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut(executable: String, arguments: [String], timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let arguments, let timeout):
            let command = ([executable] + arguments).joined(separator: " ")
            return "Command timed out after \(timeout)s: \(command)"
        }
    }
}

enum ProcessRunner {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()

        private var stdoutData = Data()
        private var stderrData = Data()
        private var stdoutEOF = false
        private var stderrEOF = false
        private var exitCode: Int32?
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

        func completeStdout() -> ProcessResult? {
            lock.lock()
            stdoutEOF = true
            let result = makeResultIfReadyLocked()
            lock.unlock()
            return result
        }

        func completeStderr() -> ProcessResult? {
            lock.lock()
            stderrEOF = true
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

        /// Resume with the output captured so far, even though a pipe never reached
        /// EOF — the exit code is already known, so the result is complete except for
        /// whatever a backgrounded child might still write into the inherited pipe.
        func finalizeAfterGrace() -> ProcessResult? {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume, let exitCode else { return nil }
            didResume = true
            return makeResultLocked(exitCode: exitCode)
        }

        /// Claim the single resume slot for a throwing path (launch failure, timeout).
        func takeResumeSlot() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }

        private func makeResultIfReadyLocked() -> ProcessResult? {
            guard !didResume, let exitCode, stdoutEOF, stderrEOF else { return nil }
            didResume = true
            return makeResultLocked(exitCode: exitCode)
        }

        private func makeResultLocked(exitCode: Int32) -> ProcessResult {
            ProcessResult(
                exitCode: exitCode,
                stdout: String(data: stdoutData, encoding: .utf8) ?? String(decoding: stdoutData, as: UTF8.self),
                stderr: String(data: stderrData, encoding: .utf8) ?? String(decoding: stderrData, as: UTF8.self)
            )
        }
    }

    /// Run `executable` and capture stdout/stderr until exit.
    ///
    /// - Parameters:
    ///   - timeout: When set, the child is terminated (SIGTERM, escalating to SIGKILL
    ///     after one second) once the interval elapses and the call throws
    ///     `ProcessRunnerError.timedOut`. `nil` waits indefinitely for exit.
    ///   - pipeDrainGracePeriod: How long to keep draining stdout/stderr after the
    ///     child exits when a pipe has not reached EOF — the case where a backgrounded
    ///     grandchild inherited the write end. After the grace the call returns with
    ///     the output captured so far instead of waiting on a pipe that may never close.
    static func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        pipeDrainGracePeriod: TimeInterval = 2.0
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

            let stopDraining: @Sendable () -> Void = {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
            }

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let result = state.completeStdout() {
                        stopDraining()
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
                    if let result = state.completeStderr() {
                        stopDraining()
                        continuation.resume(returning: result)
                    }
                } else {
                    state.appendStderr(data)
                }
            }

            process.terminationHandler = { process in
                if let result = state.markTerminated(exitCode: process.terminationStatus) {
                    stopDraining()
                    continuation.resume(returning: result)
                    return
                }
                // Exit is recorded but a pipe is still open — typically a backgrounded
                // child inherited the write end. Drain for the bounded grace, then
                // finish with what was captured.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + pipeDrainGracePeriod
                ) {
                    if let result = state.finalizeAfterGrace() {
                        stopDraining()
                        continuation.resume(returning: result)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                stopDraining()
                try? stdoutHandle.close()
                try? stderrHandle.close()
                if state.takeResumeSlot() {
                    continuation.resume(throwing: error)
                }
                return
            }

            if let timeout {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    guard state.takeResumeSlot() else { return }
                    stopDraining()
                    if process.isRunning {
                        process.terminate()
                    }
                    let pid = process.processIdentifier
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                    continuation.resume(
                        throwing: ProcessRunnerError.timedOut(
                            executable: executable,
                            arguments: arguments,
                            timeout: timeout
                        )
                    )
                }
            }
        }
    }
}

//
//  LocalTerminal.swift
//  WorkspaceManager
//
//  PTY-based terminal for local workspace execution
//

import Foundation

public class LocalTerminal {
    private let process: Process
    private let masterFd: Int32
    private var readSource: DispatchSourceRead?

    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public init(workingDirectory: URL) {
        self.process = Process()

        // Create PTY
        var master: Int32 = 0
        var slave: Int32 = 0

        var windowSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            fatalError("Failed to create PTY")
        }

        self.masterFd = master

        // Configure process
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["--login"]
        process.currentDirectoryURL = workingDirectory

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        process.environment = env

        // Connect to PTY
        process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardOutput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)

        // Set up read handler
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.masterFd, &buffer, buffer.count)
            if bytesRead > 0 {
                self.onData?(Data(buffer[0..<bytesRead]))
            }
        }
        source.resume()
        self.readSource = source

        // Start process
        process.terminationHandler = { [weak self] process in
            self?.onExit?(process.terminationStatus)
        }

        try? process.run()
        Darwin.close(slave)  // Close slave in parent
    }

    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            _ = Foundation.write(masterFd, buffer.baseAddress!, buffer.count)
        }
    }

    public func resize(cols: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &size)
    }

    public func close() {
        readSource?.cancel()
        readSource = nil
        process.terminate()
        Darwin.close(masterFd)
    }

    deinit {
        close()
    }
}

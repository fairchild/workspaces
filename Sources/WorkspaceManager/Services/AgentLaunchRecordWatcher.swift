//
//  AgentLaunchRecordWatcher.swift
//  WorkspaceManager
//
//  Tells a window when the CLI has written a launch record, by watching the directory the
//  records live in. A record lands by atomic rename, which is a write to the directory, so
//  one kernel event covers it. Bursts are coalesced: a launcher fanning out workers should
//  cost one pass, not one per worker.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AgentLaunchRecordWatcher")

@MainActor
final class AgentLaunchRecordWatcher {
    private let directory: URL
    private let onChange: @MainActor () -> Void
    private let coalescing: Duration
    private var source: DispatchSourceFileSystemObject?
    private var pendingPass: Task<Void, Never>?

    init(
        directory: URL,
        coalescing: Duration = .milliseconds(300),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.directory = directory
        self.coalescing = coalescing
        self.onChange = onChange
    }

    /// The directory is created here because it may not exist yet on a machine that has never
    /// launched from the CLI, and an event source needs something to open.
    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            log.notice("Not watching launch records: could not open \(self.directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedulePass() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pendingPass?.cancel()
        pendingPass = nil
        source?.cancel()
        source = nil
    }

    private func schedulePass() {
        pendingPass?.cancel()
        pendingPass = Task { [coalescing, onChange] in
            try? await Task.sleep(for: coalescing)
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}

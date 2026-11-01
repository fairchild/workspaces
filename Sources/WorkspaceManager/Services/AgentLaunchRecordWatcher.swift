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
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            log.notice("Not watching launch records: could not open \(self.directory.path, privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated { self?.handle(source?.data ?? []) }
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

    /// A directory deleted or moved away is no longer where records land, and the descriptor
    /// would go on watching it, so the watch starts over on the path.
    private func handle(_ events: DispatchSource.FileSystemEvent) {
        if !events.isDisjoint(with: [.delete, .rename]) {
            source?.cancel()
            source = nil
            start()
        }
        schedulePass()
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
